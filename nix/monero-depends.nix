# Monero's contrib/depends, for x86_64-windows only: nixpkgs' mingw set does not build.
# Sources are hash-pinned in-tree, so this runs offline with no fixed-output derivation.
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

    # Keep modes: --no-preserve=mode strips +x from config.guess, emptying host_os.
    cp -R contrib/depends "$TMPDIR/depends"
    chmod -R u+w "$TMPDIR/depends"

    # openssl's Configure is `#!/usr/bin/env perl`, and the sandbox has no /usr/bin/env.
    _mk="$TMPDIR/depends/packages/openssl.mk"
    grep -q '^  \./Configure ' "$_mk" || {
      echo "ERROR: openssl.mk no longer matches the ./Configure line this rewrites." >&2
      echo "Re-check it rather than letting a silent no-op fail later at configure." >&2
      exit 1
    }
    sed -i 's|^  \./Configure |  perl ./Configure |' "$_mk"

    # One explicit list: a command-line var also disables the Makefile's `+=` to it.
    # Dropped: icu4c (patch 0018), hidapi/protobuf/libusb (no Trezor), ccache (GITIAN).
    # gnu17 for 2017-era C on GCC 15; _WIN32_WINNT in CPPFLAGS, since zeromq's cxxflags
    # replace the host's. No -j: parallel `ar` corrupted libcrypto.a.
    make -C "$TMPDIR/depends" \
      HOST=x86_64-w64-mingw32 \
      GITIAN=1 \
      SOURCES_PATH="$SOURCES_PATH" \
      packages="boost openssl zeromq libiconv expat unbound sodium" \
      mingw32_CFLAGS="-pipe -std=gnu17" \
      mingw32_CXXFLAGS="-pipe" \
      mingw32_CPPFLAGS="-D_WIN32_WINNT=0x0A00" \
      mingw32_native_packages=""
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    cp -R "$TMPDIR/depends/x86_64-w64-mingw32/." "$out/"

    # depends bakes its build prefix into toolchain.cmake and .pc/.la files; rewrite it.
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
