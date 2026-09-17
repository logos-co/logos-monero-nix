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

#include <boost/filesystem.hpp>
#include <boost/program_options.hpp>

#include <openssl/ssl.h>

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

namespace po = boost::program_options;
namespace bf = boost::filesystem;

namespace {

// ---------------------------------------------------------------------------
// What this shim deliberately does NOT do, all of which src/daemon/main.cpp does.
// Each one is a behaviour that only makes sense for a standalone process:
//
//   * daemonizer::init_options / daemonizer::daemonize — fork, --detach, pidfile.
//     We ARE the process the caller wants; forking would orphan the node from the
//     module that is supposed to own its lifetime.
//   * tools::signal_handler::install — would steal SIGINT/SIGTERM from the module
//     host, whose own shutdown path is how MONEROD_stop() gets called in the first
//     place. Installing a handler here is how an in-process node hijacks its host.
//   * config-file parsing (--config-file) — the module owns configuration and
//     persists it itself; two sources of truth for the same settings is a bug.
//   * arg_command positional handling — that is the `monerod status` CLI, which
//     talks to a daemon over RPC rather than being one.
//   * parse_public_rpc_port / --public-node — a public node advertises itself to the
//     network. Nothing here should do that on a user's machine without being asked,
//     so public_rpc_port is hard-wired to 0.
//   * STACK_TRACE — not built.
// ---------------------------------------------------------------------------

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

// easylogging++ installs process-global state, so configuring it twice in one process
// is at best wasted work and at worst a surprise for whoever configured it first.
bool g_log_configured = false;

// The process-wide setup monerod does in main() via tools::on_startup(), minus the one
// part of it a LIBRARY must not do.
//
// Skipping this is not theoretical: without OPENSSL_init_ssl the RPC server binds,
// accepts the TCP connection and then never answers -- monerod defaults to
// --rpc-ssl=autodetect, so epee sniffs every incoming connection for TLS, and with
// OpenSSL uninitialised that sniff stalls. curl reports "Connected" and hangs, and
// nothing is logged because monerod's default categories put net.ssl at FATAL.
// Measured against the upstream monerod binary with identical flags, which answers
// get_info immediately.
//
// tools::on_startup() is NOT called, because it also calls setup_crash_dump(), which
// on POSIX installs SIGSEGV and SIGBUS handlers that _exit(1). In a module host that
// would replace the host's own crash handling and kill it without its teardown ever
// running -- the same reason this shim installs no SIGINT/SIGTERM handler.
void library_startup_once() {
  static std::once_flag once;
  std::call_once(once, [] {
    // boost::filesystem throws on "invalid" locales such as en_US.UTF-8, and this
    // shim calls bf::absolute() below, so it has to come first.
    tools::sanitize_locale();
    epee::string_tools::set_module_name_and_folder("monerod");
#if OPENSSL_VERSION_NUMBER < 0x10100000 || defined(LIBRESSL_VERSION_TEXT)
    SSL_library_init();
#else
    OPENSSL_init_ssl(0, NULL);
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

// A deliberately small JSON string escaper. Pulling nlohmann in here would mean
// another include path in five cross builds for what is six characters of escaping.
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

// Minimal JSON-array-of-strings parser for argv_json. The module hands us a flag list
// it built itself, so this does not need to be a general JSON parser -- but it DOES
// need to reject anything it does not fully understand rather than silently dropping a
// flag, because a dropped --stagenet means a node that syncs mainnet by surprise.
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
    // The option set monerod itself registers, minus the process-only groups listed
    // at the top of this file. t_executor::init_options is what pulls in core, p2p
    // and rpc -- everything t_daemon reads out of the variables_map.
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
      // console=FALSE, deliberately. A module host relays its child's stdout/stderr,
      // and monerod at log-level 0 still narrates startup -- interleaving that into
      // the host's own stream is noise at best. The log file is what the daemon
      // module's logTail() reads and what the UI shows.
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

    // public_rpc_port = 0: never advertise as a public node. See the note above.
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
    // run() returning false is a startup failure -- a bound port, an unreadable
    // database -- and it must not read as a clean stop, or the UI shows "stopped"
    // for a node that never came up and the user has nothing to act on.
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
      // stop_p2p(), NOT stop(). t_daemon::stop() ends with
      // `mp_internals.reset(nullptr)`, which destroys the core, p2p and rpc objects
      // that run() is still using on the daemon thread -- a reliable SIGSEGV, and
      // the node log shows exactly why: "Stopping/Deinitializing core RPC server"
      // appearing on the CALLER's thread while the daemon thread is independently
      // unwinding the same objects. stop_p2p() only signals; p2p.run() returns,
      // run() does its own orderly teardown, and the destructor below -- after the
      // join -- releases the internals on one thread. Upstream does all of this on
      // one thread, which is why it never needed the distinction.
      if (g_daemon) g_daemon->stop_p2p();
    }
    to_join = std::move(g_thread);
  }
  // Joined OUTSIDE the lock: the daemon thread takes g_mutex on its way out, so
  // holding it here would deadlock the very thread we are waiting for.
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
