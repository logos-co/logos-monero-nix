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

    # OpenSSL's ./Configure is a Perl script with a `#!/usr/bin/env perl` shebang, and
    # /usr/bin/env does not exist inside the nix sandbox:
    #   sh: ./Configure: /usr/bin/env: bad interpreter: No such file or directory
    # Invoking the interpreter directly sidesteps the shebang entirely. Of the seven
    # packages we build, openssl is the only one that runs a script this way -- the
    # rest are autotools, whose configure is #!/bin/sh, which the sandbox does have.
    #
    # This is also a failure that CANNOT reproduce on the dev Mac, where the sandbox is
    # off and /usr/bin/env resolves fine. Linux is the only place it shows up.
    _mk="$TMPDIR/depends/packages/openssl.mk"
    grep -q '^  \./Configure ' "$_mk" || {
      echo "ERROR: openssl.mk no longer matches the ./Configure line this rewrites." >&2
      echo "Re-check it rather than letting a silent no-op fail later at configure." >&2
      exit 1
    }
    sed -i 's|^  \./Configure |  perl ./Configure |' "$_mk"

    # Overriding the package lists on the command line, which `make` lets us do:
    #   - icu4c: monero_c's patch 0018 reduced mingw's ICU_LIBRARIES to just `iconv`,
    #     so the CMake no longer links ICU and building it would be pure cost.
    #   - hidapi / protobuf / libusb: hardware-wallet support, which we build with
    #     -DUSE_DEVICE_TREZOR=OFF. A node and a wallet2 ABI need none of it.
    # `packages` is ONE explicit list, and sodium is in it even though packages.mk puts
    # sodium under mingw32_packages. GNU make semantics: a variable set on the command
    # line overrides every makefile assignment to it INCLUDING `+=`, so the Makefile's
    # `packages += $(<host_os>_packages)` silently becomes a no-op the moment we
    # override `packages`. Setting mingw32_packages alongside it therefore did nothing,
    # and sodium was never built -- which surfaced much later, and only in the
    # consumer, as `SODIUM_LIBRARY ... set to NOTFOUND` from a CMake configure.
    # mingw32_native_packages is different and still works: nothing overrides
    # `native_packages`, so its `+=` still runs and appends our empty value.
    #
    # GITIAN=1 drops native_ccache, which is useless in a nix build.
    #
    # mingw32_CFLAGS carries -std=gnu17 because depends pins packages from 2017-2019
    # and nixpkgs' mingw GCC is 15.2, where the C default moved to gnu23. libiconv 1.15
    # declares mbrtowc with an empty parameter list, which gnu23 reads as "no
    # parameters": "conflicting types for 'mbrtowc'; have 'size_t(void)'". CXXFLAGS is
    # overridden separately and WITHOUT the flag -- hosts/mingw32.mk defines
    # mingw32_CXXFLAGS=$(mingw32_CFLAGS), so overriding only CFLAGS would hand a C
    # standard to g++ for boost and zeromq.
    #
    # _WIN32_WINNT is required by this toolchain rather than by the packages: its
    # mcfgthread headers carry "#warning Please define _WIN32_WINNT", which zeromq's
    # -Werror turns into an error. 0x0A00 is Windows 10, matching logos-nix's
    # deliberate choice of UCRT over the legacy MSVCRT ("what Microsoft ships on
    # Windows 10+"). The same undefined macro is what broke nixpkgs' own mingw zeromq,
    # so this is a property of the cross toolchain, not of either package set.
    #
    # It goes in CPPFLAGS, not CFLAGS/CXXFLAGS, for a reason learned the slow way:
    # zeromq.mk sets `$(package)_cxxflags=-std=c++11`, which REPLACES the host default
    # rather than appending to it, so a define put in mingw32_CXXFLAGS reached every C
    # compile (1063 of them) and no C++ one. The failure then looked identical to
    # having set no flag at all. CPPFLAGS applies to both languages, none of the seven
    # packages overrides `_cppflags`, and a preprocessor define belongs there anyway.
    make -C "$TMPDIR/depends" \
      HOST=x86_64-w64-mingw32 \
      GITIAN=1 \
      SOURCES_PATH="$SOURCES_PATH" \
      packages="boost openssl zeromq libiconv expat unbound sodium" \
      mingw32_CFLAGS="-pipe -std=gnu17" \
      mingw32_CXXFLAGS="-pipe" \
      mingw32_CPPFLAGS="-D_WIN32_WINNT=0x0A00" \
      mingw32_native_packages="" \
      -j"''${NIX_BUILD_CORES:-4}"
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    cp -R "$TMPDIR/depends/x86_64-w64-mingw32/." "$out/"

    # depends bakes its BUILD-TIME prefix into everything it generates -- the toolchain
    # file lands with
    #   SET(BOOST_ROOT /build/depends/x86_64-w64-mingw32)
    #   SET(ZMQ_LIB    /build/depends/x86_64-w64-mingw32/lib/libzmq.a)
    # and the .pc/.la/.cmake files do the same. None of those paths exists once the
    # build directory is gone, so a consumer would fail to find boost, zmq or unbound
    # with nothing to suggest why. Rewrite them to this output.
    _old="$TMPDIR/depends/x86_64-w64-mingw32"
    _hits=$(grep -rl "$_old" "$out" 2>/dev/null || true)
    if [ -z "$_hits" ]; then
      echo "ERROR: no file references the build prefix, which cannot be right --" >&2
      echo "depends always bakes it in. The rewrite below would be a silent no-op." >&2
      exit 1
    fi
    echo "$_hits" | while read -r f; do
      [ -f "$f" ] || continue
      sed -i "s|$_old|$out|g" "$f" 2>/dev/null || true
    done
    # Prove it: nothing may still point into the vanished build tree.
    if grep -rl "$_old" "$out" 2>/dev/null | grep -q .; then
      echo "ERROR: files still reference $_old after the rewrite:" >&2
      grep -rl "$_old" "$out" 2>/dev/null | head -5 >&2
      exit 1
    fi
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
