# glibc 2.12.1 x86_64 multilib sysroot post-install fix

## What this is

Two header files from glibc 2.12.1's `sysdeps/unix/sysv/linux/x86_64/sys/`:
- `reg.h` — register name constants (RAX, RBX, ORIG_RAX, ...)
- `user.h` — `struct user_regs_struct` with x86_64 fields (rax, orig_rax, ...)

Both use `#if __WORDSIZE == 64` to switch x86_64 vs i386 macros, falling
through to the i386 versions for 32-bit compile.

## Why we need them

ct-ng 1.25 + glibc 2.12.1 multilib install (x86_64 + i686) hits a known
upstream issue: glibc's multilib install picks the **i386 version** of
arch-specific headers (`sys/reg.h`, `sys/user.h`, `bits/select.h`) and
installs them to `<sysroot>/usr/include/sys/`, overwriting the x86_64
versions.

For most code paths this doesn't matter (compilers see kernel `asm/*.h`).
But GDB 16.3 gdbserver's `linux-x86-low.cc` does:

```c
#include <sys/reg.h>
...
#define ORIG_EAX ORIG_RAX     // line 225, inside #ifdef __x86_64__
...
+ ORIG_EAX * REGSIZE          // line 458, expects ORIG_RAX defined
```

The i386 sys/reg.h doesn't define `ORIG_RAX` → build fails with
"'ORIG_RAX' was not declared in this scope".

Same root cause as Phase 1 Error #19 (`bits/select.h`).

## Source

Files fetched 2026-05-09 from sourceware:
- https://sourceware.org/git/?p=glibc.git;a=blob_plain;f=sysdeps/unix/sysv/linux/x86_64/sys/reg.h;hb=refs/tags/glibc-2.12.1
- https://sourceware.org/git/?p=glibc.git;a=blob_plain;f=sysdeps/unix/sysv/linux/x86_64/sys/user.h;hb=refs/tags/glibc-2.12.1

Byte-identical to what a non-multilib glibc 2.12 x86_64 install would have
written. No ABI / symbol-version impact (compile-time only).

## How to apply

```bash
# DESTINATION = the sysroot
SYSROOT=/opt/x-tools/x86_64-centos6-linux-gnu/x86_64-centos6-linux-gnu/sysroot
chmod -R u+w "${SYSROOT}/usr/include/sys"
cp -fv reg.h user.h "${SYSROOT}/usr/include/sys/"
chmod -R u-w "${SYSROOT}/usr/include/sys"   # optional, restore RO
```

`build-phase1-gdbserver.sh` does this automatically before configure.

## Future ct-ng integration

For a fully reproducible Phase 1 build (without post-fix) the long-term
fix is to teach ct-ng to install both versions. That requires patching
glibc's `Makerules` to install x86_64 sysdeps headers under multilib —
non-trivial. Workaround via post-fix is acceptable.
