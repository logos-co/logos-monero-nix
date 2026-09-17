# libmonerod_c: the Monero daemon as a shared library with a C ABI.
#
# Built from the same patched tree as the wallet2 library (nix/monero-src.nix), which
# is what makes this cheap -- the daemon links static archives that tree already has to
# produce, so there is no second Monero build.
{ pkgs, moneroSrc, shimSrc }:

let
  inherit (pkgs) lib stdenv;
in
stdenv.mkDerivation {
  pname = "monerod_c";
  version = moneroSrc.version;

  src = shimSrc;

  nativeBuildInputs = [ pkgs.cmake pkgs.pkg-config ];

  buildInputs = [
    pkgs.boost186      # monero wants boost/asio/io_service.hpp, removed after 1.86
    pkgs.libsodium
    pkgs.openssl
    pkgs.unbound       # DNS; monero has no unbound submodule, so it comes from here
    pkgs.zeromq
  ] ++ lib.optionals stdenv.hostPlatform.isWindows [
    # nixpkgs builds mingw-w64 against mcfgthread, so pthread.h exists nowhere in the
    # default closure -- and monero's vendored C assumes POSIX threads regardless. The
    # same line appears in three other repos here for the same reason.
    pkgs.windows.pthreads
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
  ] ++ lib.optional stdenv.hostPlatform.isDarwin "-DBoost_USE_MULTITHREADED=OFF";

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
