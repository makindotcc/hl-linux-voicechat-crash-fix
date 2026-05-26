#!/usr/bin/env bash
# Find Steam main 32-bit PID and apply gdb patch.
# Run: sudo ./patch_now.sh

set -e

GDB_SCRIPT="patch.gdb"

if [ ! -f "$GDB_SCRIPT" ]; then
    echo "[-] Missing gdb script: $GDB_SCRIPT"
    exit 1
fi

# Find 32-bit Steam main (cmdline contains /ubuntu12_32/steam)
PID=""
for p in /proc/[0-9]*; do
    [ -r "$p/cmdline" ] || continue
    cmd=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null)
    case "$cmd" in
        */ubuntu12_32/steam\ *) PID=$(basename "$p"); break ;;
    esac
done

if [ -z "$PID" ]; then
    echo "[-] Steam 32-bit main process not running"
    exit 1
fi

echo "[+] Steam main PID: $PID"

# Check whether steamclient.so is loaded yet (Steam must be logged in)
if ! grep -q steamclient.so /proc/$PID/maps 2>/dev/null; then
    echo "[-] steamclient.so not loaded yet — log in to Steam and try again"
    exit 1
fi

echo "[*] Patching via gdb..."
OUTPUT=$(gdb -p "$PID" -batch -x "$GDB_SCRIPT" 2>&1) || true
echo "$OUTPUT" | grep -E '^\[' || true

if echo "$OUTPUT" | grep -q 'PLT patched\|Already patched'; then
    exit 0
else
    echo "[-] Patching failed"
    exit 1
fi
