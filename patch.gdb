# Patch buggy memmove PLT call in steamclient.so
# Automatically finds offsets — works across steamclient.so versions.
# Run: sudo gdb -p <STEAM_PID> -batch -x patch.gdb

set pagination off
set confirm off

python
import gdb
import subprocess
import re

def patch():
    pid = gdb.selected_inferior().pid

    # Find steamclient.so base address and file path
    base = None
    so_path = None
    with open('/proc/{}/maps'.format(pid)) as f:
        for line in f:
            if 'steamclient.so' in line:
                if base is None:
                    base = int(line.split('-')[0], 16)
                parts = line.strip().split()
                if so_path is None and len(parts) >= 6 and 'steamclient.so' in parts[-1]:
                    so_path = parts[-1]

    if base is None or so_path is None:
        raise RuntimeError("steamclient.so not found in /proc/{}/maps".format(pid))
    print('[*] steamclient.so base = {}'.format(hex(base)))
    print('[*] path = {}'.format(so_path))

    # Find memmove JUMP_SLOT: GOT offset and index in .rel.plt
    output = subprocess.check_output(['readelf', '-r', so_path]).decode()
    got_offset = None
    memmove_plt_index = None
    in_rel_plt = False
    index = 0
    for line in output.split('\n'):
        if 'Relocation section' in line:
            in_rel_plt = '.rel.plt' in line or '.rela.plt' in line
            index = 0
            continue
        if not in_rel_plt:
            continue
        if 'JUMP_SLOT' not in line:
            continue
        parts = line.split()
        if len(parts) >= 5:
            sym = parts[-1]
            if sym == 'memmove' or sym.startswith('memmove@'):
                got_offset = int(parts[0], 16)
                memmove_plt_index = index
                break
        index += 1

    if got_offset is None or memmove_plt_index is None:
        raise RuntimeError("memmove JUMP_SLOT not found in .rel.plt")

    # Read actual memmove address from GOT
    got_addr = base + got_offset
    memmove = int(gdb.parse_and_eval('*(unsigned int*){}'.format(hex(got_addr))))
    print('[*] memmove GOT: offset={} runtime={} -> {}'.format(
        hex(got_offset), hex(got_addr), hex(memmove)))

    # Find .plt section virtual address
    output = subprocess.check_output(['readelf', '-SW', so_path]).decode()
    plt_vaddr = None
    for line in output.split('\n'):
        m = re.search(r'\]\s+\.plt\s+PROGBITS\s+([0-9a-f]+)', line)
        if m:
            plt_vaddr = int(m.group(1), 16)
            break
    if plt_vaddr is None:
        raise RuntimeError(".plt section not found")

    # PLT layout: PLT[0] (16B resolver) + PLT[1..n] (16B each, same order as .rel.plt)
    plt_entry_vaddr = plt_vaddr + 16 + memmove_plt_index * 16
    plt_entry_addr = base + plt_entry_vaddr
    print('[*] memmove PLT entry: vaddr={} runtime={} (index={})'.format(
        hex(plt_entry_vaddr), hex(plt_entry_addr), memmove_plt_index))

    # Scan PLT entry bytes for indirect jmp (ff /4 = jmp r/m32)
    patch_addr = None
    jmp_len = 0
    for i in range(16):
        b = int(gdb.parse_and_eval('*(unsigned char*){}'.format(hex(plt_entry_addr + i))))
        if b == 0xe9:
            print('[+] Already patched (e9 at offset +{})'.format(i))
            return
        if b == 0xff:
            modrm = int(gdb.parse_and_eval('*(unsigned char*){}'.format(hex(plt_entry_addr + i + 1))))
            if (modrm >> 3) & 7 == 4:
                patch_addr = plt_entry_addr + i
                mod = (modrm >> 6) & 3
                rm = modrm & 7
                if mod == 2 or (mod == 0 and rm == 5):
                    jmp_len = 6
                elif mod == 0 and rm == 4:
                    jmp_len = 7  # SIB + disp32
                elif mod == 1:
                    jmp_len = 3
                else:
                    jmp_len = 2
                break

    if patch_addr is None:
        raise RuntimeError("Could not find indirect jmp in memmove PLT entry")
    if jmp_len < 6:
        raise RuntimeError("jmp instruction too short ({} bytes, need >= 6)".format(jmp_len))

    # Show original bytes
    orig = ' '.join('{:02x}'.format(
        int(gdb.parse_and_eval('*(unsigned char*){}'.format(hex(patch_addr + j))))
    ) for j in range(jmp_len))
    print('[*] before: {}'.format(orig))

    first = int(gdb.parse_and_eval('*(unsigned char*){}'.format(hex(patch_addr))))
    if first != 0xff:
        raise RuntimeError("Unexpected byte at {}: 0x{:02x}".format(hex(patch_addr), first))

    # Replace indirect jmp with direct jmp rel32 to memmove + nop
    rel32 = memmove - (patch_addr + 5)
    print('[*] patching {} -> jmp {} (rel32={})'.format(
        hex(patch_addr), hex(memmove), hex(rel32 & 0xffffffff)))

    gdb.execute('set *(unsigned char*){} = 0xe9'.format(hex(patch_addr)))
    gdb.execute('set *(int*){} = {}'.format(hex(patch_addr + 1), rel32))
    gdb.execute('set *(unsigned char*){} = 0x90'.format(hex(patch_addr + 5)))

    # Verify
    patched = ' '.join('{:02x}'.format(
        int(gdb.parse_and_eval('*(unsigned char*){}'.format(hex(patch_addr + j))))
    ) for j in range(6))
    print('[*] after:  {}'.format(patched))
    print('[+] PLT patched. memmove calls now go directly to libc.')

try:
    patch()
except Exception as e:
    print('[-] Error: {}'.format(e))
finally:
    try:
        gdb.execute('detach')
    except:
        pass
    gdb.execute('quit')
end
