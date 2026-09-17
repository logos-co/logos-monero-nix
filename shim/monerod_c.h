// C ABI over daemonize::t_daemon — the Monero node, in-process, as a shared library.
//
// Upstream ships src/daemon only as the monerod EXECUTABLE (monero_add_executable,
// OUTPUT_NAME "monerod"), and nobody publishes the daemon as a library, so this is the
// whole of the surface. It replaces src/daemon/main.cpp: everything main() does that
// only makes sense for a standalone process is deliberately absent — see monerod_c.cpp.
//
// STRING OWNERSHIP IS UNIFORM: every `const char*` returned by this header is
// heap-allocated and belongs to the caller, who must release it with MONEROD_free().
// That is stated per-function below and it is uniform on purpose — the last time this
// family guessed at per-function C-ABI string ownership it cost two engine aborts
// during live sends.
//
// ONE DAEMON PER PROCESS. Monero's logging (easylogging++) is process-global and the
// P2P/RPC ports are bound once, so these functions drive a single daemon instance.
#ifndef LOGOS_MONEROD_C_H
#define LOGOS_MONEROD_C_H

#ifdef __cplusplus
extern "C" {
#endif

// The library is compiled with hidden visibility so that Monero's, boost's and
// OpenSSL's symbols do not leave it. Hidden beats an -exported_symbols_list, though:
// without marking the API itself default-visible the link succeeds and the result
// exports NOTHING -- measured, `nm -gU` returned 0 symbols on the first build.
#ifndef MONEROD_API
#  if defined(_WIN32) || defined(__CYGWIN__)
#    ifdef MONEROD_C_BUILDING
#      define MONEROD_API __declspec(dllexport)
#    else
#      define MONEROD_API __declspec(dllimport)
#    endif
#  else
#    define MONEROD_API __attribute__((visibility("default")))
#  endif
#endif

/// Lifecycle states, as reported by MONEROD_state().
enum MONEROD_State {
  MONEROD_STOPPED  = 0,
  MONEROD_STARTING = 1,
  MONEROD_RUNNING  = 2,
  MONEROD_STOPPING = 3,
  MONEROD_FAILED   = 4
};

/// Start the node and RETURN IMMEDIATELY. `argv_json` is a JSON array of monerod
/// flags, e.g. ["--stagenet","--data-dir=/…","--rpc-bind-port=38081"]; a leading
/// program name is neither expected nor required. The daemon runs on its own thread.
///
/// Returns 0 when the daemon thread was started, non-zero when the arguments could
/// not be parsed or a daemon is already running — MONEROD_last_error() says which.
/// A start that fails AFTER this returns (a port already bound, a corrupt database)
/// surfaces as MONEROD_FAILED from MONEROD_state().
MONEROD_API int MONEROD_start(const char* argv_json);

/// Ask the node to stop and wait for its thread to join. Idempotent, and safe to call
/// from a thread other than the one that called MONEROD_start().
///
/// This can take longer than a caller's teardown budget: the node flushes LMDB and
/// saves the tx pool on the way out. Under logos_host the module gets 3000 ms before
/// the host proceeds without it, so call this EARLY and report MONEROD_STOPPING while
/// it runs. A hard kill mid-flush is survivable — LMDB is crash-safe — but costs a
/// long consistency check on the next start.
MONEROD_API void MONEROD_stop(void);

/// Current lifecycle state, one of MONEROD_State. Cheap; safe from any thread.
MONEROD_API int MONEROD_state(void);

/// What this shim itself knows, as a JSON object: state, uptimeSecs, dataDir, network,
/// rpcUrl, version, and the argv it was started with.
///
/// Deliberately NOT height/target/peers. t_daemon keeps its internals in a private
/// std::unique_ptr<t_internals> behind an opaque forward declaration, so reaching
/// cryptonote::core from here would mean carrying our own patch to daemon.h. Chain
/// state instead comes from monero_node_module's ordinary get_info over loopback —
/// the same path it already uses for a remote node, which is what makes the wallet's
/// Local and Remote modes render through one code path.
///
/// CALLER OWNS THE RESULT — release it with MONEROD_free(). Never NULL.
MONEROD_API const char* MONEROD_status_json(void);

/// The last error, or an empty string when there is none.
/// CALLER OWNS THE RESULT — release it with MONEROD_free(). Never NULL.
MONEROD_API const char* MONEROD_last_error(void);

/// Release a string returned by any function in this header. NULL is a no-op.
MONEROD_API void MONEROD_free(const char* s);

/// The Monero version this library was built from, e.g. "0.18.4.6-RC2".
/// CALLER OWNS THE RESULT — release it with MONEROD_free(). Never NULL.
MONEROD_API const char* MONEROD_version(void);

#ifdef __cplusplus
}
#endif

#endif // LOGOS_MONEROD_C_H
