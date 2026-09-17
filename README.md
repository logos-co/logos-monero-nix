# logos-monero-nix

One source-built Monero tree, two C-ABI shared libraries.

```
packages.<target>.monero-src   # monero @ dbcc7d21 + monero_c's 21 patches + ours
packages.<target>.monerod-c    # libmonerod_c — the daemon (monerod) as a library
```

Targets: `aarch64-darwin`, `x86_64-darwin`, `aarch64-linux`, `x86_64-linux`,
`x86_64-windows` (the Windows set comes from `logos-nix`'s mingw/UCRT cross pkgs).

## Why this exists

`logos-monero-wallet-core-module` is written against `monero_c`'s 354-symbol wallet2 C
ABI, which it consumed as a **prebuilt** `release-bundle.zip`. Building the same tree
from source retires that prebuilt, and once the tree is building, the Monero *daemon*
comes nearly free from it — the daemon links static archives the wallet2 build already
has to produce. That is what makes a local node affordable.

Upstream ships `src/daemon` only as the `monerod` executable, and nobody publishes
Monero's daemon as a shared library, so `libmonerod_c` is new work. Its C ABI is in
`shim/monerod_c.h`; every `const char*` it returns is owned by the caller and released
with `MONEROD_free`.

## The patched tree is vanilla where it counts

`monero_c`'s series is 21 patches, ~280 KB, overwhelmingly wallet-side (62 files in
`src/wallet`, plus polyseed, device/trezor and build files). It does **not** touch
`cryptonote_core`, `blockchain_db`, `hardforks`, `ringct`, `crypto`, `p2p`,
`cryptonote_protocol`, `rpc` or `daemon` — so a node built here validates blocks with
code identical to vanilla Monero. `nix/monero-src.nix` asserts that at build time
rather than trusting this paragraph, and holds our own patches to a named allowlist.

`external/randomx` is pinned to **tevador's upstream 1.2.1**, Monero's own pin, not to
`monero_c`'s iOS fork — see the comment in `nix/monero-src.nix`.

## Verified

On `aarch64-darwin`, via `shim/`'s C ABI: three start/stop cycles in one process, all
clean; and a live stagenet node that connected to 2 peers and synced height 1 → 3981 in
about 40 seconds before stopping cleanly.
