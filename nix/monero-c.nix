# monero_c's wallet2 C ABI from source, replacing the prebuilt release bundle.
# LGPL-3.0: it stays a separate, replaceable shared object.
{ pkgs, moneroSrc, shimSrc, depends ? null }:

let
  inherit (pkgs) lib;

  # Windows builds natively-on-linux against Monero's contrib/depends prefix, since
  # nixpkgs' mingw set does not build (see nix/monero-depends.nix).
  isWin = pkgs.pkgs.stdenv.hostPlatform.isWindows;
  bp = pkgs.buildPackages;
  stdenv' = if isWin then bp.stdenv else pkgs.stdenv;
in
stdenv'.mkDerivation {
  pname = "monero_wallet2_api_c";
  version = moneroSrc.version;

  src = shimSrc;

  nativeBuildInputs =
    (if isWin then [ bp.cmake bp.pkg-config pkgs.stdenv.cc pkgs.stdenv.cc.bintools ]
              else [ pkgs.cmake pkgs.pkg-config ]);

  buildInputs = lib.optionals (!isWin) [
    pkgs.boost186      # wallet_api wants Boost_LOCALE_LIBRARY as well as the usual set
    pkgs.icu           # boost::locale's backend, and wallet_api links ICU_LIBRARIES
    pkgs.libsodium
    pkgs.openssl
    pkgs.unbound
    pkgs.zeromq
  ];

  cmakeFlags = [
    "-DMONERO_SRC=${moneroSrc}"
    "-DMANUAL_SUBMODULES=ON"
    "-DCMAKE_POSITION_INDEPENDENT_CODE=ON"
    "-DUSE_READLINE=OFF"
    "-DUSE_DEVICE_TREZOR=OFF"
    "-DBUILD_TESTS=OFF"
    "-DBUILD_DOCUMENTATION=OFF"
    "-DSTACK_TRACE=OFF"
    "-Wno-dev"
  ] ++ lib.optionals (!isWin) [
    # Static zmq: the portable bundler rewrote a dynamic libzmq to @rpath and never copied it.
    "-DZMQ_LIB=${pkgs.zeromq}/lib/libzmq.a"
  ] ++ lib.optionals isWin [
    # Cross compilers, find-root and static dependency paths; STATIC ON gives one DLL.
    "-DCMAKE_TOOLCHAIN_FILE=${depends}/share/toolchain.cmake"
    # nixpkgs' cmake hook injects the native gcc; restating the cross tools last wins.
    "-DCMAKE_C_COMPILER=${pkgs.stdenv.cc}/bin/${pkgs.stdenv.cc.targetPrefix}gcc"
    "-DCMAKE_CXX_COMPILER=${pkgs.stdenv.cc}/bin/${pkgs.stdenv.cc.targetPrefix}g++"
    "-DCMAKE_AR=${pkgs.stdenv.cc.bintools.bintools}/bin/${pkgs.stdenv.cc.targetPrefix}ar"
    "-DCMAKE_RANLIB=${pkgs.stdenv.cc.bintools.bintools}/bin/${pkgs.stdenv.cc.targetPrefix}ranlib"
    "-DCMAKE_STRIP=${pkgs.stdenv.cc.bintools.bintools}/bin/${pkgs.stdenv.cc.targetPrefix}strip"
    "-DCMAKE_RC_COMPILER=${pkgs.stdenv.cc.bintools.bintools}/bin/${pkgs.stdenv.cc.targetPrefix}windres"
    # depends hard-sets zmq/unbound but not sodium, and FIND_ROOT_PATH_MODE=ONLY makes
    # <prefix>/lib unreachable by search.
    "-DSODIUM_LIBRARY=${depends}/lib/libsodium.a"
    "-DSODIUM_INCLUDE_PATH=${depends}/include"
    "-DLOGOS_DEPENDS_LIB=${depends}/lib"
  ] ++ lib.optional pkgs.stdenv.hostPlatform.isDarwin "-DBoost_USE_MULTITHREADED=OFF";

  ninjaFlags = [ "monero_wallet2_api_c" ];
  buildFlags = [ "monero_wallet2_api_c" ];

  dontStrip = true;

  # The 354 exports are wallet-core's contract. cctools nm, not GNU nm, which reads the
  # symbol table rather than dyld's exports.
  doInstallCheck = pkgs.stdenv.hostPlatform.isDarwin && !pkgs.stdenv.hostPlatform.isWindows;
  installCheckPhase = ''
    runHook preInstallCheck
    lib=$out/lib/libmonero_wallet2_api_c.dylib
    nm -gU "$lib" 2>/dev/null \
      | awk '{print $3}' | sed 's/^_//' | sort -u > got.txt
    sort -u < ${moneroSrc}/.logos/wallet2_shim/monero_libwallet2_api_c.exp \
      | sed 's/^_//' > want.txt
    if ! diff -u want.txt got.txt > sym.diff; then
      echo "ERROR: exported symbols do not match monero_c's export list." >&2
      echo "  Every symbol here is API that logos-monero-wallet-core-module calls," >&2
      echo "  so a difference in either direction is a break, not a detail." >&2
      head -40 sym.diff >&2
      exit 1
    fi
    echo "exports match monero_c's list exactly ($(wc -l < want.txt | tr -d ' ') symbols)"
    runHook postInstallCheck
  '';

  postInstall = ''
    # LGPL-3.0 notice beside the library; lib/ is where module staging looks.
    install -m0644 ${moneroSrc}/LICENSE "$out/lib/LICENSE.monero"
    install -m0644 ${moneroSrc}/.logos/LICENSE.monero_c "$out/lib/LICENSE.monero_c"
  '';

  meta = {
    description = "monero_c wallet2 C ABI, built from source (354-symbol contract)";
    license = [ pkgs.lib.licenses.bsd3 pkgs.lib.licenses.lgpl3Only ];
  };
}
