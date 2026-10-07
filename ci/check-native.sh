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
# monero_c's own fingerprints of its header, wrapper (+ Monero commit) and export list for
# v0.18.5.3-RC1, as its generate_checksum.sh computes them (the tag's own copy is stale).
want = {
    "h":   "f1f24af3a9ae7e136c67fbbeffb1af0f7a3dd6cb70a7c43d5bd36a60fdb4a64f",
    "cpp": "087f2bb11cdbca5f886346850c74f0404a9c371fd1706521e7590dcea21d8af5-22578c3f7d7b4b6dd85ff7daa42a827d97cc53d0",
    "exp": "0b4c4b51dd956cbc035dababe423b787add156e8f7d0174445d9e2d4cdbac01e",
}
for k, v in want.items():
    f = getattr(w, "MONERO_checksum_wallet2_api_c_" + k); f.restype = ctypes.c_char_p
    got = f().decode()
    assert got == v, f"wallet2 {k} checksum {got} != {v}"
print("wallet2 loads; monero_c checksums match v0.18.5.3-RC1")
PY

# A load check is not a start check: v0.18.5.0's daemon reads options the shim had not
# registered, so every start failed while everything above passed.
python3 - "$dl" <<'PY'
import ctypes, json, shutil, socket, sys, tempfile, time, urllib.request
d = ctypes.CDLL(sys.argv[1])
d.MONEROD_start.argtypes = [ctypes.c_char_p]
d.MONEROD_last_error.restype = ctypes.c_void_p
d.MONEROD_free.argtypes = [ctypes.c_void_p]
def last_error():
    p = d.MONEROD_last_error(); s = ctypes.cast(p, ctypes.c_char_p).value.decode(); d.MONEROD_free(p); return s
def port():
    s = socket.socket(); s.bind(("127.0.0.1", 0)); n = s.getsockname()[1]; s.close(); return n
dd, rpc = tempfile.mkdtemp(), port()
# The argv logos-monerod-module builds, offline.
argv = ["--stagenet", f"--data-dir={dd}", f"--log-file={dd}/monerod.log", "--rpc-bind-ip=127.0.0.1",
        f"--rpc-bind-port={rpc}", f"--p2p-bind-port={port()}", "--no-zmq", "--check-updates=disabled",
        "--no-igd", "--offline"]
assert d.MONEROD_start(json.dumps(argv).encode()) == 0, "start refused: " + last_error()
req = urllib.request.Request(f"http://127.0.0.1:{rpc}/json_rpc", headers={"Content-Type": "application/json"},
                             data=b'{"jsonrpc":"2.0","id":"0","method":"get_info"}')
for _ in range(240):
    assert d.MONEROD_state() != 4, "node failed: " + last_error()
    try:
        info = json.loads(urllib.request.urlopen(req, timeout=2).read())["result"]; break
    except (OSError, ValueError):
        time.sleep(0.25)
else:
    raise SystemExit("node never answered RPC")
d.MONEROD_stop()
assert d.MONEROD_state() == 0, "node did not stop"
shutil.rmtree(dd, ignore_errors=True)
print(f"libmonerod_c runs a node: v{info['version']} {info['nettype']}, RPC answered, stopped")
PY
