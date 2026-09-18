# Builds the Monero daemon as ONE shared library with a small C ABI.
#
# The whole trick is EXCLUDE_FROM_ALL below: it puts every Monero CMake target in
# scope without building any of them, so `--target monerod_c` compiles exactly the
# static libraries the daemon needs and nothing else. In particular `simplewallet`
# (monero-wallet-cli) is never compiled -- which matters, because that binary is the
# sole reason nixpkgs marks Monero broken on aarch64-darwin:
#
#   "macOS/ARM has a working `monerod` (at least), but `monero-wallet-cli` segfaults
#    on start after entering the wallet password, when built in release mode."
cmake_minimum_required(VERSION 3.16)
project(monerod_c CXX C)

if(NOT DEFINED MONERO_SRC)
  message(FATAL_ERROR "MONERO_SRC must point at the patched monero tree")
endif()

set(CMAKE_CXX_STANDARD 14)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Monero's libraries are static archives that get linked INTO a shared object, so
# every object in the closure has to be position-independent.
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# Keep absolute build paths out of the objects, and do it HERE rather than through
# nix's NIX_CFLAGS_COMPILE. On the Windows target this derivation runs in a native
# stdenv with the mingw compiler merely among its inputs, so NIX_CFLAGS_COMPILE would
# be read by the BUILD compiler and never reach the cross one -- the flag would
# silently not apply, and the only symptom would be a 59 MB source tree reappearing in
# the runtime closure. Setting it in CMake covers every target identically.
#
# Two mappings, because there are two absolute roots: MONERO_SRC (easylogging++ logs
# __FILE__, which embedded 123 store paths) and this shim directory (whose nix build
# path carries a random id, so two builds of identical inputs differed byte-for-byte).
set(_logos_prefix_map "-ffile-prefix-map=${MONERO_SRC}=/monero -ffile-prefix-map=${CMAKE_CURRENT_SOURCE_DIR}=/shim")
set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} ${_logos_prefix_map}")
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} ${_logos_prefix_map}")

add_subdirectory("${MONERO_SRC}" monero_build EXCLUDE_FROM_ALL)

# src/daemon is an executable-only target upstream, so its sources are compiled here
# rather than linked. Everything EXCEPT main.cpp: main() is what this shim replaces.
# The console TUs come along because daemon.cpp references t_command_server for its
# interactive branch -- they are inert with USE_READLINE=OFF and run(false).
set(MONERO_DAEMON_SOURCES
  "${MONERO_SRC}/src/daemon/daemon.cpp"
  "${MONERO_SRC}/src/daemon/executor.cpp"
  "${MONERO_SRC}/src/daemon/command_server.cpp"
  "${MONERO_SRC}/src/daemon/command_parser_executor.cpp"
  "${MONERO_SRC}/src/daemon/rpc_command_executor.cpp"
)

add_library(monerod_c SHARED monerod_c.cpp ${MONERO_DAEMON_SOURCES})

target_compile_definitions(monerod_c PRIVATE MONEROD_C_BUILDING)

target_include_directories(monerod_c PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}"
  "${MONERO_SRC}/src"
  "${MONERO_SRC}/external"
  "${MONERO_SRC}/external/easylogging++"
  "${MONERO_SRC}/external/rapidjson/include"
  # The polyseed patch adds src/polyseed/polyseed.hpp, which reaches into the vendored
  # library's own headers. Monero's targets get this via the polyseed CMake target;
  # the daemon TUs we compile ourselves do not, so it is spelled out here.
  "${MONERO_SRC}/external/polyseed/include"
  "${MONERO_SRC}/external/utf8proc"
  "${MONERO_SRC}/contrib/epee/include"
  "${CMAKE_BINARY_DIR}/monero_build/src"
  "${CMAKE_BINARY_DIR}/monero_build/translations"
)

target_link_libraries(monerod_c PRIVATE
  rpc
  blockchain_db
  cryptonote_core
  cncrypto
  common
  p2p
  cryptonote_protocol
  daemonizer
  serialization
  daemon_rpc_server
  version
  ${Boost_CHRONO_LIBRARY}
  ${Boost_FILESYSTEM_LIBRARY}
  ${Boost_PROGRAM_OPTIONS_LIBRARY}
  ${Boost_REGEX_LIBRARY}
  ${Boost_SYSTEM_LIBRARY}
  ${Boost_THREAD_LIBRARY}
  ${CMAKE_THREAD_LIBS_INIT}
  ${ZMQ_LIB}
  ${EXTRA_LIBRARIES}
  ${Blocks}
)

# Only the MONEROD_* C ABI leaves the library -- enforced by the LINKER export list
# below, and deliberately NOT by -fvisibility=hidden.
#
# Hidden visibility here breaks dynamic_cast. Our daemon TUs would get hidden
# typeinfo while Monero's static libraries keep theirs at default visibility, and
# libc++ compares std::type_info by ADDRESS -- so two copies of the same typeinfo
# make a dynamic_cast fail. MEASURED, not theorised: with the visibility presets set,
# the node started fine, bound its RPC port and accepted TCP connections, and then
# every request died in epee with
#
#   ERROR net abstract_tcp_server2.inl:1633
#   Exception in boosted_tcp_server<t_protocol_handler>::handle_accept: std::bad_cast
#
# (epee's network_address is type-erased and dynamic_casts in the accept path). curl
# reported "Connected" and hung with no response and no error, because monerod's
# default log categories put net at FATAL. The upstream monerod binary -- an
# executable, so one copy of each typeinfo -- answers the same request immediately.
#
# The export list is authoritative on both platforms, so nothing is lost: -Wl,
# -exported_symbols_list on Mach-O and a version script with `local: *;` on ELF both
# restrict the dynamic symbol table by themselves.

if(APPLE)
  target_link_options(monerod_c PRIVATE
    "-Wl,-exported_symbols_list,${CMAKE_CURRENT_SOURCE_DIR}/monerod_c.exp")
  set_target_properties(monerod_c PROPERTIES
    LINK_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/monerod_c.exp")
elseif(MINGW)
  # PE has no version script -- a DLL's export table comes from __declspec(dllexport),
  # which monerod_c.h applies through MONEROD_API under MONEROD_C_BUILDING. Passing
  # --version-script here would be an ELF mechanism aimed at a PE link. Marking any
  # symbol dllexport also stops mingw's ld from falling back to auto-exporting
  # everything, so the 7 are the whole export table; --exclude-libs keeps the static
  # archives we swallow from re-exporting theirs.
  target_link_options(monerod_c PRIVATE "-Wl,--exclude-libs,ALL")
else()
  target_link_options(monerod_c PRIVATE
    "-Wl,--version-script,${CMAKE_CURRENT_SOURCE_DIR}/monerod_c.map"
    "-Wl,--exclude-libs,ALL")
  set_target_properties(monerod_c PROPERTIES
    LINK_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/monerod_c.map")
endif()

if(MINGW)
  # Matching monero_c's own mingw link options, so the DLL we produce has the same
  # shape as the prebuilt it replaces. Static libgcc/libstdc++ keeps two more DLLs out
  # of the import table -- nix-bundle-lgx's windowsHostLibs does claim libstdc++-*.dll
  # and libgcc_s_*.dll, so this is not strictly required, but the prebuilt imports
  # neither and matching it is one less thing for the payload gate to argue about.
  target_link_options(monerod_c PRIVATE -static-libgcc -static-libstdc++)
  target_link_options(monerod_c PRIVATE "-Wl,--section-alignment,16384")
endif()

install(TARGETS monerod_c
  LIBRARY DESTINATION lib
  RUNTIME DESTINATION bin
  ARCHIVE DESTINATION lib)
install(FILES monerod_c.h DESTINATION include)

# external/polyseed builds SHARED unless monero's global STATIC option is on, and the
# link records an absolute path to it inside our own prefix -- so an uninstalled
# polyseed means libmonerod_c loads nowhere. Install whatever shared libraries the
# monero subtree produced alongside ours rather than guessing at the list.
install(DIRECTORY "${CMAKE_BINARY_DIR}/monero_build/external/polyseed/"
        DESTINATION lib
        FILES_MATCHING PATTERN "libpolyseed*")
