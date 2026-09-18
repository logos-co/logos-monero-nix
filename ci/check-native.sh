#!/usr/bin/env bash
# Checks the native libraries: exact export counts, and that each one loads and answers a call.
# Usage: ci/check-native.sh <monerod-c output> <monero-c output>
set -euo pipefail
d="$1"; w="$2"
case "$(uname -s)" in
  Darwin) ext=dylib; want_wallet=354; exports() { nm -gU "$1" | awk '{print $NF}' | sed 's/^_//'; } ;;
  Linux)  ext=so;    want_wallet=357; exports() { nm -D --defined-only "$1" | awk '{print $NF}'; } ;;
  *) echo "unsupported host $(uname -s)"; exit 1 ;;
esac
dl="$d/lib/libmonerod_c.$ext"; wl="$w/lib/libmonero_wallet2_api_c.$ext"

n=$(exports "$dl" | grep -c '^MONEROD_' || true)
[ "$n" -eq 7 ] || { echo "::error::libmonerod_c exports $n MONEROD_* symbols, expected 7"; exit 1; }
n=$(exports "$wl" | grep -c '^MONERO_' || true)
[ "$n" -eq "$want_wallet" ] || { echo "::error::wallet2 exports $n MONERO_* symbols, expected $want_wallet"; exit 1; }
echo "exports: 7 MONEROD_*, $want_wallet MONERO_*"

# A symbol check is not a load check: this caught a dangling polyseed dependency.
python3 - "$dl" "$wl" <<'PY'
import ctypes, sys
d = ctypes.CDLL(sys.argv[1])
d.MONEROD_version.restype = ctypes.c_char_p
assert d.MONEROD_state() == 0, "a fresh daemon library must report STOPPED"
print("libmonerod_c loads:", d.MONEROD_version().decode())
w = ctypes.CDLL(sys.argv[2])
# monero_c's own fingerprints of its header, wrapper (+ Monero commit) and export list, as
# shipped in the v0.18.4.6-RC2 prebuilt this library replaces.
want = {
    "h":   "f1f24af3a9ae7e136c67fbbeffb1af0f7a3dd6cb70a7c43d5bd36a60fdb4a64f",
    "cpp": "b62ff8b4a7178be15f7c53f8b368164357eb2f35db5bc00125beaafc39c3c4a5-dbcc7d212c094bd1a45f7291dbb99a4b4627a96d",
    "exp": "0b4c4b51dd956cbc035dababe423b787add156e8f7d0174445d9e2d4cdbac01e",
}
for k, v in want.items():
    f = getattr(w, "MONERO_checksum_wallet2_api_c_" + k); f.restype = ctypes.c_char_p
    got = f().decode()
    assert got == v, f"wallet2 {k} checksum {got} != {v}"
print("wallet2 loads; monero_c checksums match the v0.18.4.6-RC2 prebuilt")
PY
