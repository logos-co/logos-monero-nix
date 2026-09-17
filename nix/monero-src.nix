# The one Monero source tree this repo builds everything from: monero-project/monero
# at the revision monero_c pins, with monero_c's 21 patches replayed on top and every
# submodule materialised from a hash-pinned fetch.
#
# Why patched rather than vanilla: logos-monero-wallet-core-module is written against
# monero_c's 354-symbol C ABI, and 145 of those exports only exist because of these
# patches (polyseed, coin control, UR, trezor). The patch set is wallet-side -- nothing
# touches cryptonote_core, blockchain_db, hardforks, ringct, crypto, p2p,
# cryptonote_protocol, rpc or daemon -- so a node built from this tree validates blocks
# with code byte-identical to vanilla Monero. Measured, not assumed: the only
# consensus-file change is `#define POLYSEED_COIN` in src/cryptonote_config.h.
{ pkgs }:

let
  lib = pkgs.lib;

  # Fetches run on the BUILD machine; under cross these must not become target binaries.
  fetch = { owner, repo, rev, hash }:
    pkgs.fetchFromGitHub { inherit owner repo rev hash; };

  moneroRev = "dbcc7d212c094bd1a45f7291dbb99a4b4627a96d";

  monero_c = fetch {
    owner = "MrCyjaneK"; repo = "monero_c"; rev = "v0.18.4.6-RC2";
    hash = "sha256-xs+2i6v+eePG9URGtcOlzzXZopkpkXwlabjUAPMp5mA=";
  };

  src = fetch {
    owner = "monero-project"; repo = "monero"; rev = moneroRev;
    hash = "sha256-A7EqamADbTyK6l26foSXfZLH94OUUMsgi7jdsKRubXU=";
  };

  # GitHub STRIPS .gitmodules from archive tarballs, and patch 0001 modifies it --
  # so without this the very first patch dies with "sha1 information is lacking or
  # useless (.gitmodules)". Restored verbatim: `git hash-object` on this file is
  # 721cce3b4bb9723425cbed31cec26c3d37477556, byte-identical to the patch's pre-image.
  gitmodules = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/monero-project/monero/${moneroRev}/.gitmodules";
    hash = "sha256-dls/88qNfuE5kJZvBbcvDG/RB/Lo+U6dL4yGOd/NNh4=";
  };

  # Submodule CONTENT, by path. A GitHub archive tarball omits submodule directories
  # entirely, so every one of these has to be supplied here.
  #
  # The gitlink SHAs the patches carry are inert: we never run `git submodule update`,
  # so only this table decides what gets compiled. That is what lets us honour the
  # patch series unmodified while still choosing upstream RandomX -- see `randomx`.
  submodules = {
    "external/miniupnp" = fetch {
      owner = "miniupnp"; repo = "miniupnp";
      rev = "544e6fcc73c5ad9af48a8985c94f0f1d742ef2e0";
      hash = "sha256-opd0hcZV+pjC3Mae3Yf6AR5fj6xVwGm9LuU5zEPxBKc=";
    };
    "external/rapidjson" = fetch {
      owner = "Tencent"; repo = "rapidjson";
      rev = "129d19ba7f496df5e33658527a7158c79b99c21c";
      hash = "sha256-8bOIOmPL2uC6tic1s5MEBgxLRpI2wsyJvkcyzvygHBQ=";
    };
    "external/trezor-common" = fetch {
      owner = "trezor"; repo = "trezor-common";
      rev = "bff7fdfe436c727982cc553bdfb29a9021b423b0";
      hash = "sha256-VNypeEz9AV0ts8X3vINwYMOgO8VpNmyUPC4iY3OOuZI=";
    };
    "external/supercop" = fetch {
      owner = "monero-project"; repo = "supercop";
      rev = "633500ad8c8759995049ccd022107d1fa8a1bbc9";
      hash = "sha256-26UmESotSWnQ21VbAYEappLpkEMyl0jiuCaezRYd/sE=";
    };

    # UPSTREAM RandomX 1.2.1 -- Monero's own pin -- deliberately NOT monero_c's
    # MrCyjaneK/RandomX@5dfeeb30. Patch 0001 ("fix missing ___clear_cache when
    # targetting iOS") repoints this submodule and does nothing else. That fork is 2
    # commits ahead and, in src/jit_compiler_a64.cpp, replaces PRECISE i-cache flush
    # ranges with whole-buffer ones in BOTH preprocessor branches -- including the
    # HAVE_BUILTIN_CLEAR_CACHE path every non-Apple target takes. In
    # generateSuperscalarHash the replacement range (code .. code+CodeSize) is not even
    # a superset of the original (code+CodeSize .. code+codePos). On aarch64 that is
    # stale-i-cache territory, and this library is the proof-of-work verifier in a
    # validating node. We do not target iOS, so there is no upside to the fork.
    "external/randomx" = fetch {
      owner = "tevador"; repo = "RandomX";
      rev = "102f8acf90a7649ada410de5499a7ec62e49e1da";
      hash = "sha256-dfImzwbEfJQcaPZCoWypHiI6dishVRdqS/r+n3tfjvM=";
    };

    # Added to the tree BY the patch series, so absent from monero's own .gitmodules.
    "external/bc-ur" = fetch {
      owner = "MrCyjaneK"; repo = "bc-ur";
      rev = "d82e7c753e710b8000706dc3383b498438795208";
      hash = "sha256-96mD5YqlJd4R5lRbavxREwaEdxp/o1bUeOjh+FEkXTw=";
    };
    "external/polyseed" = fetch {
      owner = "tevador"; repo = "polyseed";
      rev = "bd79f5014c331273357277ed8a3d756fb61b9fa1";
      hash = "sha256-Vuo2FydkCNnS7OrkcevjZsqz49RzLiRq48BIg37K/AQ=";
    };
    "external/utf8proc" = fetch {
      owner = "JuliaStrings"; repo = "utf8proc";
      rev = "3de4596fbe28956855df2ecb3c11c0bbc3535838";
      hash = "sha256-DNnrKLwks3hP83K56Yjh9P3cVbivzssblKIx4M/RKqw=";
    };
  };

  # The gitlink SHAs monero records at moneroRev. `git am` applies patch 0001's
  # `-Subproject commit 102f8acf / +Subproject commit 5dfeeb30` hunk against the INDEX,
  # and an archive tarball has no gitlink entries at all -- so without seeding these the
  # very first patch fails. Seeding them is what lets the series stay unmodified.
  baseGitlinks = {
    "external/miniupnp" = "544e6fcc73c5ad9af48a8985c94f0f1d742ef2e0";
    "external/rapidjson" = "129d19ba7f496df5e33658527a7158c79b99c21c";
    "external/trezor-common" = "bff7fdfe436c727982cc553bdfb29a9021b423b0";
    "external/randomx" = "102f8acf90a7649ada410de5499a7ec62e49e1da";
    "external/supercop" = "633500ad8c8759995049ccd022107d1fa8a1bbc9";
  };

  seedGitlinks = lib.concatStringsSep "\n" (lib.mapAttrsToList (path: sha:
    ''git update-index --add --cacheinfo 160000,${sha},"${path}"'') baseGitlinks);

  materialise = lib.concatStringsSep "\n" (lib.mapAttrsToList (path: drv: ''
    echo "  ${path}"
    rm -rf "${path}"
    mkdir -p "${path}"
    cp -R --no-preserve=mode,ownership ${drv}/. "${path}/"
  '') submodules);

in
pkgs.stdenvNoCC.mkDerivation {
  pname = "monero-src-patched";
  version = "0.18.4.6-RC2";
  inherit src;

  # buildPackages: git runs on the builder. Resolving it from the target set would try
  # to build git FOR the host platform under cross.
  nativeBuildInputs = [ pkgs.buildPackages.git ];

  dontConfigure = true;
  dontBuild = true;
  dontFixup = true;

  patchPhase = ''
    runHook prePatch

    # A throwaway repo purely so `git am -3` can do its 3-way merge. The series was
    # authored against ${moneroRev} and applies to nothing else (upstream's own
    # apply_patches.sh uses `git am -3 --whitespace=fix`), so a plain `patch -p1` would
    # be trading exact upstream semantics for fuzz.
    cp --no-preserve=mode,ownership ${gitmodules} .gitmodules

    git init -q .
    git config user.email "build@logos.invalid"
    git config user.name "logos-monero-nix"
    git add -A

    # AFTER `git add -A`, never before: every external/* submodule directory in the
    # tarball is EMPTY, and `add -A` reconciles the index against the worktree, which
    # deletes any gitlink entry seeded earlier. Patch 0001 then fails with
    # "CONFLICT (modify/delete): external/randomx deleted in HEAD".
    ${seedGitlinks}

    git commit -q -m "monero ${moneroRev}"
    _base=$(git rev-parse HEAD)

    echo "applying monero_c patch series (21 patches)..."
    git am -3 --whitespace=fix ${monero_c}/patches/monero/*.patch
    _after_upstream=$(git rev-parse HEAD)

    # Our own patches, on top and kept separate so the upstream series stays a
    # verbatim replay. Currently one: t_daemon::stop_p2p() has to be reachable for
    # an embedder, because stop() resets mp_internals while run() is still using
    # them. See patches/monero/ for the reasoning.
    echo "applying logos patches..."
    git am -3 --whitespace=fix ${../patches/monero}/*.patch

    # The whole "one tree serves both the wallet and a validating node" argument rests
    # on this being empty, and a future monero_c bump could quietly break it. Verified
    # empty at v0.18.4.6-RC2. Consensus, networking and RPC code must stay vanilla.
    #
    # Scoped to the UPSTREAM series only: our own patches are held to the allowlist
    # below instead, because this guard would otherwise refuse them -- and it did,
    # which is how we know it works.
    echo "asserting monero_c's series left consensus code alone..."
    _watched="src/cryptonote_core src/blockchain_db src/hardforks src/ringct src/crypto src/p2p src/cryptonote_protocol src/rpc src/daemon"
    _touched=$(git diff --name-only "$_base" "$_after_upstream" -- $_watched)
    if [ -n "$_touched" ]; then
      echo "ERROR: monero_c's patch series now modifies consensus/networking code:" >&2
      echo "$_touched" | sed 's/^/  /' >&2
      echo "" >&2
      echo "A node built from this tree would no longer validate blocks with code" >&2
      echo "identical to vanilla Monero. Re-audit before bumping the monero_c pin." >&2
      exit 1
    fi

    # Our own patches get an explicit allowlist rather than a free pass. Anything
    # else appearing here is a patch nobody reviewed against this rule.
    _allowed="src/daemon/daemon.h"
    _ours=$(git diff --name-only "$_after_upstream" HEAD)
    for _f in $_ours; do
      case " $_allowed " in
        *" $_f "*) ;;
        *) echo "ERROR: logos patch touches an unlisted file: $_f" >&2
           echo "Add it to _allowed in nix/monero-src.nix, with a reason." >&2
           exit 1 ;;
      esac
    done

    echo "materialising submodules..."
    ${materialise}

    # The repo was scaffolding for `git am`; shipping it would put a 100 MB+ .git in
    # every consumer's closure and make the output non-deterministic.
    rm -rf .git

    runHook postPatch
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    cp -R . "$out/"
    # The wallet2 C ABI shim and its export list live in monero_c, and every consumer
    # needs them beside the tree. Staged here so exactly one derivation owns the pin.
    mkdir -p "$out/.logos"
    cp -R ${monero_c}/monero_libwallet2_api_c "$out/.logos/wallet2_shim"
    runHook postInstall
  '';

  passthru = { inherit monero_c moneroRev submodules; };

  meta = {
    description = "monero-project/monero at ${builtins.substring 0 12 moneroRev}, with monero_c's patch series applied";
    # Monero is BSD-3-Clause; monero_c's patches and shim are LGPL-3.0, so the
    # patched tree as a whole is LGPL-3.0 and every library built from it ships as a
    # separate, replaceable shared object with its licence text alongside.
    license = [ pkgs.lib.licenses.bsd3 pkgs.lib.licenses.lgpl3Only ];
  };
}
