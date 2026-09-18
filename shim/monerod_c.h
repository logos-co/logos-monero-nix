// C ABI over daemonize::t_daemon: the Monero node, in-process, as a shared library.
// Every returned `const char*` is owned by the caller; release it with MONEROD_free().
#ifndef LOGOS_MONEROD_C_H
#define LOGOS_MONEROD_C_H

#ifdef __cplusplus
extern "C" {
#endif

// Hidden visibility would otherwise hide the API itself.
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

enum MONEROD_State {
  MONEROD_STOPPED  = 0,
  MONEROD_STARTING = 1,
  MONEROD_RUNNING  = 2,
  MONEROD_STOPPING = 3,
  MONEROD_FAILED   = 4
};

// Starts the node on its own thread and returns at once. `argv_json` is a JSON array
// of monerod flags. Non-zero means refused; see MONEROD_last_error().
MONEROD_API int MONEROD_start(const char* argv_json);

// Signals the node, joins its thread, then releases it. Idempotent; any thread.
MONEROD_API void MONEROD_stop(void);

MONEROD_API int MONEROD_state(void);

// State, uptime, network, data dir, RPC URL and version as JSON. Chain state (height,
// peers) comes from the node's own RPC instead.
MONEROD_API const char* MONEROD_status_json(void);

MONEROD_API const char* MONEROD_last_error(void);
MONEROD_API void MONEROD_free(const char* s);
MONEROD_API const char* MONEROD_version(void);

#ifdef __cplusplus
}
#endif

#endif // LOGOS_MONEROD_C_H
