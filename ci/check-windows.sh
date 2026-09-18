#!/usr/bin/env bash
# Checks the Windows DLLs with the CROSS objdump: every import is a system DLL, the UCRT or the
# host's mcfgthread, and the exports are exactly the API.
# Usage: ci/check-windows.sh <monerod-c output> <monero-c output>   (OBJDUMP may override)
set -euo pipefail
d="$1"; w="$2"; OD="${OBJDUMP:-x86_64-w64-mingw32-objdump}"
allowed='^(ADVAPI32|bcrypt|CRYPT32|IPHLPAPI|KERNEL32|MSWSOCK|SHELL32|USER32|WS2_32)\.(dll|DLL)$|^api-ms-win-crt-[a-z]+-l1-1-0\.dll$|^libmcfgthread-2\.dll$'
exports() { "$OD" -p "$1" | sed -n '/\[Ordinal\/Name Pointer\] Table/,/^$/p' | awk 'NR>1 && NF {print $NF}'; }
check() {
  f="$1"; prefix="$2"; want="$3"
  imports=$("$OD" -p "$f" | sed -n 's/^[[:space:]]*DLL Name: //p')
  # A native objdump reads no PE imports at all; zero is a failure, never a pass.
  [ -n "$imports" ] || { echo "::error::read no imports from $f (not a cross objdump?)"; exit 1; }
  bad=$(printf '%s\n' "$imports" | grep -Ev "$allowed" || true)
  [ -z "$bad" ] || { echo "::error::$(basename "$f") imports unexpected DLLs: $bad"; exit 1; }
  n=$(exports "$f" | grep -c "^${prefix}_" || true)
  [ "$n" -eq "$want" ] || { echo "::error::$(basename "$f") exports $n ${prefix}_*, expected $want"; exit 1; }
  echo "$(basename "$f"): $(printf '%s\n' "$imports" | wc -l | tr -d ' ') imports allowed, $n ${prefix}_* exports"
}
check "$d/bin/libmonerod_c.dll" MONEROD 7
check "$w/bin/libmonero_wallet2_api_c.dll" MONERO 357
