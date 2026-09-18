# One Monero tree for both libraries: monero at monero_c's pin, monero_c's patches replayed,
# submodules pinned below. The patch set is wallet-side, and the build asserts it.
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

  # GitHub strips .gitmodules from tarballs, and patch 0001 edits it.
  gitmodules = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/monero-project/monero/${moneroRev}/.gitmodules";
    hash = "sha256-dls/88qNfuE5kJZvBbcvDG/RB/Lo+U6dL4yGOd/NNh4=";
  };

  # Submodule content by path; tarballs omit it. The patches' gitlink SHAs are inert.
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

    # Upstream RandomX, not monero_c's iOS fork: the fork mangles i-cache flush ranges in
    # the PoW verifier, and patch 0001 exists only to repoint this.
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

  # Seeded so patch 0001's gitlink hunk has a base; tarballs carry no gitlinks.
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

    # A scratch repo so the series replays with upstream's own `git am -3`.
    cp --no-preserve=mode,ownership ${gitmodules} .gitmodules

    git init -q .
    git config user.email "build@logos.invalid"
    git config user.name "logos-monero-nix"
    git add -A

    # After `git add -A`, which would drop gitlinks whose directories are empty.
    ${seedGitlinks}

    git commit -q -m "monero ${moneroRev}"
    _base=$(git rev-parse HEAD)

    echo "applying monero_c patch series (21 patches)..."
    git am -3 --whitespace=fix ${monero_c}/patches/monero/*.patch
    _after_upstream=$(git rev-parse HEAD)

    # Ours, kept separate so the upstream series stays verbatim.
    echo "applying logos patches..."
    git am -3 --whitespace=fix ${../patches/monero}/*.patch

    # Consensus, networking and RPC must stay vanilla; our own patches get an allowlist.
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
    _allowed="src/daemon/daemon.h src/daemon/daemon.cpp"
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
    # monero_c's shim includes the tree by relative path; recreate its layout.
    ln -s .. "$out/.logos/monero"
    # LGPL-3.0 notice for every library built from this tree.
    install -m0644 ${monero_c}/LICENSE "$out/.logos/LICENSE.monero_c"
    runHook postInstall
  '';

  passthru = { inherit monero_c moneroRev submodules; };

  meta = {
    description = "monero-project/monero at ${builtins.substring 0 12 moneroRev}, with monero_c's patch series applied";
    # BSD-3 Monero, LGPL-3.0 monero_c patches and shim.
    license = [ pkgs.lib.licenses.bsd3 pkgs.lib.licenses.lgpl3Only ];
  };
}
