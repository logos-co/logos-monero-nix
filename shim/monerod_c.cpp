#include "monerod_c.h"

#include <atomic>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#if defined(__APPLE__)
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#endif

#include <boost/filesystem.hpp>
#include <boost/program_options.hpp>


#include "common/command_line.h"
#include "common/util.h"
#include "cryptonote_core/cryptonote_core.h"
#include "daemon/command_line_args.h"
#include "daemon/daemon.h"
#include "daemon/executor.h"
#include "misc_log_ex.h"
#include "rpc/core_rpc_server.h"
#include "string_tools.h"
#include "rpc/rpc_args.h"
#include "version.h"

#undef MONERO_DEFAULT_LOG_CATEGORY
#define MONERO_DEFAULT_LOG_CATEGORY "logos.monerod"

// Declared with OpenSSL's exact parameter type, so it is a compatible redeclaration when
// the real header also arrives transitively; including it directly breaks on Windows.
struct ossl_init_settings_st;
extern "C" int OPENSSL_init_ssl(uint64_t opts, const ossl_init_settings_st* settings);

namespace po = boost::program_options;
namespace bf = boost::filesystem;

namespace {

// Unlike main.cpp there is no daemonize/fork, no signal handler, no config file
// and no public-node advertising: the module owns the process and the config.

std::mutex g_mutex;                              // serialises start/stop
std::atomic<int> g_state{MONEROD_STOPPED};
std::thread g_thread;
std::string g_error;                             // guarded by g_mutex
std::string g_argv_json;                         // guarded by g_mutex
std::string g_data_dir;                          // guarded by g_mutex
std::string g_network;                           // guarded by g_mutex
std::string g_rpc_url;                           // guarded by g_mutex
std::chrono::steady_clock::time_point g_started;
std::unique_ptr<daemonize::t_daemon> g_daemon;   // guarded by g_mutex

// easylogging++ is process-global: configure it once.
bool g_log_configured = false;
bool g_rx_jit_disabled = false;

#if defined(__APPLE__)
// A hardened-runtime host may JIT only with the allow-jit entitlement. Without it RandomX's
// JIT traps in pthread_jit_write_protect_np the moment it builds a cache (Basecamp's host).
bool host_forbids_jit() {
  SecCodeRef self = nullptr;
  if (SecCodeCopySelf(kSecCSDefaultFlags, &self) != errSecSuccess || !self) return false;
  bool forbidden = false;
  CFDictionaryRef info = nullptr;
  if (SecCodeCopySigningInformation(reinterpret_cast<SecStaticCodeRef>(self),
                                    kSecCSSigningInformation | kSecCSRequirementInformation,
                                    &info) == errSecSuccess && info) {
    uint32_t flags = 0;
    if (auto n = static_cast<CFNumberRef>(CFDictionaryGetValue(info, kSecCodeInfoFlags)))
      CFNumberGetValue(n, kCFNumberSInt32Type, &flags);
    if (flags & kSecCodeSignatureRuntime) {
      auto ents = static_cast<CFDictionaryRef>(CFDictionaryGetValue(info, kSecCodeInfoEntitlementsDict));
      forbidden = !ents || CFDictionaryGetValue(ents, CFSTR("com.apple.security.cs.allow-jit")) != kCFBooleanTrue;
    }
    CFRelease(info);
  }
  CFRelease(self);
  return forbidden;
}
#endif

// tools::on_startup() minus setup_crash_dump(), whose SIGSEGV handler would kill the
// host. The OpenSSL init matters: rpc-ssl=autodetect stalls every request without it.
void library_startup_once() {
  static std::once_flag once;
  std::call_once(once, [] {
    // boost::filesystem throws on some locales; must precede bf::absolute().
    tools::sanitize_locale();
    epee::string_tools::set_module_name_and_folder("monerod");
    OPENSSL_init_ssl(0, nullptr);
#if defined(__APPLE__)
    // Monero's own knob: a mask of RandomX flags to drop. The interpreter gives the same hashes.
    if (!std::getenv("MONERO_RANDOMX_UMASK") && host_forbids_jit()) {
      setenv("MONERO_RANDOMX_UMASK", "8", 0);  // RANDOMX_FLAG_JIT
      g_rx_jit_disabled = true;
    }
#endif
  });
}

char* dup_c(const std::string& s) {
  char* out = static_cast<char*>(std::malloc(s.size() + 1));
  if (!out) return nullptr;
  std::memcpy(out, s.c_str(), s.size() + 1);
  return out;
}

void set_error(const std::string& msg) {
  g_error = msg;
  if (!msg.empty()) MERROR(msg);
}

// Small escaper rather than pulling nlohmann into five cross builds.
std::string json_escape(const std::string& in) {
  std::string out;
  out.reserve(in.size() + 8);
  for (char c : in) {
    switch (c) {
      case '"':  out += "\\\""; break;
      case '\\': out += "\\\\"; break;
      case '\n': out += "\\n";  break;
      case '\r': out += "\\r";  break;
      case '\t': out += "\\t";  break;
      default:
        if (static_cast<unsigned char>(c) < 0x20) {
          char buf[7];
          std::snprintf(buf, sizeof(buf), "\\u%04x", c & 0xff);
          out += buf;
        } else {
          out += c;
        }
    }
  }
  return out;
}

// Rejects anything it does not fully parse: a silently dropped --stagenet would
// sync mainnet.
bool parse_argv_json(const std::string& in, std::vector<std::string>& out, std::string& err) {
  size_t i = 0;
  auto skip_ws = [&] { while (i < in.size() && (in[i]==' '||in[i]=='\t'||in[i]=='\n'||in[i]=='\r')) ++i; };
  skip_ws();
  if (i >= in.size() || in[i] != '[') { err = "argv must be a JSON array"; return false; }
  ++i; skip_ws();
  if (i < in.size() && in[i] == ']') return true;   // empty array is valid
  while (i < in.size()) {
    skip_ws();
    if (i >= in.size() || in[i] != '"') { err = "argv elements must be strings"; return false; }
    ++i;
    std::string item;
    while (i < in.size() && in[i] != '"') {
      if (in[i] == '\\') {
        if (++i >= in.size()) { err = "unterminated escape in argv"; return false; }
        switch (in[i]) {
          case '"':  item += '"';  break;
          case '\\': item += '\\'; break;
          case '/':  item += '/';  break;
          case 'n':  item += '\n'; break;
          case 'r':  item += '\r'; break;
          case 't':  item += '\t'; break;
          default:   err = "unsupported escape in argv"; return false;
        }
      } else {
        item += in[i];
      }
      ++i;
    }
    if (i >= in.size()) { err = "unterminated string in argv"; return false; }
    ++i;                                            // closing quote
    out.push_back(item);
    skip_ws();
    if (i < in.size() && in[i] == ',') { ++i; continue; }
    if (i < in.size() && in[i] == ']') return true;
    err = "malformed argv array";
    return false;
  }
  err = "unterminated argv array";
  return false;
}

} // namespace

extern "C" {

int MONEROD_start(const char* argv_json) {
  library_startup_once();
  std::lock_guard<std::mutex> lock(g_mutex);

  const int st = g_state.load();
  if (st == MONEROD_STARTING || st == MONEROD_RUNNING || st == MONEROD_STOPPING) {
    set_error("a daemon is already running in this process");
    return 1;
  }
  if (g_thread.joinable()) g_thread.join();        // reap a previous FAILED run
  set_error("");

  std::vector<std::string> args;
  std::string perr;
  if (!parse_argv_json(argv_json ? argv_json : "", args, perr)) {
    set_error("bad argv: " + perr);
    return 1;
  }
  g_argv_json = argv_json ? argv_json : "[]";

  try {
    // monerod's own option set minus the process-only groups; t_executor pulls in
    // core, p2p and rpc.
    po::options_description core_settings("Settings");
    command_line::add_arg(core_settings, daemon_args::arg_log_file);
    command_line::add_arg(core_settings, daemon_args::arg_log_level);
    command_line::add_arg(core_settings, daemon_args::arg_max_log_file_size);
    command_line::add_arg(core_settings, daemon_args::arg_max_log_files);
    command_line::add_arg(core_settings, daemon_args::arg_max_concurrency);
    command_line::add_arg(core_settings, daemon_args::arg_proxy);
    command_line::add_arg(core_settings, daemon_args::arg_proxy_allow_dns_leaks);
    command_line::add_arg(core_settings, daemon_args::arg_zmq_rpc_bind_ip);
    command_line::add_arg(core_settings, daemon_args::arg_zmq_rpc_bind_port);
    command_line::add_arg(core_settings, daemon_args::arg_zmq_pub);
    command_line::add_arg(core_settings, daemon_args::arg_zmq_rpc_disabled);
    daemonize::t_executor::init_options(core_settings);

    // boost::program_options wants a char* argv[] with argv[0] as the program name.
    std::vector<const char*> argv;
    argv.push_back("monerod");
    for (const auto& a : args) argv.push_back(a.c_str());

    po::variables_map vm;
    po::store(po::command_line_parser(static_cast<int>(argv.size()),
                                      const_cast<char**>(argv.data()))
                .options(core_settings)
                .run(),
              vm);
    po::notify(vm);

    const bf::path data_dir =
        bf::absolute(command_line::get_arg(vm, cryptonote::arg_data_dir));
    tools::create_directories_if_necessary(data_dir.string());

    g_data_dir = data_dir.string();
    g_network = command_line::get_arg(vm, cryptonote::arg_stagenet_on) ? "stagenet"
              : command_line::get_arg(vm, cryptonote::arg_testnet_on)  ? "testnet"
              : command_line::get_arg(vm, cryptonote::arg_regtest_on)  ? "regtest"
                                                                       : "mainnet";
    {
      const cryptonote::rpc_args::descriptors arg{};
      g_rpc_url = "http://" + command_line::get_arg(vm, arg.rpc_bind_ip) + ":"
                + command_line::get_arg(vm, cryptonote::core_rpc_server::arg_rpc_bind_port);
    }

    if (!g_log_configured) {
      bf::path log_file_path{command_line::get_arg(vm, daemon_args::arg_log_file)};
      if (!log_file_path.has_parent_path()) log_file_path = data_dir / log_file_path;
      // File only: the host relays our stdout, and logTail() reads the file.
      mlog_configure(log_file_path.string(), false,
                     command_line::get_arg(vm, daemon_args::arg_max_log_file_size),
                     command_line::get_arg(vm, daemon_args::arg_max_log_files));
      if (!command_line::is_arg_defaulted(vm, daemon_args::arg_log_level))
        mlog_set_log(command_line::get_arg(vm, daemon_args::arg_log_level).c_str());
      g_log_configured = true;
    }

    if (!command_line::is_arg_defaulted(vm, daemon_args::arg_max_concurrency))
      tools::set_max_concurrency(command_line::get_arg(vm, daemon_args::arg_max_concurrency));

    MGINFO("Monero '" << MONERO_RELEASE_NAME << "' (v" << MONERO_VERSION_FULL
                      << ") in-process on " << g_network);
    if (g_rx_jit_disabled)
      MGINFO("RandomX JIT off: the host is hardened without com.apple.security.cs.allow-jit");

    // public_rpc_port = 0: never advertise as a public node.
    g_daemon = std::make_unique<daemonize::t_daemon>(vm, 0);
  } catch (const std::exception& e) {
    set_error(std::string("daemon init failed: ") + e.what());
    g_state.store(MONEROD_FAILED);
    g_daemon.reset();
    return 1;
  }

  g_state.store(MONEROD_STARTING);
  g_started = std::chrono::steady_clock::now();

  // t_daemon::run() blocks until stop() is called, so it owns a thread of its own.
  g_thread = std::thread([] {
    bool ok = false;
    try {
      g_state.store(MONEROD_RUNNING);
      ok = g_daemon->run(/*interactive=*/false);
    } catch (const std::exception& e) {
      std::lock_guard<std::mutex> lock(g_mutex);
      set_error(std::string("daemon stopped with an error: ") + e.what());
      g_state.store(MONEROD_FAILED);
      return;
    } catch (...) {
      std::lock_guard<std::mutex> lock(g_mutex);
      set_error("daemon stopped with an unknown error");
      g_state.store(MONEROD_FAILED);
      return;
    }
    // false from run() is a failed start (port in use, bad DB), not a clean stop.
    if (!ok) {
      std::lock_guard<std::mutex> lock(g_mutex);
      if (g_state.load() != MONEROD_STOPPING)
        set_error("daemon failed to start (see the node log)");
      g_state.store(g_state.load() == MONEROD_STOPPING ? MONEROD_STOPPED : MONEROD_FAILED);
    } else {
      g_state.store(MONEROD_STOPPED);
    }
  });

  return 0;
}

void MONEROD_stop(void) {
  std::thread to_join;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    const int st = g_state.load();
    if (st == MONEROD_RUNNING || st == MONEROD_STARTING) {
      g_state.store(MONEROD_STOPPING);
      // stop_p2p(), not stop(): stop() frees mp_internals while run() still uses
      // them. Signal here; the thread tears down and the destructor runs after the join.
      if (g_daemon) g_daemon->stop_p2p();
    }
    to_join = std::move(g_thread);
  }
  // Outside the lock: the daemon thread takes g_mutex on its way out.
  if (to_join.joinable()) to_join.join();
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    g_daemon.reset();
    if (g_state.load() == MONEROD_STOPPING) g_state.store(MONEROD_STOPPED);
  }
}

int MONEROD_state(void) { return g_state.load(); }

const char* MONEROD_status_json(void) {
  std::lock_guard<std::mutex> lock(g_mutex);
  const int st = g_state.load();
  const long long uptime =
      (st == MONEROD_RUNNING || st == MONEROD_STOPPING)
          ? std::chrono::duration_cast<std::chrono::seconds>(
                std::chrono::steady_clock::now() - g_started).count()
          : 0;
  const char* name = st == MONEROD_STOPPED  ? "stopped"
                   : st == MONEROD_STARTING ? "starting"
                   : st == MONEROD_RUNNING  ? "running"
                   : st == MONEROD_STOPPING ? "stopping"
                                            : "failed";
  std::ostringstream os;
  os << "{\"state\":\"" << name << "\""
     << ",\"uptimeSecs\":" << uptime
     << ",\"network\":\"" << json_escape(g_network) << "\""
     << ",\"dataDir\":\"" << json_escape(g_data_dir) << "\""
     << ",\"rpcUrl\":\"" << json_escape(g_rpc_url) << "\""
     << ",\"version\":\"" << json_escape(MONERO_VERSION_FULL) << "\""
     << ",\"lastError\":\"" << json_escape(g_error) << "\""
     << ",\"argv\":" << (g_argv_json.empty() ? "[]" : g_argv_json)
     << "}";
  return dup_c(os.str());
}

const char* MONEROD_last_error(void) {
  std::lock_guard<std::mutex> lock(g_mutex);
  return dup_c(g_error);
}

void MONEROD_free(const char* s) { std::free(const_cast<char*>(s)); }

const char* MONEROD_version(void) { return dup_c(MONERO_VERSION_FULL); }

} // extern "C"
