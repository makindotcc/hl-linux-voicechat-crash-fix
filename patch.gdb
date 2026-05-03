# Patch buggy memmove PLT call in steamclient.so
# Run: sudo gdb -p <STEAM_PID> -x patch.gdb

set pagination off
set confirm off

# Auto-find steamclient.so base via Python
python
import gdb
pid = gdb.selected_inferior().pid
base = None
for line in open('/proc/{}/maps'.format(pid)):
    if 'steamclient.so' in line:
        base = int(line.split('-')[0], 16)
        break
if base is None:
    raise gdb.GdbError("steamclient.so not found in /proc/{}/maps".format(pid))
gdb.execute('set $BASE = ' + hex(base))
print('[*] steamclient.so base = ' + hex(base))
end

set $GOT_SLOT = $BASE + 0x2d936fc
set $MEMMOVE  = *(unsigned int*)$GOT_SLOT
printf "[*] memmove resolved @ %#x = %#x\n", (unsigned int)$GOT_SLOT, $MEMMOVE

# Patch site: jmp instruction inside the memmove PLT stub (BN 0xe2ad19)
set $PATCH = $BASE + 0xe1ad19

# Show original bytes
printf "[*] before: %02x %02x %02x %02x %02x %02x\n", \
  *(unsigned char*)($PATCH+0), *(unsigned char*)($PATCH+1), \
  *(unsigned char*)($PATCH+2), *(unsigned char*)($PATCH+3), \
  *(unsigned char*)($PATCH+4), *(unsigned char*)($PATCH+5)

# rel32 for `jmp memmove`
set $REL = (int)$MEMMOVE - (int)($PATCH + 5)
printf "[*] patching %#x -> jmp %#x (rel32 = %#x)\n", \
  (unsigned int)$PATCH, (unsigned int)$MEMMOVE, (unsigned int)$REL

# E9 <rel32> 90  (jmp rel32 + nop padding)
set *(unsigned char*)($PATCH+0) = 0xe9
set *(int*)($PATCH+1) = $REL
set *(unsigned char*)($PATCH+5) = 0x90

# Show patched bytes
printf "[*] after:  %02x %02x %02x %02x %02x %02x\n", \
  *(unsigned char*)($PATCH+0), *(unsigned char*)($PATCH+1), \
  *(unsigned char*)($PATCH+2), *(unsigned char*)($PATCH+3), \
  *(unsigned char*)($PATCH+4), *(unsigned char*)($PATCH+5)

printf "[+] PLT patched. memmove will always go to libc, ignoring ebx.\n"

detach
quit
