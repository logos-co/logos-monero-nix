# Builds monero_c's wallet2 C ABI from our patched tree, replacing the prebuilt
# release-bundle.zip that logos-monero-wallet-core-module used to fetch.
#
# The SOURCES are monero_c's, staged in the tree at .logos/wallet2_shim by
# nix/monero-src.nix -- deliberately not copied into this repo, so the monero_c pin
# owns them and a version bump cannot leave a stale duplicate behind. This file is a
# nix-native replacement for monero_c's own CMakeLists, whose MONERO_DIR /
# EXTERNAL_LIBS_DIR expect a contrib/depends layout we do not use.
#
# The contract is the 354-symbol export list. Anything that changes it breaks
# logos-monero-wallet-core-module, so the derivation diffs the built library's exports
# against the .exp and against the prebuilt.
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

# GLOBALLY, and before add_subdirectory -- exactly where monero_c puts it, and the
# distinction matters. Setting hidden visibility as a TARGET property instead (which is
# what libmonerod_c first did) leaves Monero's static archives at default visibility
# while our own TUs go hidden; libc++ compares std::type_info by address, and the two
# copies of one typeinfo then make dynamic_cast throw std::bad_cast at runtime. Applied
# to the whole tree there is one consistent copy and RTTI is fine -- which is why the
# prebuilt this replaces was built this way and works.
set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -fvisibility=hidden")
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -fvisibility=hidden")

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

# wallet_api links its dependencies PUBLIC, so this pulls wallet, cryptonote_core,
# mnemonics, lmdb, boost (incl. locale) and ICU along with it. bc-ur arrives the same
# way, via src/wallet.
target_link_libraries(monero_wallet2_api_c PRIVATE
  wallet_api
  ${wallet_api_LIB_DEPENDS}
)

if(APPLE)
  set(EXP "${SHIM}/monero_libwallet2_api_c.exp")
  # Via CMAKE_SHARED_LINKER_FLAGS, which is where monero_c puts it. A
  # target_link_options("-Wl,-exported_symbols_list,...") did NOT reach the link line
  # here, and the failure mode is quiet: the library still links and still exports all
  # 354 required symbols, just with 11 extras riding along (JH hash constants,
  # MONERO_RELEASE_NAME, and MONERO_PendingTransaction_txKey -- which monero_c's own
  # .exp omits, so the prebuilt does not export it either). Only the symbol diff
  # caught it.
  set(CMAKE_SHARED_LINKER_FLAGS "${CMAKE_SHARED_LINKER_FLAGS} -exported_symbols_list ${EXP}")
  set_target_properties(monero_wallet2_api_c PROPERTIES LINK_DEPENDS "${EXP}")
else()
  # monero_c uses --exclude-libs,ALL here rather than a version script. Keep that:
  # the export surface has to match the prebuilt symbol for symbol, and the .exp is
  # Mach-O-only, so ELF relies on hidden visibility plus this.
  target_link_options(monero_wallet2_api_c PRIVATE "-Wl,--exclude-libs,ALL")
endif()

if(MINGW)
  # Matching monero_c's own mingw link options, so the DLL we produce has the same
  # shape as the prebuilt it replaces. Static libgcc/libstdc++ keeps two more DLLs out
  # of the import table -- nix-bundle-lgx's windowsHostLibs does claim libstdc++-*.dll
  # and libgcc_s_*.dll, so this is not strictly required, but the prebuilt imports
  # neither and matching it is one less thing for the payload gate to argue about.
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
