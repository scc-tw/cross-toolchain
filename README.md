<p align="center">
  <img src="./assets/logo.svg" alt="cross-toolchain logo" width="120" height="120"/>
</p>

# cross-toolchain

A Docker image bundling five cross-compilers, a matched Go runtime, and a statically linkable libbpf, designed for projects that need to ship a single CGO binary running on every Linux distribution from CentOS 6 (glibc 2.12, released 2010) through current releases, plus macOS Intel and Apple Silicon. Every binary the image produces is verified to honor the GLIBC ABI floor of its target.

This repository contains the Dockerfiles, build configurations, and patches that produce the public images at:

- `docker.io/leavevm0cl6/cross-toolchain` — five cross-toolchains plus Go and libbpf
- `docker.io/leavevm0cl6/ebpf-builder` — companion image for compiling eBPF programs

[![License](https://img.shields.io/badge/license-GPL--3.0-blue.svg?logo=gnu&logoColor=white)](./LICENSE)
[![Docker Pulls](https://img.shields.io/docker/pulls/leavevm0cl6/cross-toolchain.svg?logo=docker&logoColor=white&color=2496ED)](https://hub.docker.com/r/leavevm0cl6/cross-toolchain)
[![Image Size](https://img.shields.io/docker/image-size/leavevm0cl6/cross-toolchain/latest?logo=docker&logoColor=white&color=2496ED)](https://hub.docker.com/r/leavevm0cl6/cross-toolchain)
[![Image Version](https://img.shields.io/docker/v/leavevm0cl6/cross-toolchain?sort=semver&logo=docker&logoColor=white&color=2496ED)](https://hub.docker.com/r/leavevm0cl6/cross-toolchain/tags)
[![GCC](https://img.shields.io/badge/GCC-15.2.0-FF6F00?logo=gnu&logoColor=white)](https://gcc.gnu.org/gcc-15/)
[![Clang](https://img.shields.io/badge/Clang-18-262D3A?logo=llvm&logoColor=white)](https://releases.llvm.org/18.1.0/tools/clang/docs/ReleaseNotes.html)
[![Go](https://img.shields.io/badge/Go-1.22.12-00ADD8?logo=go&logoColor=white)](https://go.dev/doc/devel/release#go1.22.minor)


## Quick start

```bash
docker pull leavevm0cl6/cross-toolchain:latest

cat > hello.c <<'EOF'
#include <stdio.h>
int main(void) { puts("hello from CentOS 6"); return 0; }
EOF

docker run --rm -v "$PWD:/work" leavevm0cl6/cross-toolchain:latest \
    x86_64-centos6-linux-gnu-gcc -static-libstdc++ -static-libgcc \
        hello.c -o hello

docker run --rm -v "$PWD:/work" leavevm0cl6/cross-toolchain:latest \
    bash -c 'x86_64-centos6-linux-gnu-objdump -T hello |
             grep -oE "GLIBC_[0-9.]+" | sort -uV | tail -1'
# expected output: GLIBC_2.4 or older — runs on any Linux from 2008 onward
```

For an interactive shell with a bind-mounted source tree:

```bash
docker run --rm -it \
    -e HOST_UID=$(id -u) -e HOST_GID=$(id -g) \
    -v "$PWD:/work" \
    leavevm0cl6/cross-toolchain:latest
```

Inside the container, `cross-toolchain-help` displays the full reference for tools, environment variables, and recipes.


## Toolchains

| Triple | Compiler | Target glibc | Target kernel | Deploy floor |
|---|---|---|---|---|
| `x86_64-centos6-linux-gnu` | gcc 15.2.0 | 2.12 | 2.6.32 | CentOS 6, RHEL 6, modern Linux (multilib enabled) |
| `x86_64-centos7-linux-gnu` | gcc 15.2.0 | 2.17 | 3.10.108 | CentOS 7+, RHEL 8+, Ubuntu 18.04+ |
| `aarch64-centos7-linux-gnu` | gcc 15.2.0 | 2.17 | 3.10.108 | CentOS 7+/RHEL 8+ on ARM64 |
| `x86_64-apple-darwin20.4` | clang 18 (osxcross) + SDK 11.3 | n/a (libSystem) | Darwin 20.4 | macOS Intel 10.15 onward |
| `arm64-apple-darwin20.4` | clang 18 (osxcross) + SDK 11.3 | n/a (libSystem) | Darwin 20.4 | macOS Apple Silicon 11.0 onward |

Plus Go 1.22.12, the latest Go release that simultaneously covers CentOS 6 (Linux 2.6.32) and macOS 10.15. Generics, slog, and the loop-variable fix are all available; range-over-func is not.


## Statically linkable libbpf for CentOS 6

The image includes a pre-built `libbpf.a` and its dependency archives (`libelf.a`, `libz.a`, `libzstd.a`), all cross-compiled with the glibc 2.12 toolchain. This permits a single CGO binary to statically link libbpf and decide at runtime whether to attempt a BPF program load: skipped on kernels that lack eBPF, attached on modern ones. Such a binary's verified GLIBC ABI floor is 2.9, which means it runs unmodified on any Linux from 2008 onward.

```bash
docker run --rm -v "$PWD:/work" leavevm0cl6/cross-toolchain:latest \
    bash -c '
        CC=x86_64-centos6-linux-gnu-gcc CGO_ENABLED=1 \
        CGO_CFLAGS="-I$PHASE1_LIBBPF_INCLUDE -I$PHASE1_EXTRAS_INCLUDE \
                    -include $PHASE1_EXTRAS_COMPAT" \
        CGO_LDFLAGS="$PHASE1_LIBBPF_A $PHASE1_LIBELF_A \
                     $PHASE1_LIBZ_A $PHASE1_LIBZSTD_A -lpthread" \
        GOOS=linux GOARCH=amd64 \
        go build -o sensor ./cmd/sensor
    '
```

The relevant paths are exposed as environment variables inside the container:

| Variable | Contents |
|---|---|
| `PHASE1_LIBBPF_A` | pre-built `libbpf.a` (libbpf master, version 1.8.0) |
| `PHASE1_LIBBPF_INCLUDE` | libbpf API headers (`bpf/libbpf.h`, `bpf/bpf.h`, `bpf/btf.h`, ...) |
| `PHASE1_LIBELF_A` | `libelf.a` (elfutils 0.191) |
| `PHASE1_LIBZ_A` | `libz.a` (zlib 1.3.1) |
| `PHASE1_LIBZSTD_A` | `libzstd.a` (zstd 1.5.6) |
| `PHASE1_EXTRAS_INCLUDE` | cherry-picked Linux UAPI headers (`linux/bpf.h`, `linux/btf.h`, ...) |
| `PHASE1_EXTRAS_COMPAT` | small additive header providing `__aligned_u64` for the glibc 2.12 sysroot |

The `PHASE1_*` prefix is historical: the libbpf extras are cross-compiled in Phase 1 of the build pipeline. The full design rationale is documented in [docs/docker-experiments.md](./docs/docker-experiments.md), section 6.


## Image variants

```
leavevm0cl6/cross-toolchain:1.0       Pinned version (recommended for CI)
leavevm0cl6/cross-toolchain:latest    Alias for the current 1.x release
leavevm0cl6/ebpf-builder:1.0          Companion image for BPF program compilation
leavevm0cl6/ebpf-builder:latest       Alias for the current 1.x release
```

For maximum reproducibility, pin to the image digest rather than a tag:

```bash
docker pull leavevm0cl6/cross-toolchain@sha256:f024f9207ad7...
```

Both images target `linux/arm64` at present. They run natively on Apple Silicon hosts and via QEMU/binfmt on Linux x86_64 hosts.


## Building the image yourself

The image is produced in four phases that run independently, then a final compositor stage assembles them. Each phase has its own Dockerfile at the repository root:

```
Dockerfile.phase1         x86_64-centos6-linux-gnu (ct-ng 1.25 with GCC 15 backport, glibc 2.12)
Dockerfile.phase2         aarch64-centos7-linux-gnu (ct-ng 1.28 native, glibc 2.17)
Dockerfile.phase3         osxcross with macOS SDK 11.3 (Intel and Apple Silicon)
Dockerfile.phase4         x86_64-centos7-linux-gnu (ct-ng 1.28 native, glibc 2.17)
Dockerfile.all            Final consumer image, combines all four phases plus Go and libbpf extras
Dockerfile.ebpf-builder   Companion image: clang-19, bpftool, and libbpf headers
```

Phase 1, 2, and 4 are builder images. Running `docker build` on each produces an image that, when invoked with `docker run`, executes `crosstool-ng` and emits a toolchain tarball into a mounted volume. Phase 3 builds osxcross directly inside its image. Phase 1 additionally requires CentOS 6 RPM artifacts for its gdbserver build; the helper script is at `scripts/prepare-centos6-real-sysroot.sh`.

Detailed build instructions, including the GCC 15 backport patches and macOS 26 host fixes, live in:

- [docs/crosstool-ng-explained.md](./docs/crosstool-ng-explained.md), the internal mechanics of crosstool-ng (Chinese, ~118 KB)
- [docs/docker-experiments.md](./docs/docker-experiments.md), the phase-by-phase Docker build journal (Chinese, ~219 KB)


## Why CentOS 6 / glibc 2.12

CentOS 6 reached end of life on 2020-11-30, but enterprise customers running long-lifecycle deployments still operate it. A single binary that targets glibc 2.12 — the version shipped with CentOS 6 — also runs on every glibc release since, because glibc is forward-compatible by ABI. One binary therefore covers CentOS 6 through current Ubuntu and RHEL releases, the same model the [manylinux](https://github.com/pypa/manylinux) project applies to Python wheels and the [holy-build-box](https://github.com/phusion/holy-build-box) project applies to standalone Linux executables.

The image goes one step beyond manylinux and holy-build-box by including a statically linkable libbpf cross-compiled against the CentOS 6 sysroot. This enables the rare combination of deploys-on-CentOS-6-onward and uses-eBPF-when-the-runtime-kernel-supports-it, with the user-space program deciding at startup whether to attempt the BPF load.


## Comparison to similar projects

| Project | Targets | Deploy floor | libbpf included | macOS support |
|---|---|---|---|---|
| cross-toolchain (this repository) | Linux x86_64 / aarch64, macOS Intel / Apple Silicon | glibc 2.12 (CentOS 6) | yes, statically linkable | yes (osxcross) |
| [dockcross](https://github.com/dockcross/dockcross) | 30+ Linux targets and Windows | varies per image; none as low as 2.12 | no | no |
| [holy-build-box](https://github.com/phusion/holy-build-box) | Linux x86_64 only | glibc 2.17 (CentOS 7) | no | no |
| [manylinux](https://github.com/pypa/manylinux) | Linux x86_64 / aarch64 / ppc64le / s390x | glibc 2.17 (manylinux2014) or 2.28 (manylinux_2_28) | no | no |
| [musl-cross-make](https://github.com/richfelker/musl-cross-make) | Linux x86_64 / aarch64 | n/a (musl) | no | no |

Choose `cross-toolchain` if both glibc 2.12 and macOS targets are needed in a single image. Choose `dockcross` for exotic Linux targets such as PowerPC, MIPS, or RISC-V where CentOS 6 support is irrelevant.


## Repository layout

```
cross-toolchain/
├── README.md                      this file
├── LICENSE                        GPL-3.0
├── Dockerfile.phase1              x86_64-centos6 cross-toolchain builder
├── Dockerfile.phase2              aarch64-centos7 cross-toolchain builder
├── Dockerfile.phase3              osxcross with macOS SDK 11.3 builder
├── Dockerfile.phase4              x86_64-centos7 cross-toolchain builder
├── Dockerfile.all                 final consumer image (cross-toolchain:latest)
├── Dockerfile.ebpf-builder        companion eBPF program build image
│
├── docs/                          design and build documentation (Chinese)
│   ├── crosstool-ng-explained.md  internal mechanics of crosstool-ng
│   ├── docker-experiments.md      phase-by-phase Docker build journal
│   └── crowdstrike-ebpf-research.md  eBPF kernel-requirement research
│
├── scripts/                       helper scripts invoked from Dockerfiles
├── configs/                       crosstool-ng .defconfig files (one per phase)
├── patches/                       crosstool-ng and glibc backport patches
├── vendor/                        upstream source archives (ct-ng, SDK)
├── dist/                          image build inputs (gitignored)
├── assets/                        README assets
└── smoke-test/                    end-to-end build verification
```


## Verifying ABI floor in CI

Add this gate to every build that produces a binary intended for old-glibc deployment:

```bash
MAX=$(x86_64-centos6-linux-gnu-objdump -T sensor |
        grep -oE 'GLIBC_[0-9.]+' | sort -uV | tail -1)
case "$MAX" in
    GLIBC_2.[0-9]|GLIBC_2.1[0-2]) echo "OK: $MAX" ;;
    *) echo "FAIL: $MAX exceeds glibc 2.12 floor"; exit 1 ;;
esac
```

This is the same approach `auditwheel` takes for Python wheels.


## Contributing

Bug reports and patches are welcome via GitHub issues and pull requests. Patches that touch the GCC 15 backport for crosstool-ng 1.25 should preserve the structure documented in [docs/crosstool-ng-explained.md](./docs/crosstool-ng-explained.md).


## License

Released under [GPL-3.0](./LICENSE). The image bundles GCC, binutils, glibc, libbpf, libelf, zlib, zstd, osxcross, and Go; each retains its upstream license. The macOS SDK 11.3 (sourced via [joseluisq/macosx-sdks](https://github.com/joseluisq/macosx-sdks)) is subject to Apple's licensing terms; consult Apple's macOS SDK Agreement before redistributing.


## Acknowledgements

- [crosstool-NG](https://crosstool-ng.github.io/), the cross-toolchain generator that does the heavy lifting in phases 1, 2, and 4.
- [osxcross](https://github.com/tpoechtrager/osxcross), the macOS cross-toolchain in phase 3.
- [libbpf](https://github.com/libbpf/libbpf) and [bpftool](https://github.com/libbpf/bpftool), the BPF userspace runtime.
- [joseluisq/macosx-sdks](https://github.com/joseluisq/macosx-sdks), distribution of the macOS 11.3 SDK.
- [manylinux](https://github.com/pypa/manylinux) and [holy-build-box](https://github.com/phusion/holy-build-box), for pioneering the "compile against an old glibc to ship one binary everywhere" pattern.
