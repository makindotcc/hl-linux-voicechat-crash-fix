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

BASE=$(grep steamclient.so /proc/$PID/maps | head -1 | cut -d- -f1)
echo "[+] steamclient.so base: 0x$BASE"

# Check whether the patch is already applied
PATCH_ADDR=$((0x$BASE + 0xe1ad19))
BYTES=$(dd if=/proc/$PID/mem bs=1 count=1 skip=$PATCH_ADDR 2>/dev/null | xxd -p)
if [ "$BYTES" = "e9" ]; then
    echo "[+] Patch already applied (first byte = 0xe9)"
    exit 0
elif [ "$BYTES" != "ff" ]; then
    echo "[!] Unexpected byte at 0x$(printf '%x' $PATCH_ADDR): 0x$BYTES"
    echo "    Expected: 0xff (original) or 0xe9 (patched)"
    exit 1
fi

echo "[*] Patching via gdb..."
gdb -p "$PID" -batch -x "$GDB_SCRIPT" 2>&1 | grep -E '^\[|patched|Patching|memmove|jmp|after|before' || true

# Verify
BYTES=$(dd if=/proc/$PID/mem bs=1 count=6 skip=$PATCH_ADDR 2>/dev/null | xxd -p)
if [ "${BYTES:0:2}" = "e9" ] && [ "${BYTES:10:2}" = "90" ]; then
    echo "[+] Patch applied successfully: $BYTES"
else
    echo "[-] Something went wrong — bytes: $BYTES"
    exit 1
fi
