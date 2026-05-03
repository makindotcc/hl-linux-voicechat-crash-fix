# Patch buggy memmove PLT call w steamclient.so
# Run: sudo gdb -p <PID_steam> -x /home/user/Desktop/stimek/patch.gdb

set pagination off
set confirm off

# Auto-find steamclient.so base via Python
python
import gdb, re
pid = gdb.selected_inferior().pid
base = None
for line in open('/proc/{}/maps'.format(pid)):
    if 'steamclient.so' in line:
        base = int(line.split('-')[0], 16)
        break
if base is None:
    raise gdb.GdbError("steamclient.so nie znalezione w /proc/{}/maps".format(pid))
gdb.execute('set $BASE = ' + hex(base))
print('[*] steamclient.so base = ' + hex(base))
end

set $GOT_SLOT = $BASE + 0x2d936fc
set $MEMMOVE  = *(unsigned int*)$GOT_SLOT
printf "[*] memmove resolved @ %#x = %#x\n", (unsigned int)$GOT_SLOT, $MEMMOVE

# Patch site: jmp instruction wewnątrz PLT stuba memmove (BN 0xe2ad19)
set $PATCH = $BASE + 0xe1ad19

# Pokaż przed
printf "[*] before: %02x %02x %02x %02x %02x %02x\n", \
  *(unsigned char*)($PATCH+0), *(unsigned char*)($PATCH+1), \
  *(unsigned char*)($PATCH+2), *(unsigned char*)($PATCH+3), \
  *(unsigned char*)($PATCH+4), *(unsigned char*)($PATCH+5)

# rel32 dla `jmp memmove`
set $REL = (int)$MEMMOVE - (int)($PATCH + 5)
printf "[*] patching %#x -> jmp %#x (rel32 = %#x)\n", \
  (unsigned int)$PATCH, (unsigned int)$MEMMOVE, (unsigned int)$REL

# E9 <rel32> 90  (jmp rel32 + nop padding)
set *(unsigned char*)($PATCH+0) = 0xe9
set *(int*)($PATCH+1) = $REL
set *(unsigned char*)($PATCH+5) = 0x90

# Pokaż po
printf "[*] after:  %02x %02x %02x %02x %02x %02x\n", \
  *(unsigned char*)($PATCH+0), *(unsigned char*)($PATCH+1), \
  *(unsigned char*)($PATCH+2), *(unsigned char*)($PATCH+3), \
  *(unsigned char*)($PATCH+4), *(unsigned char*)($PATCH+5)

printf "[+] PLT patched. memmove zawsze poleci do libc, ignorując ebx.\n"

detach
quit
