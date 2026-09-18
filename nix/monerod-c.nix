# libmonerod_c: the Monero daemon as a shared library with a C ABI.
#
# Built from the same patched tree as the wallet2 library (nix/monero-src.nix), which
# is what makes this cheap -- the daemon links static archives that tree already has to
# produce, so there is no second Monero build.
{ pkgs, moneroSrc, shimSrc, depends ? null }:

let
  inherit (pkgs) lib;

  # x86_64-windows takes a different route entirely: Monero's own contrib/depends
  # prefix supplies boost, openssl, zeromq, unbound, expat, libiconv and sodium, plus
  # a toolchain.cmake that points CMake at them. nixpkgs' mingw set does not build --
  # see nix/monero-depends.nix for what fails and why -- and depends is how Monero
  # officially ships Windows.
  #
  # That makes the Windows build a NATIVE derivation that happens to emit PE objects:
  # it runs on the build platform with the cross toolchain among its inputs, exactly
  # as the depends build itself does. So the stdenv, cmake and pkg-config all come
  # from buildPackages, and none of the nixpkgs dependency set is used.
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
    # Supplies CMAKE_SYSTEM_NAME, the cross compilers, CMAKE_FIND_ROOT_PATH and
    # BOOST_ROOT/ZMQ_LIB/UNBOUND_LIBRARIES pointing at depends' static prefix.
    # It also sets STATIC ON, which is what gives Windows one self-contained DLL
    # instead of a payload full of nix-built dependency DLLs.
    "-DCMAKE_TOOLCHAIN_FILE=${depends}/share/toolchain.cmake"
  ] ++ lib.optional pkgs.stdenv.hostPlatform.isDarwin "-DBoost_USE_MULTITHREADED=OFF";

  # Build ONLY our target: this is what keeps simplewallet (and the tests, and the
  # blockchain utilities) out of the build entirely.
  # __FILE__ is what drags the whole 59 MB source tree into this library's RUNTIME
  # closure, and from there into every consumer and the .lgx payload: easylogging++
  # logs __FILE__, so the compiled TUs embed 123 absolute store paths and nix records
  # a reference for each. Rewriting the prefix drops the reference and makes the log
  # lines read /monero/src/... instead of a store hash, which is also easier to read.
  env.NIX_CFLAGS_COMPILE = "-ffile-prefix-map=${moneroSrc}=/monero";

  ninjaFlags = [ "monerod_c" ];
  buildFlags = [ "monerod_c" ];

  # A macOS linker-signed binary is invalidated by strip, and a stripped Mach-O with a
  # broken ad-hoc signature refuses to load rather than failing loudly at link time.
  dontStrip = true;

  postInstall = ''
    # Monero is BSD-3-Clause and monero_c's patches are LGPL-3.0, so the licence text
    # has to travel with the library. lib/ rather than share/: that is the only place
    # logos-module-builder's `include` staging looks when it copies runtime files
    # beside a plugin.
    install -m0644 ${moneroSrc}/LICENSE "$out/lib/LICENSE.monero"
    install -m0644 ${moneroSrc}/.logos/LICENSE.monero_c "$out/lib/LICENSE.monero_c"
  '';

  meta = {
    description = "Monero daemon (monerod) as a shared library with a C ABI";
    license = [ pkgs.lib.licenses.bsd3 pkgs.lib.licenses.lgpl3Only ];
  };
}
