# libmonerod_c: Monero's daemon as a shared library with a C ABI.
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
  pname = "monerod_c";
  version = moneroSrc.version;

  src = shimSrc;

  nativeBuildInputs =
    (if isWin then [ bp.cmake bp.pkg-config pkgs.stdenv.cc pkgs.stdenv.cc.bintools ]
              else [ pkgs.cmake pkgs.pkg-config ]);

  buildInputs = lib.optionals (!isWin) [
    pkgs.boost186      # monero wants boost/asio/io_service.hpp, removed after 1.86
    pkgs.libsodium
    pkgs.openssl
    pkgs.unbound       # DNS; monero has no unbound submodule, so it comes from here
    pkgs.zeromq
  ];

  cmakeFlags = [
    "-DMONERO_SRC=${moneroSrc}"
    # Our tree has no .git (nix/monero-src.nix strips it), so monero must not try to
    # run `git submodule update`. The submodules are already materialised in-tree.
    "-DMANUAL_SUBMODULES=ON"
    "-DCMAKE_POSITION_INDEPENDENT_CODE=ON"
    # The interactive console is compiled but never entered (run(false)), and readline
    # is a dependency we would otherwise carry into five cross builds for nothing.
    "-DUSE_READLINE=OFF"
    # Trezor drags in protobuf, libusb, hidapi and -- on Linux -- udev, for a hardware
    # wallet a NODE has no use for.
    "-DUSE_DEVICE_TREZOR=OFF"
    "-DBUILD_TESTS=OFF"
    "-DBUILD_DOCUMENTATION=OFF"
    # libunwind has no mingw port, and a node does not need to dump stacks.
    "-DSTACK_TRACE=OFF"
    "-Wno-dev"
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

  # Build ONLY our target: this is what keeps simplewallet (and the tests, and the
  # blockchain utilities) out of the build entirely.
  ninjaFlags = [ "monerod_c" ];
  buildFlags = [ "monerod_c" ];

  # A macOS linker-signed binary is invalidated by strip, and a stripped Mach-O with a
  # broken ad-hoc signature refuses to load rather than failing loudly at link time.
  dontStrip = true;

  postInstall = ''
    # BSD-3 and LGPL-3.0 notices; lib/ is where module staging looks.
    install -m0644 ${moneroSrc}/LICENSE "$out/lib/LICENSE.monero"
    install -m0644 ${moneroSrc}/.logos/LICENSE.monero_c "$out/lib/LICENSE.monero_c"
  '';

  meta = {
    description = "Monero daemon (monerod) as a shared library with a C ABI";
    license = [ pkgs.lib.licenses.bsd3 pkgs.lib.licenses.lgpl3Only ];
  };
}
