# Monero's daemon as one shared library with a C ABI. EXCLUDE_FROM_ALL builds only
# what monerod_c needs, so simplewallet (broken on aarch64-darwin) is never compiled.
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

# Strip absolute source/build paths from __FILE__. Set here, not via NIX_CFLAGS_COMPILE,
# which never reaches the cross compiler on the Windows branch.
set(_logos_prefix_map "-ffile-prefix-map=${MONERO_SRC}=/monero -ffile-prefix-map=${CMAKE_CURRENT_SOURCE_DIR}=/shim")
set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} ${_logos_prefix_map}")
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} ${_logos_prefix_map}")

add_subdirectory("${MONERO_SRC}" monero_build EXCLUDE_FROM_ALL)

# src/daemon is executable-only upstream, so compile it here: minus main.cpp (the shim)
# and minus the console TUs, which patch 0002 compiles out.
set(MONERO_DAEMON_SOURCES
  "${MONERO_SRC}/src/daemon/daemon.cpp"
  "${MONERO_SRC}/src/daemon/executor.cpp"
)

add_library(monerod_c SHARED monerod_c.cpp ${MONERO_DAEMON_SOURCES})

target_compile_definitions(monerod_c PRIVATE MONEROD_C_BUILDING MONERO_NO_INTERACTIVE_CONSOLE
  MONERO_NO_SIGNAL_HANDLER)

target_include_directories(monerod_c PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}"
  "${MONERO_SRC}/src"
  "${MONERO_SRC}/external"
  "${MONERO_SRC}/external/easylogging++"
  "${MONERO_SRC}/external/rapidjson/include"
  # polyseed.hpp reaches into the vendored library's headers.
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

# Exports are restricted by the linker list, not -fvisibility=hidden: hidden typeinfo
# here vs default in Monero's archives made dynamic_cast throw std::bad_cast.

if(APPLE)
  target_link_options(monerod_c PRIVATE
    "-Wl,-exported_symbols_list,${CMAKE_CURRENT_SOURCE_DIR}/monerod_c.exp")
  set_target_properties(monerod_c PROPERTIES
    LINK_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/monerod_c.exp")
elseif(MINGW)
  # Monero sets WIN32_LEAN_AND_MEAN only in its own scope; without it winsock.h arrives
  # before asio's winsock2.h.
  target_compile_definitions(monerod_c PRIVATE WIN32_LEAN_AND_MEAN)

  # Patch 0018 makes mingw's ICU_LIBRARIES a bare `iconv`, so the link needs this dir.
  if(LOGOS_DEPENDS_LIB)
    target_link_directories(monerod_c PRIVATE "${LOGOS_DEPENDS_LIB}")
  endif()

  # PE exports come from __declspec(dllexport), not a version script.
  target_link_options(monerod_c PRIVATE "-Wl,--exclude-libs,ALL")
else()
  target_link_options(monerod_c PRIVATE
    "-Wl,--version-script,${CMAKE_CURRENT_SOURCE_DIR}/monerod_c.map"
    "-Wl,--exclude-libs,ALL")
  set_target_properties(monerod_c PROPERTIES
    LINK_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/monerod_c.map")
endif()

if(MINGW)
  # Same mingw link options as monero_c, so the DLL has the prebuilt's shape.
  target_link_options(monerod_c PRIVATE -static-libgcc -static-libstdc++)
  target_link_options(monerod_c PRIVATE "-Wl,--section-alignment,16384")
endif()

install(TARGETS monerod_c
  LIBRARY DESTINATION lib
  RUNTIME DESTINATION bin
  ARCHIVE DESTINATION lib)
install(FILES monerod_c.h DESTINATION include)

# polyseed builds SHARED unless Monero's STATIC is on, and we link it by absolute path.
install(DIRECTORY "${CMAKE_BINARY_DIR}/monero_build/external/polyseed/"
        DESTINATION lib
        FILES_MATCHING PATTERN "libpolyseed*")
