# libmonero_wallet2_api_c: monero_c's wallet2 C ABI, built from source.
#
# This REPLACES the prebuilt release-bundle.zip that
# logos-monero-wallet-core-module's own nix/monero-c.nix used to fetch. The module's
# API surface must not move, so the build asserts the exports against monero_c's
# own .exp list -- 354 symbols, the same contract the prebuilt published.
#
# LGPL-3.0: monero_c's shim and patches are LGPL, over BSD-3 Monero. The library stays
# a separate, replaceable shared object with its licence text alongside, and building
# from source strengthens that position rather than weakening it -- we can hand over the
# exact corresponding source and the recipe that produced this file.
{ pkgs, moneroSrc, shimSrc }:

let
  inherit (pkgs) lib stdenv;
in
stdenv.mkDerivation {
  pname = "monero_wallet2_api_c";
  version = moneroSrc.version;

  src = shimSrc;

  nativeBuildInputs = [ pkgs.cmake pkgs.pkg-config ];

  buildInputs = [
    pkgs.boost186      # wallet_api wants Boost_LOCALE_LIBRARY as well as the usual set
    pkgs.icu           # boost::locale's backend, and wallet_api links ICU_LIBRARIES
    pkgs.libsodium
    pkgs.openssl
    pkgs.unbound
    pkgs.zeromq
  ] ++ lib.optionals stdenv.hostPlatform.isWindows [
    pkgs.windows.pthreads
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
  ] ++ lib.optional stdenv.hostPlatform.isDarwin "-DBoost_USE_MULTITHREADED=OFF";

  ninjaFlags = [ "monero_wallet2_api_c" ];
  buildFlags = [ "monero_wallet2_api_c" ];

  dontStrip = true;

  # The export surface IS the contract with logos-monero-wallet-core-module, so it is
  # checked here rather than left to a consumer's link error. Mach-O only: the ELF side
  # has no equally crisp notion of "exported" to diff, and is covered by the same
  # sources plus hidden visibility and --exclude-libs,ALL.
  #
  # `nm` here is the stdenv's own -- cctools on darwin -- and that matters. GNU
  # binutils nm reads the Mach-O symbol TABLE rather than what dyld would export, and
  # reported 19,153 spurious extras against a library whose link line demonstrably
  # carried -exported_symbols_list. cctools nm -gU is the tool that gives 354 for the
  # prebuilt this replaces, so it is the tool the comparison has to use.
  doInstallCheck = stdenv.hostPlatform.isDarwin && !stdenv.hostPlatform.isWindows;
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
    # LGPL-3.0 4(d) wants the notice beside the library it covers, and lib/ is the
    # only place logos-module-builder's `include` staging looks when it copies runtime
    # files next to a plugin -- the lesson the prebuilt's own derivation carried at
    # nix/monero-c.nix:53-55.
    install -m0644 ${moneroSrc}/LICENSE "$out/lib/LICENSE.monero"
    install -m0644 ${moneroSrc}/.logos/LICENSE.monero_c "$out/lib/LICENSE.monero_c"
  '';

  meta = {
    description = "monero_c wallet2 C ABI, built from source (354-symbol contract)";
    license = [ pkgs.lib.licenses.bsd3 pkgs.lib.licenses.lgpl3Only ];
  };
}
