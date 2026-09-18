# Monero's own contrib/depends, built hermetically, for the Windows target only.
#
# WHY, measured at P2: the nixpkgs mingw package set does not build. boost 1.86 dies in
# Boost.Process's Jamfile ("Unable to find file or target named
# .../libs/process/build//advapi32"); zeromq 4.3.5 and libevent both fail with
# _WIN32_WINNT-family errors under mingw/UCRT + GCC 15 -- zeromq's windows.hpp gets
# "operator '>=' has no left operand", libevent errors inside mingw's OWN iphlpapi.h.
# Adding -D_WIN32_WINNT cleared zeromq's first error straight into a second (it builds
# the Unix IPC transport on Windows and wants sys/socket.h). None of these three has
# ever been cross-built in this workspace, and ZMQ is mandatory in Monero's CMake, so
# it cannot simply be dropped.
#
# contrib/depends is how Monero officially ships Windows and how monero_c builds the
# prebuilt we are replacing, with upstream's own mingw patches for each package. It
# needs NO fixed-output derivation: every source is sha256-pinned in-tree, so nix
# fetches each by its committed hash, pre-seeds sources/, and depends runs offline.
#
# Used for x86_64-windows ONLY. The four native targets keep using nixpkgs, where they
# are already green.
{ pkgs, moneroSrc }:

let
  lib = pkgs.lib;
  # This derivation RUNS on the build platform and emits mingw artifacts, so it is a
  # native derivation that merely has the cross toolchain among its inputs.
  buildPkgs = pkgs.buildPackages;

  # Monero mirrors every one of these at downloads.getmonero.org/depends-sources, which
  # is the same fallback contrib/depends itself uses when an upstream moves.
  fetch = { name, url, sha256 }: buildPkgs.fetchurl {
    inherit sha256;
    urls = [ url "https://downloads.getmonero.org/depends-sources/${name}" ];
    inherit name;
  };

  # Versions and hashes read out of contrib/depends/packages/*.mk at this tree's
  # revision -- not chosen here. Bumping the monero pin can move them.
  sources = {
    "boost_1_69_0.tar.gz" = fetch {
      name = "boost_1_69_0.tar.gz";
      url = "https://archives.boost.io/release/1.69.0/source/boost_1_69_0.tar.gz";
      sha256 = "9a2c2819310839ea373f42d69e733c339b4e9a19deab6bfec448281554aa4dbb";
    };
    "openssl-3.0.19.tar.gz" = fetch {
      name = "openssl-3.0.19.tar.gz";
      url = "https://www.openssl.org/source/openssl-3.0.19.tar.gz";
      sha256 = "fa5a4143b8aae18be53ef2f3caf29a2e0747430b8bc74d32d88335b94ab63072";
    };
    "zeromq-4.3.4.tar.gz" = fetch {
      name = "zeromq-4.3.4.tar.gz";
      url = "https://github.com/zeromq/libzmq/releases/download/v4.3.4/zeromq-4.3.4.tar.gz";
      sha256 = "c593001a89f5a85dd2ddf564805deb860e02471171b3f204944857336295c3e5";
    };
    "libiconv-1.15.tar.gz" = fetch {
      name = "libiconv-1.15.tar.gz";
      url = "https://ftp.gnu.org/gnu/libiconv/libiconv-1.15.tar.gz";
      sha256 = "ccf536620a45458d26ba83887a983b96827001e92a13847b45e4925cc8913178";
    };
    "expat-2.6.0.tar.bz2" = fetch {
      name = "expat-2.6.0.tar.bz2";
      url = "https://github.com/libexpat/libexpat/releases/download/R_2_6_0/expat-2.6.0.tar.bz2";
      sha256 = "ff60e6a6b6ce570ae012dc7b73169c7fdf4b6bf08c12ed0ec6f55736b78d85ba";
    };
    "unbound-1.19.1.tar.gz" = fetch {
      name = "unbound-1.19.1.tar.gz";
      url = "https://www.nlnetlabs.nl/downloads/unbound/unbound-1.19.1.tar.gz";
      sha256 = "bc1d576f3dd846a0739adc41ffaa702404c6767d2b6082deb9f2f97cbb24a3a9";
    };
    "libsodium-1.0.18.tar.gz" = fetch {
      name = "libsodium-1.0.18.tar.gz";
      url = "https://download.libsodium.org/libsodium/releases/libsodium-1.0.18.tar.gz";
      sha256 = "6f504490b342a4f8a4c4a02fc9b866cbef8622d5df4e5452b46be121e46636c1";
    };
  };

  seed = lib.concatStringsSep "\n"
    (lib.mapAttrsToList (fname: drv: ''cp ${drv} "$SOURCES_PATH/${fname}"'') sources);

in
buildPkgs.stdenv.mkDerivation {
  pname = "monero-depends-x86_64-w64-mingw32";
  version = moneroSrc.version;
  src = moneroSrc;

  nativeBuildInputs = [
    # The mingw cross toolchain, which depends invokes by target prefix.
    pkgs.stdenv.cc
    pkgs.stdenv.cc.bintools
    buildPkgs.gnumake buildPkgs.autoconf buildPkgs.automake buildPkgs.libtool
    buildPkgs.pkg-config buildPkgs.python3 buildPkgs.perl buildPkgs.which
    buildPkgs.gettext buildPkgs.file buildPkgs.patch buildPkgs.curl
  ];

  dontConfigure = true;

  buildPhase = ''
    runHook preBuild
    export SOURCES_PATH="$TMPDIR/depends-sources"
    mkdir -p "$SOURCES_PATH"
    ${seed}

    # The source tree is read-only in the store and depends writes into it -- but copy
    # with modes INTACT and relax them afterwards. `--no-preserve=mode` also strips the
    # executable bit from config.guess/config.sub, and the failure is one the error
    # message does not name: `$(shell ./config.guess)` silently yields nothing, so
    # host_os is empty and make stops on "No rule to make target 'hosts/.mk'".
    cp -R contrib/depends "$TMPDIR/depends"
    chmod -R u+w "$TMPDIR/depends"

    # Overriding the package lists on the command line, which `make` lets us do:
    #   - icu4c: monero_c's patch 0018 reduced mingw's ICU_LIBRARIES to just `iconv`,
    #     so the CMake no longer links ICU and building it would be pure cost.
    #   - hidapi / protobuf / libusb: hardware-wallet support, which we build with
    #     -DUSE_DEVICE_TREZOR=OFF. A node and a wallet2 ABI need none of it.
    # GITIAN=1 drops native_ccache, which is useless in a nix build.
    #
    # mingw32_CFLAGS carries -std=gnu17 because depends pins packages from 2017-2019
    # and nixpkgs' mingw GCC is 15.2, where the C default moved to gnu23. libiconv 1.15
    # declares mbrtowc with an empty parameter list, which gnu23 reads as "no
    # parameters": "conflicting types for 'mbrtowc'; have 'size_t(void)'". CXXFLAGS is
    # overridden separately and WITHOUT the flag -- hosts/mingw32.mk defines
    # mingw32_CXXFLAGS=$(mingw32_CFLAGS), so overriding only CFLAGS would hand a C
    # standard to g++ for boost and zeromq.
    make -C "$TMPDIR/depends" \
      HOST=x86_64-w64-mingw32 \
      GITIAN=1 \
      SOURCES_PATH="$SOURCES_PATH" \
      packages="boost openssl zeromq libiconv expat unbound" \
      mingw32_CFLAGS="-pipe -std=gnu17" \
      mingw32_CXXFLAGS="-pipe" \
      mingw32_packages="sodium" \
      mingw32_native_packages="" \
      -j"''${NIX_BUILD_CORES:-4}"
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    cp -R "$TMPDIR/depends/x86_64-w64-mingw32/." "$out/"
    # depends writes a CMake toolchain file naming its own prefix; the Monero build
    # consumes it instead of nixpkgs' cross plumbing.
    test -f "$out/share/toolchain.cmake" || {
      echo "ERROR: depends produced no share/toolchain.cmake -- the Monero build has" >&2
      echo "nothing to point CMAKE_TOOLCHAIN_FILE at." >&2
      ls -R "$out" | head -40 >&2
      exit 1
    }
    runHook postInstall
  '';

  meta.description = "Monero contrib/depends prefix for x86_64-w64-mingw32, built offline from in-tree pins";
}
