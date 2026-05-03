# cs16-fix

> **⚠️ AI-generated** ⚠️
>
> This entire project — the reverse engineering, the analysis, the patch,
> the scripts, and this README — was produced in a single session with an
> LLM (Claude). It worked on my machine after manual testing, but no human
> has reviewed it line-by-line.

Runtime patch for a crash in Steam's voice decoder (`steamclient.so`) that
takes down the Steam client when receiving voice chat in older Source-engine
games (CS 1.6, HL, TF2 Classic, GMod legacy, etc.) on Linux.


## Is this a VAC ban risk?

**Probably not, but not zero.**

## The crash

Steam Voice's Speex-based decoder (function `sub_2709480` in
`steamclient.so`) has an x86 PIC ABI bug: it clobbers the `ebx` register —
which on i386 must hold `_GLOBAL_OFFSET_TABLE_` for PLT calls to work — and
then calls `memmove` through the PLT.

The PLT stub for `memmove` is:

```asm
endbr32
mov   ecx, 0x1ee0
jmp   dword [ebx - 0xb4ec8]   ; expects ebx = GOT base
```

When the codec calls this with `ebx = src_buffer + 0x2d04` instead of the
GOT base, the indirect jump dereferences a random heap address. Most of the
time that address happens to contain *some* valid function pointer (so voice
plays back with audio glitches but no crash). Occasionally it points to a
small integer or unmapped memory and the CPU jumps to garbage — `SIGSEGV`,
Steam dies, you get a coredump in `/var/lib/systemd/coredump/`.

Stack trace looks like this:

```
#0  0x0000000000000025                              <-- bogus jump target
#1  steamclient.so + 0x26fc5c3                      <-- inside sub_2709480
#2  steamclient.so + 0x26faa9d                      <-- decoder dispatch
... (codec chain)
#7  steamclient.so + 0x1924f26  ISteamUser::DecompressVoice
#15 libtier0_s.so   + 0x336ae   SteamThreadTools::CThread::ThreadProc
```

## The fix

We rewrite the 6-byte indirect jump in the `memmove` PLT stub to a direct
absolute jump to the real `libc` `memmove`. This makes the stub independent
of `ebx`, so both correct and broken callers end up at `memmove`
regardless. The patch lives only in process memory.

```
before:  ff a3 38 b1 f4 ff      jmp [ebx - 0xb4ec8]
after:   e9 XX XX XX XX  90     jmp <abs memmove>
```

Done with `gdb` + `ptrace`. Could be done as an `LD_PRELOAD`, but I'm too lazy to implement it since
I don't plan to play cs 1.6 daily.

## Usage

Requires `gdb`, root (for `ptrace`), and Linux.

1. Start Steam, log in, wait for the client UI to be fully loaded.
2. Run:
   ```sh
   sudo ./patch_now.sh
   ```
3. You should see:
   ```
   [+] Steam main PID: <PID>
   [+] steamclient.so base: 0x...
   [*] Patching via gdb...
   [+] Patch applied successfully: e9XXXXXXXX90
   ```
4. Join your CS 1.6 / HL / GMod server and use voice chat.

The patch must be re-applied after every Steam restart (it's only in memory).

## Files

- `patch.gdb` — the actual patch logic (gdb script, finds the steamclient
  base from `/proc/PID/maps`, reads `memmove` from the GOT slot, rewrites
  the PLT)
- `patch_now.sh` — wrapper that locates the Steam process, sanity-checks
  the bytes, runs gdb, and verifies the result

## Compatibility

Tested with a `steamclient.so` build with these offsets (the script
sanity-checks the original bytes before writing — if they don't match it
refuses to patch):

- PLT stub jmp instruction at RVA `0xe1ad19`
- `memmove` GOT.PLT slot at RVA `0x2d936fc`
- Original bytes: `ff a3 38 b1 f4 ff`

If Valve ships a new `steamclient.so` and the bytes change, you'll need to
re-locate the offsets in Binary Ninja / Ghidra / IDA.
