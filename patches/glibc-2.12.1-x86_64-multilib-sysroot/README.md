# glibc 2.12.1 x86_64 multilib sysroot post-install fix

## What this is

A small overlay of architecture-sensitive glibc 2.12.1 x86 headers, including:
- `bits/wordsize.h` — selects 64-bit vs 32-bit ABI from compiler defines
- `bits/pthreadtypes.h` — uses wordsize-dependent pthread layouts
- `sys/reg.h` — register name constants (RAX, RBX, ORIG_RAX, ...)
- `sys/user.h` — `struct user_regs_struct` with x86_64 fields (rax, orig_rax, ...)

These headers use compiler-defined architecture macros, directly or via
`__WORDSIZE`, so 64-bit compiles see x86_64 definitions while `-m32` compiles
keep seeing i386 definitions.

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

Initial files fetched 2026-05-09 from sourceware:
- https://sourceware.org/git/?p=glibc.git;a=blob_plain;f=sysdeps/unix/sysv/linux/x86_64/sys/reg.h;hb=refs/tags/glibc-2.12.1
- https://sourceware.org/git/?p=glibc.git;a=blob_plain;f=sysdeps/unix/sysv/linux/x86_64/sys/user.h;hb=refs/tags/glibc-2.12.1

Byte-identical to what a non-multilib glibc 2.12 x86_64 install would have
written. No ABI / symbol-version impact (compile-time only).

## How to apply

```bash
# DESTINATION = the sysroot
SYSROOT=/opt/x-tools/x86_64-centos6-linux-gnu/x86_64-centos6-linux-gnu/sysroot
chmod -R u+w "${SYSROOT}/usr/include"
cp -a usr/include/. "${SYSROOT}/usr/include/"
chmod -R u-w "${SYSROOT}/usr/include"   # optional, restore RO
```

`docker-build-target.sh` applies this automatically after the Phase 1 ct-ng
build, before the toolchain is packaged. `build-phase1-gdbserver.sh` also uses a
real CentOS sysroot for its standalone gdbserver build.

## Future ct-ng integration

For a fully reproducible Phase 1 build (without post-fix) the long-term
fix is to teach ct-ng to install both versions. That requires patching
glibc's `Makerules` to install x86_64 sysdeps headers under multilib —
non-trivial. Workaround via post-fix is acceptable.
