# monero_c's wallet2 C ABI built from our tree; replaces the prebuilt release bundle.
# The contract is its 354-symbol export list.
cmake_minimum_required(VERSION 3.16)
project(monero_wallet2_api_c CXX C)

if(NOT DEFINED MONERO_SRC)
  message(FATAL_ERROR "MONERO_SRC must point at the patched monero tree")
endif()

set(SHIM "${MONERO_SRC}/.logos/wallet2_shim")

# 11, matching monero_c: this is wallet2_api's own standard and the shim is written to it.
set(CMAKE_CXX_STANDARD 11)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# Globally and before add_subdirectory, as monero_c does: one consistent visibility
# keeps typeinfo unique, so dynamic_cast works.
set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -fvisibility=hidden")
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -fvisibility=hidden")

# Strip absolute source/build paths from __FILE__. Set here, not via NIX_CFLAGS_COMPILE,
# which never reaches the cross compiler on the Windows branch.
set(_logos_prefix_map "-ffile-prefix-map=${MONERO_SRC}=/monero -ffile-prefix-map=${CMAKE_CURRENT_SOURCE_DIR}=/shim")
set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} ${_logos_prefix_map}")
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} ${_logos_prefix_map}")

# Monero's STATIC (set by depends' toolchain on Windows) makes polyseed an archive, and its
# header drops dllimport only under POLYSEED_STATIC, which monero_c's toolchain sets globally.
if(STATIC)
  add_compile_definitions(POLYSEED_STATIC)
endif()

add_subdirectory("${MONERO_SRC}" monero_build EXCLUDE_FROM_ALL)

add_library(monero_wallet2_api_c SHARED
  "${SHIM}/src/main/cpp/helpers.cpp"
  "${SHIM}/src/main/cpp/monero_wallet2_api_c.cpp"
  "${SHIM}/src/main/cpp/monero_checksum.c"
)

target_compile_definitions(monero_wallet2_api_c PRIVATE FLAVOR_MONERO)

target_include_directories(monero_wallet2_api_c PRIVATE
  "${SHIM}/src/main/cpp"
  "${MONERO_SRC}/src"
  "${MONERO_SRC}/external"
  "${MONERO_SRC}/external/easylogging++"
  "${MONERO_SRC}/external/rapidjson/include"
  "${MONERO_SRC}/external/polyseed/include"
  "${MONERO_SRC}/contrib/epee/include"
  "${CMAKE_BINARY_DIR}/monero_build/src"
  "${CMAKE_BINARY_DIR}/monero_build/translations"
)

# wallet_api links its deps PUBLIC (wallet, core, boost, ICU, bc-ur).
target_link_libraries(monero_wallet2_api_c PRIVATE
  wallet_api
  ${wallet_api_LIB_DEPENDS}
)

if(APPLE)
  set(EXP "${SHIM}/monero_libwallet2_api_c.exp")
  # Via CMAKE_SHARED_LINKER_FLAGS, as monero_c does; target_link_options never reached
  # the link line.
  set(CMAKE_SHARED_LINKER_FLAGS "${CMAKE_SHARED_LINKER_FLAGS} -exported_symbols_list ${EXP}")
  set_target_properties(monero_wallet2_api_c PROPERTIES LINK_DEPENDS "${EXP}")
else()
  # ELF has no .exp: hidden visibility plus --exclude-libs, as monero_c does.
  target_link_options(monero_wallet2_api_c PRIVATE "-Wl,--exclude-libs,ALL")
endif()

if(MINGW)
  # Monero sets WIN32_LEAN_AND_MEAN only in its own scope; without it winsock.h arrives
  # before asio's winsock2.h.
  target_compile_definitions(monero_wallet2_api_c PRIVATE WIN32_LEAN_AND_MEAN)

  # Patch 0018 makes mingw's ICU_LIBRARIES a bare `iconv`, so the link needs this dir.
  if(LOGOS_DEPENDS_LIB)
    target_link_directories(monero_wallet2_api_c PRIVATE "${LOGOS_DEPENDS_LIB}")
  endif()

  # Same mingw link options as monero_c, so the DLL has the prebuilt's shape.
  target_link_options(monero_wallet2_api_c PRIVATE -static-libgcc -static-libstdc++)
  target_link_options(monero_wallet2_api_c PRIVATE "-Wl,--section-alignment,16384")
endif()

install(TARGETS monero_wallet2_api_c
  LIBRARY DESTINATION lib
  RUNTIME DESTINATION bin
  ARCHIVE DESTINATION lib)
install(FILES
  "${SHIM}/src/main/cpp/monero_wallet2_api_c.h"
  "${SHIM}/src/main/cpp/monero_checksum.h"
  DESTINATION include)
