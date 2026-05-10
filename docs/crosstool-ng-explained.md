# 深入解析：用 crosstool-ng 從 macOS 26 跨編 Linux x86_64 + glibc 2.12

> **環境**：macOS arm64 (Apple Silicon, Darwin 25.x)、crosstool-NG 1.25.0、GCC 11.2.0、glibc 2.12.1、brew gcc 14 當 host compiler。
> **目標**：產出 Linux x86_64 binary，能跑在 CentOS 6 (glibc 2.12 / kernel 2.6.32)，與 reference toolchain ABI 完全對齊。
> **狀態**：✅ build 成功，11 次嘗試後完成。每個概念都對照 crosstool-NG 官方文件[^1] 跟 GNU/POSIX 手冊。

---

## 給新手的 5 分鐘 TL;DR

**問題**：你的 Mac 是 2026 macOS 26 + Apple Silicon，但你要編 binary 給跑 CentOS 6（glibc 2.12，2010 年 OS、2009 年 kernel）的客戶。Mac 本身沒有 Linux 編譯器，需要一個跨平台 toolchain。

**這個 directory 提供什麼**：
- `toolchain/scripts/build.sh` — Mac 上 build cross-compiler 的 driver script
- `toolchain/configs/x86_64-centos6-glibc212.defconfig` — ct-ng 設定
- `toolchain/vendor/` — ct-ng 1.25 source（用 GitHub 上 release 直接下）
- 各種 patch 跟 wrapper（在 `tmp/` 內，不入 git）

**三個一定要先抓到的概念**：
1. **三條獨立軸線** — BUILD（你 build toolchain 的機器）、HOST（toolchain 之後跑的機器）、TARGET（toolchain 吐什麼 binary）。我們：BUILD=HOST=Mac arm64、TARGET=Linux x86_64 + glibc 2.12。
2. **glibc symbol versioning 只往前相容** — `puts@GLIBC_2.2.5` 表示「2.2.5 加進來的 puts」、能跑在任何 ≥ 2.2.5 的 glibc。binary 內最高的 `@GLIBC_X.Y` = floor。
3. **toolchain = 一束東西** — gcc + binutils + sysroot（target 的 `/lib` + `/usr/include` 快照）。三者缺一不可。

**這個 toolchain 跟 reference 對齊**：reference 已經有自己的 `x86_64-centos6-linux-gnu-gcc 11.2.0`，我們從它的 `gcc -v` 輸出反推完整 config，產出 ABI identical 的版本。

**怎麼跑**：
```bash
bash toolchain/scripts/build.sh
# ~30-40 分鐘，產出在 ~/x-tools/x86_64-centos6-linux-gnu/
```

**怎麼用**：
```bash
PREFIX=~/x-tools/x86_64-centos6-linux-gnu
$PREFIX/bin/x86_64-centos6-linux-gnu-gcc hello.c -o hello
file hello   # ELF 64-bit, x86-64, Linux

# cgo Go 用法
export PATH=$PREFIX/bin:$PATH
CC=x86_64-centos6-linux-gnu-gcc CGO_ENABLED=1 GOOS=linux GOARCH=amd64 go build ./cmd/sensor
```

---

> ## ⚠️ 重要前提
>
> **crosstool-NG 在 2018-11-26 [官方放棄 macOS 支援](https://crosstool-ng.github.io/2018/11/26/macos.html)[^23]。** 這 directory 一系列的修法是社群繞過上游放棄 macOS 之後累積的。**只在 macOS 26 + Apple Silicon 驗證過**。換 macOS 版本可能得重新踩一輪坑。

---

## 目錄

- [給新手的 5 分鐘 TL;DR](#給新手的-5-分鐘-tldr)
- [一個照理講不可能的謎題](#一個照理講不可能的謎題)
- [三個一定要建立的心智模型](#三個一定要建立的心智模型)
  - [Insight 1：跨平台編譯有「三」條軸線](#insight-1跨平台編譯有三條軸線不是兩條)
  - [Insight 2：glibc symbol versioning 只能往前相容](#insight-2glibc-symbol-versioning-只能往前相容)
  - [Insight 3：toolchain 是一束 compiler + binutils + sysroot](#insight-3toolchain-是一束compiler--binutils--sysroot不只-compiler)
- [Mechanism 1：crosstool-ng bootstrap 的 16 個 step](#mechanism-1crosstool-ng-bootstrap-的-16-個-step細節版)
  - [名詞先定](#名詞先定)
  - [for_build vs for_host 分類](#一個關鍵概念for_buildvsfor_host分類)
  - [完整 16 step](#完整-16-step)
  - [為什麼順序非變不可](#為什麼順序非變不可)
- [Mechanism 2：sysroot 解剖](#mechanism-2sysroot-解剖)
- [Mechanism 3：為什麼 macOS 需要 case-sensitive 檔案系統](#mechanism-3為什麼-macos-需要-case-sensitive-檔案系統)
- [Mechanism 4：Mac 上 cross-build 的兩種 libc](#mechanism-4mac-上-cross-build-的兩種-libc)
  - [libc++ 21 害我們踩的坑](#libc-21-害我們踩的坑)
  - [_FORTIFY_SOURCE macro 的副作用](#_fortify_source-macro-的副作用)
- [Mechanism 5：vendor 欄位有意義嗎](#mechanism-5vendor-欄位有意義嗎)
  - [vendor 的實際影響](#vendor-的實際影響)
  - [為什麼還是寫 centos6](#為什麼還是寫-centos6)
- [Mechanism 6：1.28 era 早期失敗 — 為什麼會 pivot 到 1.25](#mechanism-6128-era-早期失敗--為什麼會-pivot-到-125)
  - [Finding #A：case-sensitive FS abort](#pre-pivot-finding-a--your-file-system-is-not-case-sensitive)
  - [Finding #B：ncurses gawk LANG-unset bug](#pre-pivot-finding-b--ncurses-no-rule-to-make-target-libncursesa)
  - [Finding #C：brew bash 5 + CF fork-safety SIGSEGV](#pre-pivot-finding-c--brew-bash-5--macos-26-coreFoundation-fork-safety-sigsegv)
  - [Finding #D：1.28 偷換 glibc 2.42 → pivot trigger](#pre-pivot-finding-d--128-build-完才發現-glibc-是-242-不是-212pivot-trigger)
  - [Finding #E：reference reverse-engineering](#pre-pivot-finding-e--reference-反向工程發現-125--gcc-11-才對齊)
  - [Mechanism 6 總結](#mechanism-6-總結128-era-的-5-個-finding-教什麼)
- [Mechanism 7：11 次失敗 + 1 個遺留 error 的詳解](#mechanism-711-次失敗--1-個遺留-error-的詳解)
  - [總覽表](#總覽表)
  - [Fix #1：ct-ng 1.28 偷換 glibc 2.42](#fix-1--ct-ng-128-偷換-glibc-242-而非-212)
  - [Fix #2：bash `${var^^}` syntax fail](#fix-2--bash-var-bad-substitution)
  - [Fix #3：zlib URL 404](#fix-3--zlib-1212-download-url-404)
  - [Fix #4：glibc/linux 版本 pin 沒被 honored](#fix-4--glibc--linux-版本-pin-沒被-honoredfall-through-到-235--516)
  - [Fix #5：zlib fdopen 撞 macOS](#fix-5--zlib-_stdioh32-expected-identifier-fdopen-撞-macos)
  - [Fix #6：gettext obstack.c clang 21](#fix-6--gettext-obstackc-撞-apple-clang-21-strict-mode)
  - [Fix #7：binutils libiberty PTR](#fix-7--binutils-libiberty-ptr-undeclared)
  - [Fix #8：unifdef.c strlcpy 撞 macOS](#fix-8--linux-kernel-unifdefc-expected-parameter-declarator)
  - [Fix #9：GCC 11 vs Apple libc++ 21](#fix-9--stage-1-gcc-撞-apple-libc-21-__abi_tag__)
  - [Fix #10：ct-ng 拒絕 CC env var](#fix-10--ct-ng-拒絕-cc-env-var)
  - [Fix #11：GCC 14 不認 clang flag](#fix-11--gcc-14-不認得-clang-only-flag)
  - [遺留 error：成功 build 仍報 1 個非致命 error](#遺留-error--成功-build-仍報-1-個非致命-error)
  - [修法物件分類速查](#修法物件分類速查)
  - [教訓](#教訓)
- [業界 context：50 個 production project](#業界-context50-個-production-project-的-toolchain-pattern)
- [Distribution：怎麼把 toolchain 給其他人](#distribution怎麼把-toolchain-給其他人)
  - [選項 A：Brew tap（推薦）](#選項-abrew-tap推薦)
  - [選項 B：Tart VM](#選項-btart-vm如果要-image-based)
  - [選項 C：直接 tarball](#選項-c直接-tarball)
  - [為什麼 Docker 不是選項](#為什麼-docker-不是選項)
- [進階話題：跨 macOS 版本相容性](#進階話題跨-macos-版本相容性)
- [怎麼除錯下一個你會踩到的坑](#怎麼除錯下一個你會踩到的坑)
- [Quick reference：ct-ng 重要 config option](#quick-referencect-ng-重要-config-option)
- [附錄 A：brew 依賴每個 package 解釋](#附錄-abrew-依賴每個-package-解釋初學者向)
- [附錄 B：build-1.25.sh 完整逐區段解析](#附錄-bbuild-125sh-完整逐區段解析)
- [附錄 C：defconfig 完整逐行解析](#附錄-cdefconfig-完整逐行解析)
- [附錄 D：兩個 patches 完整內容](#附錄-d兩個-patches-完整內容)
- [附錄 E：ct-ng 安裝後手動修改清單](#附錄-ect-ng-安裝後手動修改清單)
- [附錄 F：ct-ng 1.25 從 source build 步驟](#附錄-fct-ng-125-從-source-build-步驟)
- [附錄 G：`#include <>` 怎麼找到 header](#附錄-ginclude--怎麼找到-header初學者向)
- [附錄 H：常見編譯 error 速查](#附錄-h常見編譯-error-速查)
- [註腳 / 參考](#註腳--參考)

---

## 一個照理講不可能的謎題

你在 2026 macOS Tahoe 26 + Apple Silicon 上。你要：
- 編 cgo Go 程式（C++20 features）
- 輸出 Linux x86_64 binary
- 跑在 CentOS 6（2010 釋出，2020 EOL）glibc 2.12 + kernel 2.6.32
- 同時能整合進已有的 reference codebase（也是 glibc 2.12 + Bitdefender SDK）

聽起來像時光旅行：用 16 年後的 OS 編 16 年前的 OS 用的程式。但這正是 cross-toolchain 的 sweet spot。本文一次解釋每個機制、每個踩過的坑、每個修法為什麼這樣修。

---

## 三個一定要建立的心智模型

> 後面每個 mechanism 章節都會繞回這三個。卡住就回來重讀。

### Insight 1：跨平台編譯有「三」條軸線，不是兩條

大多數 build 是 native（單條軸線）：「我在 Linux x86_64，編給 Linux x86_64」。

cross-compile 三條：

| 軸 | 意思 | 我們的值 |
|---|---|---|
| BUILD | 跑 ct-ng 的機器 | Mac arm64 |
| HOST | 之後 toolchain 會被 invoke 的機器 | Mac arm64 |
| TARGET | toolchain 產出 binary 的目標環境 | Linux x86_64 + glibc 2.12 |

BUILD = HOST ≠ TARGET 叫 *cross compiler*。三個都不一樣叫 *Canadian cross*（很罕見）。三個都一樣是 *native*。

**關鍵**：cross-compiler **本身是 Mac binary**（Mach-O），但**它輸出的東西是 Linux ELF**。「能跑哪」跟「會吐什麼格式」是兩回事。

### Insight 2：glibc symbol versioning 只能往前相容

每個 glibc function 都帶 version label：`puts@GLIBC_2.2.5`、`__libc_start_main@GLIBC_2.34`。version 永遠不會被砍掉，只會新增。

例子：
```
glibc 2.0 (1997)   exports: memcpy@GLIBC_2.0
glibc 2.14 (2011)  adds:    memcpy@GLIBC_2.14   (修了 overlap 行為)
                   STILL EXPORTS:  memcpy@GLIBC_2.0   (不能弄壞舊 binaries)
glibc 2.40 (2024)  STILL EXPORTS: 兩個版本
```

**規則**：binary 的 *最低 glibc 需求* = 它 reference 的 *最高 `@GLIBC_X.Y`*。新 host：✓（有所有舊 symbol）。舊 host：✗（少了新的）。

驗證任何 binary[^4]：
```bash
$ objdump -T your-binary | grep -oE 'GLIBC_[0-9.]+' | sort -uV | tail -3
GLIBC_2.7
GLIBC_2.9
GLIBC_2.11    ← 這支 binary 要 glibc ≥ 2.11
```

**為什麼這讓「舊 glibc target」工作**：compiler 不需要老 — 它只要避免 emit 比 target glibc 新的 symbol。新 compiler 指到舊 sysroot 就辦得到（Insight 3）。

### Insight 3：toolchain 是一束「compiler + binutils + sysroot」，不只 compiler

打 `gcc hello.c -o hello` 時，4 個 software 跑：

```
hello.c  →  gcc (compiler)         →  hello.s   (assembly)
hello.s  →  as  (assembler)        →  hello.o   (object)
hello.o  →  ld  (linker)           →  hello     (executable)
                                      ↑
                                      連向系統 (= "sysroot") 的 libc.so.6, libstdc++.so.6, ...
```

cross toolchain 每樣都換變體：
- `gcc` → `x86_64-centos6-linux-gnu-gcc`
- `as` → `x86_64-centos6-linux-gnu-as`  
- `ld` → `x86_64-centos6-linux-gnu-ld`
- libc 跟 headers 不在 `/lib` `/usr/include`（那是你 Mac 的）→ 在 sysroot 目錄：`<prefix>/x86_64-centos6-linux-gnu/sysroot/lib/libc.so.6`、`<prefix>/x86_64-centos6-linux-gnu/sysroot/usr/include/stdio.h`

**舊 glibc + 新 GCC 的 magic 是**：
1. compiler (GCC 11) 知道 C++20、有現代 optimization
2. sysroot 裡 `libc.so.6` 只 export 到 GLIBC_2.12 的 symbol
3. GCC 指向舊 sysroot 時，*只 emit* 那些 sysroot 有的 symbol
4. 結果：binary reference 都 ≤ 2.12，能跑在 CentOS 6

---

## Mechanism 1：crosstool-ng bootstrap 的 16 個 step（細節版）

ct-ng 不能直接下載 GCC 跑就好。GCC 要 glibc 才 build 完整、glibc 要 GCC 才能編 — 雞生蛋蛋生雞。解法是把 build 拆成 16 個有序 step、每 step 砍掉部分依賴：

### 名詞先定

```
BUILD  = aarch64-apple-darwin25 (Mac)
HOST   = aarch64-apple-darwin25 (跟 BUILD 一樣)
TARGET = x86_64-centos6-linux-gnu

兩個目錄:
BUILDTOOLS_DIR  = .build/x86_64-centos6-linux-gnu/buildtools/
                  ← ct-ng 「build 過程內部用的」中間工具，build 完丟掉
PREFIX_DIR      = ~/x-tools/x86_64-centos6-linux-gnu/
                  ← 最終交付給 user 的 toolchain
SYSROOT         = $PREFIX_DIR/x86_64-centos6-linux-gnu/sysroot/
                  ← 模擬 target 的 / 跟 /usr/include
```

### 一個關鍵概念：「for_build」vs「for_host」分類

ct-ng 把 component 分兩類：
- **for_build**：build 過程中 ct-ng 自己會 invoke 的 utility（m4、autoconf 那些）→ 裝 BUILDTOOLS_DIR、用完丟
- **for_host**：最終 toolchain 內會 link 的 library（gmp、mpfr、ncurses）→ 裝 PREFIX_DIR、隨 toolchain 出貨

`m4` / `automake` 只有 for_build（user 不用 m4），`gmp` / `mpfr` 只有 for_host（gcc 內部 link 它們）。`ncurses` 兩個都有（特殊 — for_build 出 `tic` 給 for_host 自己用）。

### 完整 16 step

| # | Step name | 編譯器 | 組譯器 | 連結器 | 目的 | 輸出格式 |
|---|---|---|---|---|---|---|
| 1 | companion_tools_for_build | brew gcc-14 | Apple as | Apple ld | m4/automake 等小工具 | Mac Mach-O |
| 2 | companion_libs_for_build | brew gcc-14 | Apple as | Apple ld | ncurses (給 step 5 用 tic) | Mac Mach-O .a |
| 3 | binutils_for_build | brew gcc-14 | Apple as | Apple ld | cross-as / cross-ld 「給 ct-ng 中間用」 | Mac Mach-O |
| 4 | companion_tools_for_host | brew gcc-14 | Apple as | Apple ld | 同 step 1 但裝 PREFIX_DIR | Mac Mach-O |
| 5 | companion_libs_for_host | brew gcc-14 | Apple as | Apple ld | gmp/mpfr/mpc/isl/ncurses/zlib/libiconv/gettext | Mac Mach-O .a |
| 6 | binutils_for_host | brew gcc-14 | Apple as | Apple ld | 最終 cross-binutils（user 用） | Mac Mach-O |
| 7 | cc_core (stage-1 GCC) | brew gcc-14 | Apple as | Apple ld | 殘缺 cross-gcc，下一步編 glibc 用 | Mac Mach-O |
| 8 | kernel_headers | (純 file copy) | - | - | sysroot/usr/include/linux/* | 文字 .h |
| 9 | libc_start_files (glibc 第一刀) | step 7 stage-1 gcc | step 3 cross-as | (no link) | sysroot/usr/lib/crt1.o, headers | Linux ELF .o |
| 10 | cc_for_build (stage-1.5 GCC) | brew gcc-14 | Apple as | Apple ld | 升級殘缺 gcc，能 build 完整 libgcc | Mac Mach-O |
| 11 | libc (glibc 第二刀，完整) | step 10 stage-1.5 gcc | step 3 cross-as | step 3 cross-ld | sysroot/lib/libc.so.6 等 | Linux ELF .so / .a |
| 12 | cc_for_host (stage-2 GCC, **★ 最終 ★**) | brew gcc-14 | Apple as | Apple ld | user 用的 cross-gcc + libstdc++ | Mac Mach-O + Linux ELF |
| 13 | companion_libs_for_target | step 12 cross-gcc | step 6 cross-as | step 6 cross-ld | sysroot/usr/lib/libgmp.so 等 | Linux ELF .so |
| 14 | binutils_for_target | step 12 cross-gcc | step 6 cross-as | step 6 cross-ld | sysroot/usr/bin/as 等 | Linux ELF |
| 15 | debug | (skipped, CT_DEBUG_GDB=n) | - | - | gdb cross-debugger | - |
| 16 | test_suite | (skipped) | - | - | optional test | - |

### 為什麼順序非變不可

每 step 依賴前一個：
- step 7 (stage-1 gcc) 依賴 step 6 cross-binutils 跟 step 5 companion libs
- step 9 (glibc headers + crt) 依賴 step 7 stage-1 gcc + step 8 kernel headers
- step 10 (stage-1.5 gcc) 依賴 step 9 glibc headers
- step 11 (full glibc) 依賴 step 10 stage-1.5 gcc + step 9 crt files
- step 12 (final gcc with libstdc++) 依賴 step 11 full glibc

**glibc 為什麼分兩刀**：完整 glibc 的 `make all` 在 configure 階段要 link test program → 要 startup objects (crt) + libgcc → 但這些之前還沒。所以 step 9 先 build 出 glibc headers + crt object（不需要 libc.a 也能 build，因為它們本身就是 libc 的一部分）；step 10 用這些補完整版 libgcc；step 11 終於能 build full libc。

**GCC 為什麼三刀**：
- step 7 (cc_core) — 殘缺：`--without-headers --with-newlib --disable-shared --disable-libstdc++-v3`
- step 10 (cc_for_build) — 升級：拿掉 `--without-headers`，能 build libgcc
- step 12 (cc_for_host) — 完整：加 `--enable-languages=c,c++ --enable-shared --enable-libstdc++` 這時 sysroot 有 libc，libstdc++ 能 build

`ct-ng list-steps` 可以列出來：
```bash
$ ct-ng list-steps
INFO :: Available build steps, in order:
  - companion_tools_for_build
  - companion_libs_for_build
  - binutils_for_build
  - companion_tools_for_host
  - companion_libs_for_host
  - binutils_for_host
  - cc_core              ← stage-1 GCC
  - kernel_headers
  - libc_start_files     ← glibc 第一刀
  - cc_for_build         ← stage-1.5 GCC
  - libc                 ← glibc 第二刀
  - cc_for_host          ← stage-2 GCC（最終）
  - companion_libs_for_target
  - binutils_for_target
  - debug
  - test_suite
```

順序 hard-coded。fail 在哪 step 可以 `ct-ng <step>` resume，前面的不會重做（除非 source 改）。

---

## Mechanism 2：sysroot 解剖

build 完後 prefix 結構：

```
~/x-tools/x86_64-centos6-linux-gnu/         ← prefix (CT_PREFIX_DIR)
├── bin/                                      Mac arm64 binaries (HOST)
│   ├── x86_64-centos6-linux-gnu-gcc           ← compiler
│   ├── x86_64-centos6-linux-gnu-g++           ← C++ frontend
│   ├── x86_64-centos6-linux-gnu-ld            ← linker
│   ├── x86_64-centos6-linux-gnu-ar            ← archiver
│   ├── x86_64-centos6-linux-gnu-strip         ← ELF strip
│   ├── x86_64-centos6-linux-gnu-objdump       ← inspector
│   └── ...
│
├── lib/gcc/x86_64-centos6-linux-gnu/11.2.0/   GCC 自己的 helper
│   ├── libgcc.a                                ← integer divmod, fp ops, ...
│   ├── libgcc_eh.a                             ← exception unwinding (static)
│   └── crtbegin.o, crtend.o                    ← C++ static init dispatch
│
└── x86_64-centos6-linux-gnu/sysroot/           ← TARGET 檔案系統快照
    ├── lib/
    │   ├── libc.so.6                           ← glibc 2.12 binary
    │   ├── ld-linux-x86-64.so.2                ← target 動態連結器
    │   ├── libpthread.so.0
    │   ├── libdl.so.2
    │   └── libstdc++.so.6                      ← C++ runtime (來自 GCC 11)
    ├── usr/include/                            ← #include <foo.h> 找的地方
    │   ├── stdio.h
    │   ├── stdlib.h
    │   ├── linux/                              ← kernel UAPI (來自 Linux 2.6.32)
    │   │   ├── socket.h
    │   │   └── ...
    │   ├── asm/
    │   └── c++/11.2.0/                         ← libstdc++ headers
    └── usr/lib/
        ├── libc.a                              ← static glibc
        ├── libstdc++.a
        └── crt1.o, crti.o, crtn.o              ← startup objects
```

兩件要消化的：

**(a) `bin/` 是 HOST binary、sysroot/ 裡是 TARGET binary。**
```bash
$ file ~/x-tools/.../bin/x86_64-centos6-linux-gnu-gcc
... Mach-O 64-bit executable arm64    ← Mac 程式

$ file ~/x-tools/.../sysroot/lib/libc.so.6
... ELF 64-bit LSB shared object, x86-64    ← Linux 程式
```

**(b) C++ headers 是新的 (GCC 11)、libc binary 是舊的 (glibc 2.12)。** 這正好是 Insight 3：新 compiler、舊 runtime。寫 `#include <ranges>` (C++20) gcc 從 `c++/11.2.0/` 讀；call `memcpy` 連到 `lib/libc.so.6` (glibc 2.12)。

驗證：
```bash
$ ls ~/x-tools/.../sysroot/usr/include/c++/11.2.0/ranges
# 存在 — C++20 ranges header

$ ~/x-tools/.../bin/x86_64-centos6-linux-gnu-objdump -T ~/x-tools/.../sysroot/lib/libc.so.6 | grep -oE 'GLIBC_[0-9.]+' | sort -uV | tail -1
GLIBC_2.12        ← 舊 libc
```

---

## Mechanism 3：為什麼 macOS 需要 case-sensitive 檔案系統

Linux source code 有像 `Makefile` 跟 `makefile`、`Stack.c` 跟 `stack.c` 只差大小寫的檔案。macOS APFS / HFS+ 預設 **case-insensitive** → ct-ng 直接 abort：

```
[ERROR]  Your file system in '...' is *not* case-sensitive!
```

驗證：
```bash
$ touch /tmp/A /tmp/a
$ ls /tmp | grep -i '^a$'
A                  ← 只有一個檔；第二個 touch 蓋掉
                     (case-sensitive FS 兩個都會在)
```

**修法**：建 case-sensitive sparseimage：
```bash
hdiutil create -type SPARSE -size 30g -fs "Case-sensitive Journaled HFS+" \
    -volname ct-build /path/to/ct-build
hdiutil attach /path/to/ct-build.sparseimage
# 掛在 /Volumes/ct-build/
```

`build-1.25.sh` 自動偵測 + 建 sparseimage。**WORK_DIR 跟 PREFIX_DIR 兩個都**要 case-sensitive — ct-ng 兩個都檢查。

我們用 **HFS+** 不用 APFS（messense CI[^11] 也選 HFS+），因為 APFS 的 metadata semantics 跟 ncurses parallel build 不對盤、會 race。

---

## Mechanism 4：Mac 上 cross-build 的「兩種 libc」

這是 macOS 上獨有的概念混淆。要分清楚 **3 個 libc**：

```
1. Mac 系統 libc (libSystem.B.dylib)
   = 你的 Mac 上跑任何 Mach-O 程式的依賴
   = cross-gcc 二進制檔本身連向這個（因為它是 Mac 程式）
   
2. Apple Clang 的 C++ 標準庫 (libc++ 21)
   = 在 macOS 26 SDK 內：/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/include/c++/v1/
   = LLVM 出的 STL 實作
   = 用 -stdlib=libc++ flag (Apple 預設)
   
3. Target sysroot glibc (glibc 2.12)
   = 我們 build 出來放在 sysroot 內
   = cross-gcc 編 user code 時連向這個
   = 跟前兩個完全無關
```

混淆的地方：cross-gcc 編譯時用 (1) 跟 (2)（讓 cross-gcc 自己跑得起來），但編 user code 時連向 (3)（讓 user code 跑得了 Linux）。

### libc++ 21 害我們踩的坑

GCC 11 source 是 2021 寫的，預期 host C++ stdlib 是 2021 之前的 libc++ 或 libstdc++。Apple Clang 21（2026）出的 libc++ 21 用了新 attribute 寫法（如 `__abi_tag__` on using-declarations）GCC 11 source 在某些 macro 處理上會撞。

**修法**：改用 **brew GCC 14** 當 host compiler。GCC 14 帶 **libstdc++ 14**（GNU 的、不是 LLVM 的），完全繞過 libc++ 體系。

```bash
brew install gcc@14
# 在 PATH 第一個放 wrapper 目錄，內含 gcc → /opt/homebrew/opt/gcc@14/bin/gcc-14
```

### `_FORTIFY_SOURCE` macro 的副作用

Apple SDK 開了 `_FORTIFY_SOURCE`，會把 `strlcpy` 偷偷改名成 `__builtin___strlcpy_chk`（多塞個 buffer size 參數做安全檢查）：

```c
// macOS string.h:
#define strlcpy(dst, src, len) \
    __builtin___strlcpy_chk((dst), (src), (len), __builtin_object_size((dst), 1))
```

這在 function call 沒事，但在 function declaration 會炸：
```c
size_t strlcpy(char *dst, const char *src, size_t siz);
// preprocessor 展開為:
size_t __builtin___strlcpy_chk(char *dst, const char *src, size_t siz,
                                __builtin_object_size((char *dst), 1));
//                              ↑ 第 4 個「參數」是 function call expression
//                              ↑ 不是「型別+名字」 → C 文法不接受
//                              → "expected parameter declarator" error
```

Linux kernel 2.6.32 的 `unifdef.c` line 84 寫了這種 declaration（因為 2009 年 glibc 沒 strlcpy）。Mac 上踩到 → 我們寫 patch 刪掉那行（讓它走 macOS 的 `<string.h>`）。

---

## Mechanism 5：vendor 欄位有意義嗎

Target tuple 結構：
```
x86_64-centos6-linux-gnu
  │      │      │    │
  arch   vendor  os  libc
  ↑      ↑      ↑    ↑
  關鍵    可有可無 關鍵 關鍵
```

`vendor` 欄 99% 是 cosmetic。GCC / autoconf / binutils 認真看的是 arch / os / libc。

### vendor 的實際影響

| 影響面 | centos6 vs unknown | 結果 |
|---|---|---|
| 產出 binary 的 ABI | x86_64 Linux ELF + glibc 2.12 | **完全一樣** |
| 部署相容性 | 跑得了就跑得了 | **完全一樣** |
| GCC 編譯行為 | 一樣 | **完全一樣** |
| Toolchain 二進制檔名 | `x86_64-centos6-linux-gnu-gcc` | **不同** |
| sysroot 路徑 | `~/x-tools/x86_64-centos6-linux-gnu/` | **不同** |
| `gcc -dumpmachine` | 字面 vendor 串 | **不同** |

### 為什麼還是寫 centos6

1. **跟 reference 對齊** — reference 的 toolchain 名為 `x86_64-centos6-linux-gnu-gcc`，整合到他們 build system 不用改字串
2. **自我說明** — 名字一看就知道「給 CentOS 6 用」
3. **保險** — 有些 autoconf project hardcode 4 段 tuple，omit vendor 會 break

GCC 認的「特殊 vendor」：`apple-darwin`（切 Mach-O 後端）、`pc-mingw32`（切 Windows PE）、`*-rtems`、`*-elf`、`*-eabi`。`centos6` 不在裡面 → GCC 完全當 unknown 處理 → ABI 不變。

---

## Mechanism 6：1.28 era 早期失敗 — 為什麼會 pivot 到 1.25

**先講前情**：最初設計是 ct-ng 1.28 + GCC 15 + glibc 2.12.2。理由：1.28 是 brew 上裝得到的最新版、GCC 15 對 C++23 支援最完整。一週後發現 1.28 根本不能 build glibc 2.12 → 整個方向砍掉重來。

這節記**1.28 那一週踩過的 5 個 mount / 編譯 / silent 錯誤**，每個都對應到後來 1.25 era 為什麼那樣設定。

### Pre-pivot Finding #A — `Your file system is *not* case-sensitive!`

**Error 訊息（verbatim）**：
```
[ERROR]  Your file system in '/Users/frank.liu/vms/shared/capsule8/tmp/ct-x86_64-glibc212' is *not* case-sensitive!
[ERROR]  Build failed in step '(top-level)'
[ERROR]  Error happened in: CT_Abort[scripts/functions@487]
[ERROR]        called from: CT_TestAndAbort[scripts/functions@507]
[ERROR]        called from: main[scripts/crosstool-NG.sh@67]
```

**觸發位置**：
- ct-ng step：開機 sanity check
- File：`scripts/crosstool-NG.sh:67` 內 `CT_TestAndAbort` 跑 touch / find 對比
- 機制：建 `.cscheck-A` 跟 `.cscheck-a` 兩個檔，find 有沒有兩個出現

**根因**：macOS APFS / HFS+ 預設 **case-insensitive**。`Makefile` 跟 `makefile` 在 macOS 上是同檔。Linux source（特別是 kernel 跟 glibc）有大量只差大小寫的檔（`Stack.c` vs `stack.c`、`Makefile` vs `makefile`），會撞名 → ct-ng 直接 abort。

**解法**：建 case-sensitive sparseimage 用 hdiutil：
```bash
hdiutil create -type SPARSE -size 30g -fs "Case-sensitive APFS" \
    -volname ct-build /path/to/ct-build
hdiutil attach /path/to/ct-build.sparseimage
# 掛在 /Volumes/ct-build/
```
然後把 ct-ng 的 work dir 跟 install prefix 都導向這個 mount point。**兩個都要 case-sensitive**，ct-ng 兩處都檢查。

後續經驗：APFS 在後面踩到 ncurses parallel race（見 Finding #B），改用 **`Case-sensitive Journaled HFS+`**（messense CI 也用 HFS+）。

**Reference**：
- ct-ng source `scripts/functions` 的 `CT_TestAndAbort` 跟 `CT_DoArchSetSysrootDir`：<https://github.com/crosstool-ng/crosstool-ng/blob/master/scripts/functions>
- Apple File System Reference (case-sensitivity per-volume)：<https://developer.apple.com/documentation/foundation/file_system/about_apple_file_system>
- `man 1 hdiutil`：<https://ss64.com/mac/hdiutil.html>

**承接到 1.25 era**：解這個 finding 留下 build script 的 sparseimage 自動建立邏輯。1.25 build 沿用同邏輯。我們現在用 HFS+ 不是 APFS（從 Finding #B 學到）。

---

### Pre-pivot Finding #B — ncurses `No rule to make target '../lib/libncurses.a'`

**Error 訊息（verbatim）**：
```
[ERROR]    make[2]: *** No rule to make target '../lib/libncurses.a', needed by 'all'.
[ERROR]    Build failed in step 'Installing ncurses for build'
```

**觸發位置**：
- ct-ng step：early step 2 `companion_libs_for_build` (在 cc_core 之前)
- File：`ncurses/ncurses/Makefile` 預期應該有 `../lib/libncurses.a` 的 rule，但實際沒有

**根因（speculative 階段）**：
我們花了好幾次 build 才找到真因。speculative 嘗試：

| Speculative 修法 | 推理 | 結果 |
|---|---|---|
| `CT_DEBUG_GDB=n`（disable GDB） | GDB TUI 用 ncurses，砍掉 GDB 應該不要 ncurses | fail（`gettext` 也透過 `GETTEXT_NEEDED` → `NCURSES_NEEDED` 拉 ncurses） |
| `CT_NCURSES_V_6_4=y` (pin 6.4 not 6.5) | 6.5 是 2024-04 release，6.4 是已驗證舊版 | fail（problem 不是 6.5 specific） |
| `CT_PARALLEL_JOBS=1`（force sequential） | error 提到 `make[2]`，看似 parallel race | fail（外層 `-j1` 還是有 inner Makefile 自己 parallel） |

3 個 speculative fix 各浪費 1 輪 build 時間。後來搜尋 GitHub issues #1788/#1810/#1926 都報同症狀，看 [messense/macos-cross-toolchains 的 .config](https://github.com/messense/homebrew-macos-cross-toolchains/blob/main/x86_64-unknown-linux-gnu/.config) 找到 **真因**：

`mk-1st.awk` 是 ncurses configure 用 awk 處理 template 生 Makefile rule（包括 libncurses.a 的 rule）。在我們的 broken build 裡 `mk-1st.awk` 輸出**只有 1 byte**（一個換行）。獨立跑同樣 awk command 卻產 200+ 行。bisect env：**`LANG`** 是分水嶺。

`LANG` unset 時 macOS gawk 5.4 某個 locale-aware code path 默默 fail → 空輸出 → ncurses Makefile 缺 rule。

`LANG` 為什麼會 unset？autoconf 生成的 ncurses configure 第 70 行有：
```sh
$as_unset LANG || test "${LANG+set}" != set || { LANG=C; export LANG; }
```
`$as_unset` (= `unset -v`) 成功 unset LANG，`||` short-circuit，LANG 永遠不會走到 `LANG=C` 的 fallback。

**解法**：patch ct-ng 內部 `scripts/build/companion_libs/220-ncurses.sh` 兩個動作：

```diff
     CT_DoLog EXTRA "Configuring ncurses"
+    # macOS workaround: ncurses' autoconf-generated configure unsets LANG
+    # at line 70 (`$as_unset LANG ...`). With LANG unset, gawk silently
+    # fails to produce mk-1st.awk's output, leaving libncurses.a build rule
+    # missing.
+    /opt/homebrew/opt/gnu-sed/bin/gsed -i \
+        -e 's|^\$as_unset LANG .*|LANG=C; export LANG|' \
+        -e 's|^\$as_unset LC_ALL .*|LC_ALL=C; export LC_ALL|' \
+        "${CT_SRC_DIR}/ncurses/configure"
     CT_DoExecLog CFG                                                    \
     CFLAGS="${cflags}"                                                  \
     LDFLAGS="${ldflags}"                                                \
+    LANG=C LC_ALL=C                                                     \
     ${CONFIG_SHELL}                                                     \
     "${CT_SRC_DIR}/ncurses/configure"                                   \
```

(a) 預先 sed 改 ncurses configure 的 `$as_unset LANG` 改成 `LANG=C; export LANG`
(b) configure 呼叫加上 `LANG=C LC_ALL=C`，雙保險

**Reference**：
- autoconf locale-normalization 樣板：<https://git.savannah.gnu.org/gitweb/?p=autoconf.git;a=blob;f=lib/autoconf/general.m4>
- gawk 5.4 source（`Locale support`）：<https://git.savannah.gnu.org/gitweb/?p=gawk.git;a=blob;f=re.c>
- ct-ng issue #1788 (binutils PATH ordering)：<https://github.com/crosstool-ng/crosstool-ng/issues/1788>
- 我們的修法檔在 `tmp/ct-ng-1.25/share/crosstool-ng/scripts/build/companion_libs/220-ncurses.sh`

**承接到 1.25 era**：1.25 build 也沿用同樣 patch（已 apply 到 ct-ng-1.25 安裝樹）。沒這 patch 1.25 ncurses 一樣會炸。

---

### Pre-pivot Finding #C — brew bash 5 + macOS 26 CoreFoundation fork-safety SIGSEGV

**Error 訊息（verbatim，從 ncurses config.log 抓）**：
```
configure:1181: PATH=".;."; conftest.sh
The process has forked and you cannot use this CoreFoundation functionality safely. You MUST exec().
configure:1184: $? = 139
```

**觸發位置**：
- ct-ng step：跑 ncurses (或其他 configure-heavy component) 的 autoconf 階段
- File：autoconf 生成的 `configure` 內 `( PATH=".;."; conftest.sh ) 2>&5` 這類 subshell pattern
- subshell 的 child process fork 之後沒立刻 exec()，使用 CoreFoundation framework function 觸發 macOS 26 安全 abort

**根因**：

```bash
$ otool -L /opt/homebrew/opt/bash/bin/bash | grep CoreFoundation
    /System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation
                                          ↑ brew bash 5 連向 CoreFoundation

$ otool -L /bin/bash | grep CoreFoundation
                                          ↑ 空，Apple bash 3.2 沒連 CF
```

macOS 26 (Tahoe) 加嚴 CoreFoundation fork-safety 檢查。brew bash 5 連向 CF → 它 fork 出 subshell 後、child 還沒 exec() 之前，如果 CF runtime 內部初始化做某些事 → SIGSEGV abort。

早期 macOS（messense CI 跑的 macOS 14/15）只 print warning 不 abort，這 issue 在 macOS 26 才浮現。

**Speculative attempt（沒解到）**：
- `export OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES` — 看似有道理（disable fork safety），實測還是 SIGSEGV。原因：這 env var 只 disable Objective-C `+initialize` fork safety，不 disable CoreFoundation 整體 fork-safety（Apple 沒給 env var 關 CF 整套）。

**真正解法**：強迫 ct-ng 用 Apple `/bin/bash` 3.2.57（沒 CF linkage）跑 autoconf subshell。但 ct-ng 的 `share/crosstool-ng/paths.sh` hardcode brew bash → 改不到（brew install 的檔，permission issue）。

**對 brew install 的 1.28 era 修法**：把整個 brew ct-ng install mirror 到 `tmp/ct-ng-local/`（local 可寫），patch local 的 `paths.sh`：
```diff
- export bash="/opt/homebrew/opt/bash/bin/bash"
+ export bash="/bin/bash"
```
然後 build script 內 wrapper function 強制呼叫 local copy：
```bash
ct-ng() { "${CT_NG_LOCAL}/ct-ng" "$@"; }
```

**Reference**：
- macOS CoreFoundation fork-safety 機制：（Apple 不公開官方文件，行為見 `OBJC_DISABLE_INITIALIZE_FORK_SAFETY` 環境變數源碼 + `man 3 fork`「fork is unsafe to call from any code that uses CoreFoundation」）
- 驗證 bash CF linkage：`otool -L /opt/homebrew/opt/bash/bin/bash | grep CoreFoundation`
- `OBJC_DISABLE_INITIALIZE_FORK_SAFETY` 不 cover CoreFoundation 的討論（Stack Overflow / Apple dev forums）

**承接到 1.25 era**：1.25 自己 build 出來、不靠 brew → 我們直接寫進 1.25 安裝後手動修改清單（附錄 E #1 跟 #2）。但 1.25 era 的解法**反過來**：

- ct-ng 自己的 script (`scripts/build/...`) 用 brew bash 5（要 `${var^^}` syntax）
- autoconf subshell 仍用 `/bin/bash` (避 CF fork-safety)
- 透過 `BASH=/bin/bash` 跟 `CONFIG_SHELL=/bin/bash` 兩個 env var 分流

「兩個 bash 並用」這個架構是從 1.28 era CF abort 學來的。

---

### Pre-pivot Finding #D — 1.28 build 完才發現 glibc 是 2.42 不是 2.12（pivot trigger）

**Error 訊息（verbatim 沒 explicit error）**：
build 完成（除了最後 cross-gdb step 失敗），但驗證 sysroot 看：
```
$ objdump -T /Volumes/ct-x86_64-glibc212/x-tools/.../sysroot/lib/libc.so.6 | grep -oE 'GLIBC_[0-9.]+' | sort -uV | tail
GLIBC_2.39
GLIBC_2.41
GLIBC_2.42                ← 預期 2.12，實際 2.42
```

回看 build.log：
```
[DEBUG]    CT_GLIBC_VERSION="2.42"
[DEBUG]    CT_GLIBC_VERSION=2.42
[DEBUG]    Already have '/Volumes/ct-x86_64-glibc212/build/.build/tarballs/glibc-2.42.tar.xz'
```

但我們 defconfig 寫的是 `CT_GLIBC_VERSION="2.12.2"`！

**觸發位置**：ct-ng 1.28 安裝樹 `share/crosstool-ng/packages/glibc/`：
```
$ ls /opt/homebrew/Cellar/crosstool-ng/1.28.0/share/crosstool-ng/packages/glibc/
2.17  2.19  2.23  2.24  ...  2.42
       (沒有 2.12)
```

**根因**：ct-ng 1.28 的 packages/glibc/ 沒有 2.12.x 子目錄。kconfig 自動從 packages/X/ 列表生 boolean choice，沒 2.12 就沒對應 boolean。我們 defconfig 寫 `CT_GLIBC_VERSION="2.12.2"` 是個 string，但 string 是從 boolean 推算出來的，沒對應 boolean → ct-ng 默默 fall-through 到最新版預設 (2.42)。

關鍵 commit [6d5227b](https://github.com/crosstool-ng/crosstool-ng/commit/6d5227b63b096b052dde8717822db259971db515)（2022-05-10）："glibc 2.12.1 was marked as obsolete. Now that the 1.25.0 release is out this version can be removed completely"。**1.25 是最後一個有 glibc 2.12 的 ct-ng 版本**。

**驗證 1.25 真的有**：
```
$ ls /tmp/ct-ng-src/.../packages/glibc/
2.12.1  2.17  2.19  2.23  ...  2.35
        ↑ 有！
```

**解法**：pivot 整個 setup：
1. 放棄 ct-ng 1.28 + GCC 15 路線
2. 改用 ct-ng 1.25.0（最後支援 glibc 2.12）
3. 配 GCC 11（reference 用的版本）
4. 重新做所有 macOS 26 patch（變成 Mechanism 7 的 11 個 fix）

**Reference**：
- glibc 2.12 移除 commit：<https://github.com/crosstool-ng/crosstool-ng/commit/6d5227b63b096b052dde8717822db259971db515>
- ct-ng 1.25.0 release：<https://github.com/crosstool-ng/crosstool-ng/releases/tag/crosstool-ng-1.25.0>
- ct-ng 1.25 package list：<https://github.com/crosstool-ng/crosstool-ng/tree/crosstool-ng-1.25.0/packages>
- ct-ng 1.26 package list（已沒 2.12）：<https://github.com/crosstool-ng/crosstool-ng/tree/crosstool-ng-1.26.0/packages/glibc>

**承接到 1.25 era**：這個 finding 是整個 pivot 的觸發點。Mechanism 7 Fix #1 是這個 finding 的「修法」。Fix #4 (boolean V_X_Y pin) 也是吸收這個教訓 — 我們改成在 defconfig 明寫 `CT_GLIBC_V_2_12_1=y`，避免被 fall-through 又坑。

---

### Pre-pivot Finding #E — reference 反向工程：發現 1.25 + GCC 11 才對齊

**Error 訊息**：沒 error，是 user 觀察：「reference binary 的 floor 是 GLIBC_2.3.2，比我們 build 出來的 binary 低（要 2.34+）→ 不能在 reference 部署環境跑」

**觸發位置**：driver pivot decision

**反向工程過程**：
1. 對 reference binary 跑 `objdump -T reference | grep -oE 'GLIBC_[0-9.]+' | sort -uV | tail` → max GLIBC_2.3.2
2. 對 Bitdefender SDK `libbdscan.so` 跑同樣指令 → max GLIBC_2.3
3. 推論：reference + BD SDK 都是「為最大可攜性」build 的舊機器友善 binary
4. 找 reference toolchain：在 reference 機器跑 `x86_64-centos6-linux-gnu-gcc -v` 看完整 configure：
```
gcc version 11.2.0 (crosstool-NG 1.25.0)
Configured with: ... --target=x86_64-centos6-linux-gnu --prefix=/root/x-tools/x86_64-centos6-linux-gnu --with-pkgversion='crosstool-NG 1.25.0' --enable-languages=c,c++ --disable-libquadmath --disable-libgomp --disable-libssp --disable-libsanitizer --enable-target-optspace --enable-lto ...
```

確認 reference 用：
- ct-ng 1.25.0
- GCC 11.2.0
- glibc 2.12.1（後查 sysroot 確認）
- target tuple `x86_64-centos6-linux-gnu`
- 一堆 `--disable-libX` 跟 `--enable-Y` flag

**解法**：把 reference 的 configure flag 抄成 defconfig（附錄 C 內每個 `CT_CC_GCC_LIBQUADMATH=n` 等都是這來的）。

**為什麼 vendor 是 `centos6`**：reference `gcc -v` 顯示 target tuple 內 vendor 段就是 `centos6`。雖然 GCC 行為跟 vendor 無關（見 Mechanism 5），但對齊 reference 的 tuple 字串可以避免「他們 build system grep `x86_64-centos6-linux-gnu-gcc` 字串時找不到我們」之類的整合問題。

**Reference**：
- 驗 binary glibc floor 的指令：`objdump -T <binary> | grep -oE 'GLIBC_[0-9.]+' | sort -uV | tail`
- Bitdefender SDK 路徑（reference 機器內）：`/path/to/bitdefender/libbdscan.so`
- reference `gcc -v` 完整輸出（手動抄錄到 `tmp/notes/reference-gcc-v.txt` 或 git 內某 reference 檔）

**承接到 1.25 era**：Mechanism 7 整個 11 fix 都是「為了讓 1.25 + GCC 11 + glibc 2.12 在 macOS 26 跑得起來」。每個 fix 的根本前提就是這個 pivot。

---

### Mechanism 6 總結：1.28 era 的 5 個 finding 教什麼

| Finding | 教訓 | 對 1.25 era 的影響 |
|---|---|---|
| #A case-sensitive FS | macOS 預設 FS 不適合 cross-build，要 sparseimage | build script sparseimage 自動建（HFS+） |
| #B ncurses gawk LANG | autoconf locale-normalization 跟 gawk 衝突 | 1.25 內部 ncurses script 同 patch、build script 全程 LANG=C |
| #C CF fork-safety | brew bash 5 + macOS 26 不能跑 autoconf subshell | 1.25 build script 「兩個 bash 並用」架構 |
| #D 1.28 沒 glibc 2.12 | defconfig string 不夠、要 boolean V_X_Y | 1.25 defconfig 用 boolean pin，pivot 觸發 |
| #E reference reverse-engineer | 對齊 reference configure flag 整套 | 1.25 defconfig 抄 reference 的 disable/enable list |

**1.28 era 浪費了 ~1 週**，原因主要是 Finding #B 那 3 個 speculative fix（每個 1-2 hr build time）跟 Finding #D 太晚發現（build 完才驗證）。教訓在 Mechanism 7 教訓區（搜 exact error string、每個修法要驗證、misread timestamp）。

---

## Mechanism 7：11 次失敗 + 1 個遺留 error 的詳解

每個 fix 都附 4 件事：**error 訊息 verbatim** / **觸發位置** / **解法** / **reference 來證明不是亂搞**。

### 總覽表

| # | Fail step | Error 一句話摘要 | 解法分類 |
|---|---|---|---|
| 1 | (build 完才知) | glibc 偷換 2.42 not 2.12 | ct-ng 1.28 → 1.25 |
| 2 | sanity check | `${var^^}: bad substitution` | bash 5 |
| 3 | retrieve tarballs | zlib 1.2.12 URL 404 | fossils archive |
| 4 | (build 中才知) | glibc 抓到 2.35 not 2.12 | boolean V_X_Y pin |
| 5 | zlib host build | `_stdio.h:322 expected identifier` | patch fdopen |
| 6 | gettext host build | `incompatible function pointer types` | CFLAGS demote |
| 7 | binutils host build | `'PTR' undeclared` | 移掉 brew binutils CPPFLAGS |
| 8 | kernel headers | `expected parameter declarator` | patch unifdef.c |
| 9 | stage-1 gcc | `'__abi_tag__' attribute only applies to ...` | brew gcc-14 host |
| 10 | sanity check | `Don't set CC. It screws up the build.` | wrapper symlink |
| 11 | sanity check (試編 test program) | `no option '-Wincompatible-function-pointer-types'` | 清空 cflags |
| 遺留 | glibc full build (但 build 沒掛) | `bits/stdio_lim.h: No such file or directory` | 不修（race，後面自然 OK） |

---

### Fix #1 — ct-ng 1.28 偷換 glibc 2.42 而非 2.12

**Error 訊息（verbatim）**：build 完成不報錯，但驗證 sysroot libc.so.6：
```
$ objdump -T sysroot/lib/libc.so.6 | grep -oE 'GLIBC_[0-9.]+' | sort -uV | tail
GLIBC_2.39
GLIBC_2.41
GLIBC_2.42         ← 預期 2.12，實際 2.42
```
build.log 的 debug 行印：
```
[DEBUG]    CT_GLIBC_VERSION="2.42"
[DEBUG]    CT_GLIBC_VERSION=2.42
```

**觸發位置**：ct-ng 1.28 的 kconfig 解析。defconfig 寫 `CT_GLIBC_VERSION="2.12.2"` 但 ct-ng 1.28 的 `packages/glibc/` 沒有 2.12.x 子目錄 → kconfig 看不到對應 boolean choice → `CT_GLIBC_VERSION` string 被靜默 fall-through 到 default（最新版 2.42）。

**根因**：ct-ng commit [6d5227b](https://github.com/crosstool-ng/crosstool-ng/commit/6d5227b63b096b052dde8717822db259971db515)（2022-05-10）將 glibc 2.12.1 標 obsolete 並完全移除。1.26 起就沒 2.12。**1.25 是最後一個有 2.12 的版本**。

**解法**：pivot 到 ct-ng 1.25.0（[release tarball](https://github.com/crosstool-ng/crosstool-ng/releases/tag/crosstool-ng-1.25.0)），它 ships glibc 2.12.1。

**Reference**：
- ct-ng 1.25 packages/glibc：<https://github.com/crosstool-ng/crosstool-ng/tree/crosstool-ng-1.25.0/packages/glibc>
- 1.26 同目錄（沒 2.12）：<https://github.com/crosstool-ng/crosstool-ng/tree/crosstool-ng-1.26.0/packages/glibc>
- glibc 移除 commit：<https://github.com/crosstool-ng/crosstool-ng/commit/6d5227b63b096b052dde8717822db259971db515>

---

### Fix #2 — bash `${var^^}: bad substitution`

**Error 訊息（verbatim）**：
```
/Users/frank.liu/vms/shared/capsule8/tmp/ct-ng-1.25/share/crosstool-ng/scripts/build/companion_tools.sh: line 8: CT_COMP_TOOLS_${_f^^}: bad substitution
/Users/frank.liu/vms/shared/capsule8/tmp/ct-ng-1.25/share/crosstool-ng/scripts/build/debug.sh: line 8: CT_DEBUG_${_f^^}: bad substitution
/Users/frank.liu/vms/shared/capsule8/tmp/ct-ng-1.25/share/crosstool-ng/scripts/functions: line 2062: local ${v}=\${CT_${sym}_${v^^}}: bad substitution
```

**觸發位置**：
- ct-ng step：sanity check + 早期 step 1 (companion_tools_for_build) 進行中
- File：`scripts/build/companion_tools.sh:8`、`scripts/build/debug.sh:8`、`scripts/functions:2062` 等
- ct-ng 自己 source code 用了 `${var^^}` (bash 4+ uppercase parameter expansion)

**根因**：macOS `/bin/bash` 是 **3.2.57(1)-release** (Apple 因 GPLv3 license 不升級到 bash 4+)。ct-ng 1.25 的 build Makefile 跟 paths.sh hardcode `bash=/bin/bash`，會把 ct-ng 自己的 script 用 3.2 跑 → `^^` syntax 不認得。

**解法**：把 ct-ng 1.25 安裝後的兩個地方改指向 brew bash 5：
```bash
# tmp/ct-ng-1.25/bin/ct-ng (Makefile 形式) :
- export bash         = /bin/bash
+ export bash         = /opt/homebrew/opt/bash/bin/bash

# tmp/ct-ng-1.25/share/crosstool-ng/paths.sh :
- export bash="/bin/bash"
+ export bash="/opt/homebrew/opt/bash/bin/bash"
```
（autoconf subshell 仍用 `/bin/bash` via `CONFIG_SHELL` 避開 macOS 26 CoreFoundation fork-safety abort —兩個 bash 分流。）

**Reference**：
- bash 4 release notes (`^^` 加入)：<https://www.gnu.org/software/bash/manual/html_node/Shell-Parameter-Expansion.html>
- macOS bash 3.2 history (GPLv3 issue)：<https://news.ycombinator.com/item?id=8842136>
- 我們 build script 內 PATH 編排（讓 brew bash 在 invoke ct-ng Makefile 時被 SHELL 用到）：`toolchain/scripts/build.sh`

---

### Fix #3 — zlib 1.2.12 download URL 404

**Error 訊息（verbatim）**：
```
[EXTRA]    Retrieving 'zlib-1.2.12'
[DEBUG]    Trying 'http://downloads.sourceforge.net/project/libpng/zlib/1.2.12/zlib-1.2.12.tar.xz'
[ALL  ]    HTTP request sent, awaiting response... 404 Not Found
[DEBUG]    Trying 'https://www.zlib.net//zlib-1.2.12.tar.xz'
[ALL  ]    HTTP request sent, awaiting response... 404 Not Found
[DEBUG]    Trying 'http://downloads.sourceforge.net/project/libpng/zlib/1.2.12/zlib-1.2.12.tar.gz'
[ALL  ]    HTTP request sent, awaiting response... 404 Not Found
[DEBUG]    Trying 'https://www.zlib.net//zlib-1.2.12.tar.gz'
[ALL  ]    HTTP request sent, awaiting response... 404 Not Found
[ERROR]    zlib: download failed
```

**觸發位置**：
- ct-ng step：`Retrieving needed toolchain components' tarballs`（即 `do_companion_libs_get` → `do_zlib_get`）
- 觸發檔：`scripts/build/companion_libs/050-zlib.sh:16` 內 `CT_Fetch ZLIB`
- URL 來自 `packages/zlib/package.desc` 的 `mirrors=` 欄位

**根因**：zlib 1.2.12（2022-03 釋出）有 [CVE-2022-37434](https://nvd.nist.gov/vuln/detail/CVE-2022-37434) 安全漏洞、上游撤掉。zlib.net 跟 sourceforge 都不再 host 這版（只有 1.2.13+）。但 ct-ng 1.25 ships 1.2.12 是它唯一支援的 zlib 版。

**解法**：把 zlib 1.2.12 的 mirror 指向 zlib 自家的 fossils 歷史 archive：
```diff
# tmp/ct-ng-1.25/share/crosstool-ng/packages/zlib/package.desc :
- mirrors='http://downloads.sourceforge.net/project/libpng/zlib/${CT_ZLIB_VERSION} https://www.zlib.net/'
+ mirrors='https://www.zlib.net/fossils https://www.zlib.net/'

# tmp/ct-ng-1.25/share/crosstool-ng/config/versions/zlib.in :
- default "http://downloads.sourceforge.net/project/libpng/zlib/${CT_ZLIB_VERSION} https://www.zlib.net/"
+ default "https://www.zlib.net/fossils https://www.zlib.net/"
```

**Reference**：
- CVE-2022-37434：<https://nvd.nist.gov/vuln/detail/CVE-2022-37434>
- zlib fossils archive 列表：<https://www.zlib.net/fossils/>
- 驗證：`curl -sI https://www.zlib.net/fossils/zlib-1.2.12.tar.gz` → 200 OK

---

### Fix #4 — glibc / linux 版本 pin 沒被 honored（fall-through 到 2.35 / 5.16）

**Error 訊息（verbatim）**：build.log debug 行 + retrieve 訊息：
```
[EXTRA]    Retrieving 'linux-5.16.9'
[EXTRA]    Retrieving 'glibc-2.35'
```
而我們 defconfig 寫的是：
```
CT_GLIBC_VERSION="2.12.1"
CT_LINUX_VERSION="2.6.32.71"
```
產生的 `.config` 內容卻是：
```
CT_LINUX_V_5_16=y                ← fall-through 到最新
CT_LINUX_VERSION="5.16.9"
CT_GLIBC_V_2_35=y                ← fall-through 到最新
CT_GLIBC_VERSION="2.35"
# CT_GLIBC_V_2_12_1 is not set
```

**觸發位置**：ct-ng `defconfig` 跑時的 kconfig parser。

**根因**：ct-ng 的 kconfig 把 version 當成「choice + boolean」結構。`CT_GLIBC_VERSION="X"` 這個 string variable 是**從 boolean 推導出來**的（在 `config/versions/glibc.in`），不是 input。defconfig 該設的是 boolean `CT_GLIBC_V_2_12_1=y`。

跟 GCC 不一樣的是：GCC 有兩層 boolean (`CT_GCC_V_11=y`)，配 string `CT_GCC_VERSION="11.2.0"` 兩個都寫對才會生效。glibc / linux 沒這層、只有單一版本 boolean。

**解法**：defconfig 加上明確 boolean：
```diff
+ CT_LINUX_V_2_6_32=y
  CT_LINUX_VERSION="2.6.32.71"

+ CT_GLIBC_V_2_12_1=y
  CT_GLIBC_VERSION="2.12.1"
```

**Reference**：
- ct-ng kconfig template：[`maintainer/kconfig-versions.template`](https://github.com/crosstool-ng/crosstool-ng/blob/crosstool-ng-1.25.0/maintainer/kconfig-versions.template)
- Generated `config/versions/glibc.in`（display this file 看 `choice "Version of glibc"` 區塊）
- Linux Kconfig "choice" 語意：<https://www.kernel.org/doc/html/latest/kbuild/kconfig-language.html#choices>

---

### Fix #5 — zlib `_stdio.h:322 expected identifier` (fdopen 撞 macOS)

**Error 訊息（verbatim）**：
```
In file included from /Volumes/.../src/zlib/zutil.c:10:
In file included from /Volumes/.../src/zlib/gzguts.h:21:
In file included from /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/include/stdio.h:61:
/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/include/_stdio.h:322:7: error: expected identifier or '('
  322 | FILE    *fdopen(int, const char *) __DARWIN_ALIAS_STARTING(__MAC_10_6, __IPHONE_2_0, __DARWIN_ALIAS(fdopen));

/Volumes/.../src/zlib/zutil.h:147:33: note: expanded from macro 'fdopen'
  147 | #        define fdopen(fd,mode) NULL /* No fdopen() */
```

**觸發位置**：
- ct-ng step：step 5 `companion_libs_for_host` → `do_zlib_for_host`
- File：`zlib-1.2.12/zutil.h:147` 定義 macro，被 `gzguts.h` 透過 `<stdio.h>` 引入時撞名
- Error 是 Apple Clang 21 處理 `_stdio.h:322` 時報的（被 zlib 的 macro 把 `fdopen` 改成 `NULL`）

**根因**：zlib 1.2.12 zutil.h 內 Mac OS Classic 殘留 code：
```c
#if defined(MACOS) || defined(TARGET_OS_MAC)
#  define OS_CODE  7
#  ifndef Z_SOLO
#    if defined(__MWERKS__) && __dest_os != __be_os && __dest_os != __win32_os
#      include <unix.h> /* for fdopen */
#    else
#      ifndef fdopen
#        define fdopen(fd,mode) NULL /* No fdopen() */    ← 這行
#      endif
#    endif
#  endif
#endif
```
`TARGET_OS_MAC` 在現代 macOS 是 1（`<TargetConditionals.h>` 定義）→ activate Mac OS Classic 路徑 → 把 `fdopen` define 成 `NULL`。但現代 macOS `<stdio.h>` 有 `fdopen` declaration → 被 zlib macro 改成 `FILE *NULL(...)` → C 語法錯誤。

**解法**：寫 patch 移除那行 define（讓 zlib 用 macOS `<string.h>` 提供的 `fdopen`）：
```
# tmp/ct-ng-1.25/share/crosstool-ng/packages/zlib/1.2.12/0002-fix-fdopen-macos.patch :
@@ -144,9 +144,7 @@
 #    if defined(__MWERKS__) && __dest_os != __be_os && __dest_os != __win32_os
 #      include <unix.h> /* for fdopen */
 #    else
-#      ifndef fdopen
-#        define fdopen(fd,mode) NULL /* No fdopen() */
-#      endif
+       /* fdopen is provided by Apple stdio.h on modern macOS */
 #    endif
```

**Reference**：
- `TARGET_OS_MAC` macro 定義：Apple `<TargetConditionals.h>`（Xcode CLT 內）
- zlib upstream 1.2.13 修法（更全面）：<https://github.com/madler/zlib/commit/eff308af425b67093bab25f80f1ae950166bece1>
- zlib 1.2.12 source `zutil.h:141-152`：`tmp/ct-ng-src/release-extract/crosstool-ng-1.25.0/packages/zlib/...`（在我們 ct-ng 1.25 unpack 過的 source 樹內）

---

### Fix #6 — gettext `obstack.c` 撞 Apple Clang 21 strict mode

**Error 訊息（verbatim）**：
```
/Volumes/.../src/gettext/libtextstyle/lib/obstack.c:351:31: error: incompatible function pointer types initializing 'void (*)(void) __attribute__((noreturn))' with an expression of type 'void (void)' [-Wincompatible-function-pointer-types]
```

**觸發位置**：
- ct-ng step：step 5 `companion_libs_for_host` → `do_gettext_for_host`
- File：`gettext-0.21/libtextstyle/lib/obstack.c:351`，code 為：
```c
__attribute_noreturn__ void (*obstack_alloc_failed_handler) (void)
  = print_and_abort;
```
- Error reporter：Apple Clang 21（用作 host C compiler）

**根因**：Apple Clang 16+ 把 `-Wincompatible-function-pointer-types` 預設升 error。`obstack.c` 把帶 `noreturn` attribute 的 function pointer 賦值為「沒 noreturn 的 print_and_abort」（雖然 print_and_abort 本身有 noreturn，但 attribute 不傳遞到 function pointer 賦值）→ Clang 16+ 認為 incompatible。

**解法**：defconfig 內加 host CFLAGS demote：
```
CT_EXTRA_CFLAGS_FOR_HOST="-Wno-error=incompatible-function-pointer-types -Wno-incompatible-function-pointer-types -Wno-error=implicit-function-declaration -Wno-error=int-conversion"
```
（這 fix 後來在 #11 因換 GCC 14 而清空，因為 GCC 不認得 clang flag）

**Reference**：
- Apple Clang 16 release notes：<https://developer.apple.com/documentation/xcode-release-notes/xcode-16-release-notes>
- Clang 16 release notes (`-Wincompatible-function-pointer-types` 預設升 error)：<https://releases.llvm.org/16.0.0/tools/clang/docs/ReleaseNotes.html>
- Clang warning options：<https://clang.llvm.org/docs/DiagnosticsReference.html#wincompatible-function-pointer-types>

---

### Fix #7 — binutils libiberty `'PTR' undeclared`

**Error 訊息（verbatim）**：
```
/Volumes/.../src/binutils/libiberty/objalloc.c:95:18: error: use of undeclared identifier 'PTR'
/Volumes/.../src/binutils/libiberty/objalloc.c:114:1: error: unknown type name 'PTR'
/Volumes/.../src/binutils/libiberty/objalloc.c:135:15: error: use of undeclared identifier 'PTR'
... (10+ similar errors)
make[1]: *** [Makefile:1029: all] Error 2
```

**觸發位置**：
- ct-ng step：step 6 `binutils_for_host` → `do_binutils_for_host`
- File：`binutils-2.38/libiberty/objalloc.c:95+`，例如：
```c
ret->chunks = (PTR) malloc (CHUNK_SIZE);
```
- 應該由 `binutils-2.38/include/ansidecl.h:73` 的 `#define PTR void *` 提供，但被 brew binutils 2.46 的 ansidecl.h shadow

**根因**：build script CPPFLAGS 加了 `-I/opt/homebrew/opt/binutils/include` (per ct-ng OS-setup 老建議)。brew binutils 2.46 的 `ansidecl.h` 已經[移除 `PTR` macro 定義](https://sourceware.org/git/?p=binutils-gdb.git)（modern cleanup），於是 binutils 2.38 source 編譯時找到的是 brew 2.46 那份不含 PTR 的 ansidecl.h。

**解法**：build script 移掉那個 CPPFLAGS：
```diff
# toolchain/scripts/build.sh :
- export LDFLAGS="-L${BREW_PREFIX}/opt/binutils/lib -L${BREW_PREFIX}/opt/bison/lib -L${BREW_PREFIX}/opt/ncurses/lib"
- export CPPFLAGS="-I${BREW_PREFIX}/opt/binutils/include -I${BREW_PREFIX}/opt/ncurses/include"
+ export LDFLAGS="-L${BREW_PREFIX}/opt/bison/lib -L${BREW_PREFIX}/opt/ncurses/lib"
+ export CPPFLAGS="-I${BREW_PREFIX}/opt/ncurses/include"
```

**Reference**：
- binutils 2.38 ansidecl.h `#define PTR void *`（gitweb tag `binutils-2_38`）：<https://sourceware.org/git/?p=binutils-gdb.git;a=blob;f=include/ansidecl.h;hb=binutils-2_38>
- binutils 2.46 ansidecl.h（PTR 已移除）：<https://sourceware.org/git/?p=binutils-gdb.git;a=blob;f=include/ansidecl.h;hb=binutils-2_46>
- ct-ng issue #1788 PATH ordering / brew binutils 互動討論：<https://github.com/crosstool-ng/crosstool-ng/issues/1788>

---

### Fix #8 — Linux kernel `unifdef.c` `expected parameter declarator`

**Error 訊息（verbatim）**：
```
/Volumes/.../src/linux-2.6.32.71/scripts/unifdef.c:75:8: error: expected parameter declarator
/Volumes/.../src/linux-2.6.32.71/scripts/unifdef.c:75:8: error: expected ')'
/Volumes/.../src/linux-2.6.32.71/scripts/unifdef.c:75:8: error: type specifier missing, defaults to 'int'; ISO C99 and later do not support implicit int [-Wimplicit-int]
/Volumes/.../src/linux-2.6.32.71/scripts/unifdef.c:75:8: error: conflicting types for '__builtin___strlcpy_chk'
4 errors generated.
make[3]: *** [scripts/Makefile.host:118: scripts/unifdef] Error 1
```

**觸發位置**：
- ct-ng step：step 8 `kernel_headers` → `do_kernel_headers`
- File：`linux-2.6.32.71/scripts/unifdef.c:84`：
```c
size_t strlcpy(char *dst, const char *src, size_t siz);
```
- 注意：Linux source 上是 line 84，error 報 line 75 是因為 macro 展開後位置偏移

**根因**：見 Mechanism 4 的 `_FORTIFY_SOURCE` 細解。簡單說：
1. macOS `<string.h>` 有 macro：`#define strlcpy(d,s,l) __builtin___strlcpy_chk(d,s,l, __builtin_object_size(d, 1))`
2. unifdef.c `#include <string.h>` 之後又自己宣告 `size_t strlcpy(...)`
3. 自己那行被 macro 展開成 `size_t __builtin___strlcpy_chk(char *dst, ..., __builtin_object_size((char *dst), 1))`
4. 第 4 個「參數」是 function call expression，C 語法不接受在 declaration 位置

unifdef.c 寫這行的原因：2009 年 glibc 沒 `strlcpy`，自己宣告才有 prototype。

**解法**：寫 patch 移除這行（macOS string.h 已提供）：
```
# tmp/ct-ng-1.25/share/crosstool-ng/packages/linux/2.6.32.71/0001-fix-unifdef-strlcpy-macos.patch :
--- a/scripts/unifdef.c
+++ b/scripts/unifdef.c
@@ -81,8 +81,6 @@
 #include <string.h>
 #include <unistd.h>

-size_t strlcpy(char *dst, const char *src, size_t siz);
-
 /* types of input lines: */
 typedef enum {
```

**Reference**：
- Linux 2.6.32 `unifdef.c`：<https://elixir.bootlin.com/linux/v2.6.32.71/source/scripts/unifdef.c>
- macOS `_FORTIFY_SOURCE` 對 strlcpy 的 macro：`/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/include/secure/_string.h`
- glibc 2.38 終於加 strlcpy 的 commit：<https://sourceware.org/git/?p=glibc.git;a=commit;h=454a20c8756c9c1d055cd7e8b1fc1631bf26ea27>
- Linux 3.x 後 in-tree unifdef 移除、改用 system unifdef：<https://lore.kernel.org/lkml/1395423091-3506-1-git-send-email-mmarek@suse.cz/>

---

### Fix #9 — stage-1 GCC 撞 Apple libc++ 21 (`__abi_tag__`)

**Error 訊息（verbatim）**：
```
/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/include/c++/v1/__locale:477:3: error: '__abi_tag__' attribute only applies to structs, variables, functions, and namespaces
/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/include/c++/v1/__locale:477:57: error: expected ';' at end of declaration list
/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/include/c++/v1/__locale:479:68: error: too many arguments provided to function-like macro invocation
... (60+ similar errors)
fatal error: too many errors emitted, stopping now [-ferror-limit=]
```

**觸發位置**：
- ct-ng step：step 7 `cc_core` (stage-1 GCC) → `do_cc_core`
- File：Apple Clang 21 編 GCC 11 source 時，host header `c++/v1/__locale:477+` 出錯
- GCC 11 source `gcc/system.h` 之類某個地方拉進 libc++ header

**根因**：Apple Clang 21 ships with **libc++ 21**（LLVM C++ stdlib）。libc++ 21 用了 GCC 11 source 沒料到的 attribute syntax (`__abi_tag__` on using-declarations)。GCC 11 是 2021 年釋出，當時 libc++ 還在版本 12-14 一帶，5 年後的 libc++ 21 加的 C++ 特性 GCC 11 source 內部某些 macro pattern 處理不了。

**解法**：改用 brew GCC 14 當 host compiler（GCC 自帶 libstdc++ 14，根本不用 libc++）：
```bash
brew install gcc@14
```

**這個解法跟 Fix #10 配套，要解釋為什麼不能直接設 `CC=...`，要走 wrapper symlink 路線：**

`brew install gcc@14` 之後 binary 名是 `gcc-14`、`g++-14`（強制版本後綴，避免跟 Apple Clang `/usr/bin/gcc` 撞名）：
```bash
$ ls /opt/homebrew/opt/gcc@14/bin/
gcc-14   g++-14   cpp-14   gcov-14   ...
```

但 `autoconf`、ct-ng、glibc 等 build system **找的都是「`gcc`」「`g++`」這種沒後綴的字串**。如果 PATH 內沒人提供這名字，autoconf 找到的是 `/usr/bin/gcc`（Apple Clang alias）→ 又用回 Apple Clang。

最直接的辦法是 `export CC=/opt/homebrew/opt/gcc@14/bin/gcc-14`，但這條路 ct-ng 自己擋掉了（見 Fix #10）：
```
[ERROR]  Don't set CC. It screws up the build.
```
ct-ng 會分階段改 CC（cc_core / cc_for_build / cc_for_host 各自不同），user 設 env 會干擾它的內部邏輯。

→ 唯一可行：**用 wrapper symlink 假裝 gcc-14 是 gcc**，放 PATH 第一個。

```bash
GCC14_PREFIX="${BREW_PREFIX}/opt/gcc@14"
WRAPPERS="${REPO_ROOT}/tmp/gcc14-wrappers"
mkdir -p "${WRAPPERS}"
ln -sf "${GCC14_PREFIX}/bin/gcc-14" "${WRAPPERS}/gcc"
ln -sf "${GCC14_PREFIX}/bin/g++-14" "${WRAPPERS}/g++"
ln -sf "${GCC14_PREFIX}/bin/gcc-14" "${WRAPPERS}/cc"
ln -sf "${GCC14_PREFIX}/bin/g++-14" "${WRAPPERS}/c++"
export PATH="${WRAPPERS}:${PATH}"   # WRAPPERS 在最前面才能蓋過 /usr/bin/gcc (Apple Clang)
```

幾個設計細節：

| 為什麼這樣？ | 不這樣會怎樣？ |
|---|---|
| 只 wrap `gcc` `g++` `cc` `c++` 4 個 entry point | `ar`/`nm`/`as`/`ld` 等用 Apple `/usr/bin/` 即可，這些跟 libc++ 沒關 |
| 放 `tmp/gcc14-wrappers/`（local 目錄）而非 `/usr/local/bin/` | 不污染 user 平常 shell，下次手動 invoke `gcc` 還是 Apple Clang，做 native Mac binary 不會被 brew gcc 編 |
| PATH 放最前 | 不夠前的話 `/usr/bin/gcc`（Apple Clang）先被找到 → 修法失效 |
| 用 symlink 不用 shell wrapper script | symlink 透明（autoconf 看 readlink 認得是 gcc-14），shell script 會被 autoconf 偵測為「不是真 gcc」 |
| build script 內 export PATH，跳出 script 自動失效 | 避免 user shell 被永久污染 |

**Reference**：
- GCC bug #111632 (gcc fails to bootstrap when using libc++)：<https://gcc.gnu.org/bugzilla/show_bug.cgi?id=111632>
- GCC 官方 build 文件（討論 bootstrap 流程）：<https://gcc.gnu.org/install/build.html>（"with the same major version" 一句為社群慣例 / 我們經驗，GCC 文件本身只描述 3-stage bootstrap 流程而沒明示版本要求）
- libc++ 21 release notes：<https://libcxx.llvm.org/ReleaseNotes/21.html>

---

### Fix #10 — ct-ng 拒絕 `CC` env var

**Error 訊息（verbatim）**：
```
[INFO ]  Performing some trivial sanity checks
[ERROR]  Don't set CC. It screws up the build.
[ERROR]  >>
[ERROR]  >>  Build failed in step '(top-level)'
[ERROR]  >>  Error happened in: CT_Abort[scripts/functions@487]
[ERROR]  >>        called from: CT_TestAndAbort[scripts/functions@507]
[ERROR]  >>        called from: main[scripts/crosstool-NG.sh@67]
```

**觸發位置**：
- ct-ng step：開機 sanity check
- File：`scripts/crosstool-NG.sh:67`，code：
```bash
CT_TestAndAbort "Don't set CC. It screws up the build." -n "${CC+set}"
```

**根因**：ct-ng 內部會為每個 build 階段（cc_core/cc_for_build/cc_for_host）分別決定 CC，user 設 env 會干擾這個邏輯，所以 ct-ng 直接 abort 拒絕。

**解法**：放棄用 `CC=` env var。改用 PATH manipulation：在 PATH 第一個位置放 wrapper symlinks，讓 ct-ng autoconf 找 `gcc` 時找到我們的 gcc-14（透過 wrapper 指向）。

**Reference**：
- ct-ng `crosstool-NG.sh:67`：<https://github.com/crosstool-ng/crosstool-ng/blob/crosstool-ng-1.25.0/scripts/crosstool-NG.sh#L65-L70>
- 同檔對應的 CFLAGS / CXX 限制（line 65, 66, 68）

---

### Fix #11 — GCC 14 不認得 Clang-only flag

**Error 訊息（verbatim）**：
```
cc1: error: '-Wno-error=incompatible-function-pointer-types': no option '-Wincompatible-function-pointer-types'; did you mean '-Wincompatible-pointer-types'?
cc1: error: '-Wno-error=incompatible-function-pointer-types': no option '-Wincompatible-function-pointer-types'; did you mean '-Wincompatible-pointer-types'?
[ERROR]  >>  Build failed in step 'Checking that gcc can compile a trivial program'
```

**觸發位置**：
- ct-ng step：sanity check 內 "Checking that gcc can compile a trivial program"
- File：ct-ng 編一個試 hello.c 試新 host compiler，cflags 帶上 defconfig 的 `CT_EXTRA_CFLAGS_FOR_BUILD`
- error reporter：GCC 14 cc1（從 #9 修法切換來的 host compiler）

**根因**：`-Wincompatible-function-pointer-types` 是 Clang 專用 flag，GCC 沒這 option（GCC 等價是 `-Wincompatible-pointer-types`，broader）。Fix #6 加進 defconfig 是為 Apple Clang 21；Fix #9 切到 GCC 14 之後這 flag 就成毒。

**解法**：清空 defconfig 內 cflags（GCC 14 預設不把那些升 error，本來就不需要）：
```diff
# toolchain/configs/x86_64-centos6-glibc212.defconfig :
- CT_EXTRA_CFLAGS_FOR_HOST="-Wno-error=incompatible-function-pointer-types ..."
- CT_EXTRA_CFLAGS_FOR_BUILD="-Wno-error=incompatible-function-pointer-types ..."
+ CT_EXTRA_CFLAGS_FOR_HOST=""
+ CT_EXTRA_CFLAGS_FOR_BUILD=""
```

**Reference**：
- GCC warning options 列表：<https://gcc.gnu.org/onlinedocs/gcc/Warning-Options.html>
- Clang warning options：<https://clang.llvm.org/docs/DiagnosticsReference.html>
- 對照表 (GCC ↔ Clang flag mapping)：<https://gcc.gnu.org/wiki/ClangDiagnosticCompatibility>

---

### 遺留 error — 成功 build 仍報 1 個非致命 error

**Error 訊息（verbatim）**：
```
In file included from include/limits.h:153,
                 from nptl/sysdeps/pthread/allocalim.h:21,
                 from include/alloca.h:20,
                 from ./stdlib/stdlib.h:497,
                 from include/stdlib.h:8,
                 from nptl/sysdeps/x86_64/tls.h:28,
                 from include/tls.h:6,
                 from tls.make.c:3:
include/bits/xopen_lim.h:34:10: fatal error: bits/stdio_lim.h: No such file or directory
   34 | #include <bits/stdio_lim.h>
      |          ^~~~~~~~~~~~~~~~~~
compilation terminated.
sed: can't read /Volumes/.../build/build-libc/multilib/tls.make.dT: No such file or directory
mv -f /Volumes/.../build/build-libc/multilib/tls.makeT /Volumes/.../build/build-libc/multilib/tls.make
```

**觸發位置**：
- ct-ng step：step 11 `libc` (full glibc build)
- File：glibc 內部 Makefile rule 為了生成 `tls.make` (Makefile 依賴 metadata) 跑 `gcc -E ... tls.make.c`，preprocessing 中 `xopen_lim.h:34` 試圖 include `bits/stdio_lim.h`
- Trigger：tls.make 是 glibc 早期 dependency 推算階段；那時 stdio_lim.h 尚未生成

**根因**：`bits/stdio_lim.h` 是 glibc 從 `bits/stdio_lim.h.in` template 用 awk 處理動態生成的（不在 source tarball 內）。生成 stdio_lim.h 跟計算 tls.make 是 glibc Makefile 內兩個獨立 rule、順序不保證。tls.make 計算先跑 → stdio_lim.h 還沒生 → preprocessing fatal error。

**為什麼非致命**：
1. `tls.make` 只是 Makefile 的 dependency metadata（決定 incremental rebuild），不是實際 code
2. 上面 log 看到下一行 `mv -f .../tls.makeT .../tls.make` 不檢查 exit code → 即使 makeT 是空 / 部分內容，照樣 mv
3. glibc Makefile 沒 `set -e` 強制終止
4. 後面真的需要 `stdio_lim.h` 的 step（編 glibc .c source）時，stdio_lim.h 已生成 → 沒事
5. 整體 `make all` 完成、`make install` 安裝完整 glibc

**解法**：**不修**。這是 glibc 2.12 自己 Makefile dependency graph 的 race，已知非致命，整個 build 完成就 OK。我們 sysroot 內 `bits/stdio_lim.h` 已存在、用 user code `#include <stdio.h>` 不會踩到（user code 不會走 tls.make 那條路徑）。

**Reference**：
- glibc 2.12 Makerules（生成 stdio_lim.h 的 rule）：<https://sourceware.org/git/?p=glibc.git;a=blob;f=Makerules;hb=glibc-2.12.1>
- glibc tls.make 生成邏輯：在 glibc source `Makefile` 內搜 "tls.make"
- 類似 race 在新版 glibc 改善（2.30+ 用 build-many-glibcs.py 重整 dep graph）

---

### 修法物件分類速查

```
defconfig 改:                     #1 (ct-ng 版本), #4 (boolean V_X_Y), #5 patch dir, 
                                  #6/#11 (cflags), #8 patch dir
build script 改:                  #2 (bash 5), #7 (CPPFLAGS), #9 (gcc-14 wrappers), #10 (wrapper)
ct-ng 內部 paths.sh 改:           #2 (bash)
ct-ng 內部 source patch:          #5 (zlib 0002), #8 (linux 0001)
ct-ng 內部 kconfig + package.desc: #3 (zlib mirror)
不修:                             遺留 (glibc 自身 race, 非致命)
```

11 個都不是 ct-ng bug、也不是 macOS bug — 是「ct-ng 設計時沒料到 macOS 26」+「macOS 26 SDK 比過去更嚴」的相互作用。

### 教訓

1. **官方文件先讀完再 speculate** — ct-ng OS-setup page[^20] + messense[^11] CI workflow 答了 50% 問題。
2. **fail 訊息搜 exact 字串** — 「Don't set CC. It screws up the build」直接搜，找 ct-ng issues / source code，5 分鐘解決。
3. **每個修法要有經驗驗證** — 「這修法應該 work」沒用，要驗下次 fail 訊息有沒有變。我浪費過幾小時設 `OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES` 但其實它沒解 CoreFoundation fork-safety 問題（不同框架）。
4. **misread timestamps** — ct-ng log 的 `[02:30]` 是 `[MM:SS]` 不是 `[HH:MM]`。我一開始把 3 分鐘的 build 誤讀成 2.5 小時，浪費好幾天的判斷力。

---

## 業界 context：50 個 production project 的 toolchain pattern

| Pattern | 採用數 | 範例 |
|---|---|---|
| **Docker custom builder image** | ~14 | Cilium, Tracee, Falco, Beats, Rust toolchain, uv, Loki, ClickHouse |
| **GH Actions matrix native (CGO=0 Go)** | ~13 | Tetragon, Tailscale, Trivy, gh CLI, helm, terraform |
| **cross-rs (Rust + Docker)** | ~6 | ripgrep, fd, hyperfine, vector, starship |
| **musl-cross / static** | ~6 | Tailscale Linux, k3s static, sentry-cli |
| **goreleaser-cross Docker** | ~3 | Parca-Agent + 多 infra |
| **zig cc** | 2 | Bun, Zig 自己 |
| **crosstool-ng custom (本文)** | ~3 | messense, manylinux2014, Rust dist for aarch64 |
| **AmanoTeam/obggcc** | 多 (Linux only) | 直接給 prebuilt cross-gcc + 多 glibc 版本 sysroot |
| **manylinux 生態** | 2 | uv, Python wheel infra |

對最像本目錄情境（Go + cgo + 出貨企業 Linux）的 project，主流是 **Docker as toolchain**（Tetragon[^12]、Tracee[^13]、Cilium[^14]、Beats[^15]、Parca-Agent[^16]）。**沒人用 zig cc**、**沒人用 Mac-native ct-ng**。

我們選 Mac-native ct-ng 因為：
1. M1/M2 Mac dev 想要 native arm64 速度 (Docker linux/amd64 走 Rosetta 2 慢 30-40%)
2. 跟 reference toolchain ABI 對齊有商業價值
3. 為了 CI / release 還是要 Docker 路線（不是這 repo 的 scope）

---

## Distribution：怎麼把 toolchain 給其他人

我們 build 出來的是 ~3 GB Mac arm64 toolchain。要給同事用，幾種選擇：

### 選項 A：Brew tap（推薦）

仿 messense 的做法。創一個 GitHub repo `homebrew-cross-toolchains`，寫 `.rb` formula 指向你的 GitHub Release tarball：

```ruby
class X8664Centos6LinuxGnu < Formula
  desc "x86_64-centos6-linux-gnu cross toolchain (reference compatible)"
  version "11.2.0"
  url "https://github.com/your-org/cross-toolchains/releases/download/v11.2.0/x86_64-centos6-linux-gnu-#{Hardware::CPU.arm? ? 'aarch64' : 'x86_64'}-darwin.tar.gz"
  sha256 "..."

  def install
    (prefix/"toolchain").install Dir["./*"]
    Dir.glob(prefix/"toolchain/bin/*") {|file| bin.install_symlink file}
  end
end
```

同事：
```bash
brew tap your-org/cross-toolchains
brew install x86_64-centos6-linux-gnu
```

native 跑、零 overhead、體驗最像 Docker pull。

### 選項 B：Tart VM（如果要 image-based）

[Tart](https://tart.run/) 是 Mac 上 Docker-like CLI 跑 macOS VM。把 toolchain build 進 macOS VM image：
```bash
tart create --from-ipsw=latest macos-toolchain
tart run macos-toolchain
# 進去 install toolchain
tart push macos-toolchain ghcr.io/your-org/macos-toolchain:1.0
```

同事：`tart pull ... && tart run`。但每個 VM image 5-20 GB、跑起來吃 4 GB+ RAM，不適合日常 dev。

### 選項 C：直接 tarball

把 `/Volumes/ct-x86_64-centos6/x-tools/x86_64-centos6-linux-gnu/` tar 起來給人，搭個 install 腳本。最簡單但最不專業。

### 為什麼 Docker 不是選項

Docker container = Linux container。Mac arm64 Mach-O 二進制檔放進去不會跑（Linux kernel 認不得）。Apple 自家 `container` CLI 跑的也是 Linux container，不是 macOS container。**macOS 沒有 container 概念**（沒 namespaces / cgroups），只有 VM。要 image-based 分發只能走 Tart。

---

## 進階話題：跨 macOS 版本相容性

我們 build 的 toolchain 在 macOS 26 上能跑。能不能跑在 macOS 11 (Big Sur)？

**沒人專門測過**[^25]。messense CI[^24] 用 macOS 14/15、不顯式設 `MACOSX_DEPLOYMENT_TARGET`。我們的 build 沿用同樣做法，預設 deployment target 大概是 macOS 13/14。

要保證跨版本相容，build 前 export：
```bash
export MACOSX_DEPLOYMENT_TARGET=11.0
export SDKROOT=$(xcrun -sdk macosx --show-sdk-path)
```

但 macOS 26 SDK 可能根本不含 11.0 的 API stub（Apple 通常保 N-3 個版本，11 對 26 = 15 版差）。最保險就是在最舊的目標 macOS 上 build。

---

## 怎麼除錯下一個你會踩到的坑

通用流程：

```
1. ct-ng fail → 看 tmp/last-build-logs-1.25/build.log 抓真正 error 字串
   (build script 的 trap 會自動 copy 出來)

2. 搜尋 exact error string:
   - GitHub crosstool-ng/issues 搜
   - 上游 component 的 mailing list (binutils, gcc, glibc)
   - messense/homebrew-macos-cross-toolchains 看 .config 跟 workflow

3. 沒 hit 的話，bisect 環境變數:
   - env -i HOST_CC=brew-gcc-14 ... 跟原 build 對比，找出哪個 var 影響
   - patch 用 `set -x` 看 ct-ng 跑的 command line

4. 確認 fix 真的解問題:
   - 重 build，看 fail 點是不是變了 (移到下一個 step)
   - 如果同樣訊息 → fix 沒生效，重看 root cause

5. 把 fix 寫進 build-1.25.sh 或 defconfig 或 ct-ng 內部 patch dir
```

---

## Quick reference：ct-ng 重要 config option

我們 defconfig 用到的（`x86_64-centos6-glibc212.defconfig`）：

| Option | 我們的值 | 作用 |
|---|---|---|
| `CT_OBSOLETE` | y | 允許選 obsolete package（glibc 2.12.1 標 obsolete） |
| `CT_EXPERIMENTAL` | y | 允許 experimental flag |
| `CT_OVERRIDE_CONFIG_GUESS_SUB` | y | macOS arm64 必需，舊 config.guess 不認 Apple Silicon |
| `CT_TARGET_VENDOR` | "centos6" | tuple vendor 段 |
| `CT_LINUX_V_2_6_32` | y | kernel headers 用 2.6.32.71 (CentOS 6 actual) |
| `CT_GLIBC_V_2_12_1` | y | glibc 2.12.1 (boolean choice，不是 string) |
| `CT_GCC_VERSION` | "11.2.0" | GCC 版本 |
| `CT_BINUTILS_VERSION` | "2.38" | 1.25 ships 最新 |
| `CT_CC_GCC_LIBSANITIZER` | n | libsanitizer 要 glibc 2.27+，2.12 沒 |
| `CT_CC_GCC_LIBQUADMATH` | n | 跟 reference 對齊 |
| `CT_CC_GCC_LIBGOMP` | n | 跟 reference 對齊 |
| `CT_CC_GCC_LIBSSP` | n | 跟 reference 對齊 |
| `CT_CC_GCC_LIBMPX` | y | Intel MPX, GCC 9- 才有 |
| `CT_CC_GCC_LNK_HASH_STYLE_BOTH` | y | 同時 emit DT_HASH + DT_GNU_HASH，舊 ld.so 才能 load |
| `CT_GLIBC_ENABLE_OBSOLETE_RPC` | y | 留 `<rpc/*.h>`，BD SDK 之類 legacy 程式可能用 |
| `CT_PARALLEL_JOBS` | 0 | 用所有 CPU core |
| `CT_DEBUG_GDB` | (not set) | 跳過 cross-gdb（暫時，要的話打開） |

---

## 附錄 A：brew 依賴每個 package 解釋（初學者向）

build script 內 `REQUIRED_BREW=` 列了 18 個 package。每個為什麼需要：

| package | 它做什麼 | macOS 為什麼缺它 / 為什麼不能用內建版 |
|---|---|---|
| `autoconf` | 從 `configure.ac` 生成 `configure` script | macOS 沒裝 / 系統版可能太舊 |
| `automake` | 從 `Makefile.am` 生成 `Makefile.in` | 同上 |
| `bash` | bash 5 (我們需要 `${var^^}` 等 bash 4+ syntax) | macOS `/bin/bash` 是 bash 3.2 (Apple GPLv3 拒升級) |
| `binutils` | GNU assembler / linker / objcopy / objdump 等 | Apple 自家 binutils 只認 Mach-O，編 cross 用不到 ELF；但我們**只用** `objcopy` `objdump` `readelf` 這三個 macOS 沒提供的 |
| `bison` | parser generator (`.y` → `.c`)，編 GCC / glibc 要用 | macOS 內建 `yacc` 是 BSD yacc，太舊不認 GCC source 用的 bison-only feature |
| `gawk` | GNU awk — POSIX awk 不夠用（gettext / glibc 內 awk script 用 GNU 擴充） | macOS `/usr/bin/awk` 是 BSD awk |
| `gettext` | i18n 支援 + `msgfmt` / `xgettext` 工具 | macOS 沒內建 |
| `gnu-sed` | GNU sed (`-i.bak` syntax 跟 BSD `-i ''` 不同) | macOS `/usr/bin/sed` 是 BSD sed |
| `gnu-tar` | GNU tar (`--strip-components` 等 flag BSD tar 解析錯) | macOS `/usr/bin/tar` 是 BSD tar |
| `help2man` | 從 binary 的 `--help` 輸出產生 man page | macOS 沒 |
| `libtool` | shared library wrapper (`*.la` 檔處理) | macOS 有 BSD libtool 但用法不同 |
| `make` | GNU make 4.x | macOS 內建 GNU make 但版本舊 (3.81)，部分 ct-ng feature 需要 4.0+ |
| `ncurses` | terminal UI library，gdb 跟 dialog UI 要 link | macOS 有 ncurses 但版本不同、可能撞 |
| `readline` | command-line editing library，gdb 要 | macOS 不提供（Apple 用 libedit 替代） |
| `texinfo` | `makeinfo` — GCC source 內 .texi 文件處理 | macOS 沒 |
| `wget` | HTTP downloader (ct-ng 用 wget 不用 curl) | macOS 沒 wget |
| `xz` | xz compression (`.tar.xz` decompress) | macOS 有但 brew 版確保 |
| `zstd` | zstd compression | 同上 |
| `gcc@14` | host C/C++ compiler (替代 Apple Clang 21，避開 libc++ 21 撞 GCC 11 source) | macOS 內建 Apple Clang，太新撞 (Fix #9) |

設這個 array 用意：build script 一開始 `for pkg in "${REQUIRED_BREW[@]}"; brew install "$pkg"` 自動補裝。所以新環境跑 build 不用手動裝。

---

## 附錄 B：build-1.25.sh 完整逐區段解析

腳本主要分 8 區，每區做一件事：

### 區段 1：定位 + 路徑 setup

```bash
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEFCONFIG="${1:-${REPO_ROOT}/toolchain/configs/x86_64-centos6-glibc212.defconfig}"
WORK_DIR="${WORK_DIR:-${REPO_ROOT}/tmp/ct-x86_64-centos6}"
CT_NG_PREFIX="${REPO_ROOT}/tmp/ct-ng-1.25"
CT_NG_BIN="${CT_NG_PREFIX}/bin/ct-ng"
```

**做什麼**：
- `REPO_ROOT` 找 git repo 根（透過 `dirname/.. + pwd`）
- `DEFCONFIG` 預設用 repo 內的，但允許 user 傳第一個 argument 蓋掉
- `WORK_DIR` ct-ng 中間檔放哪
- `CT_NG_BIN` 我們本地 build 出來的 ct-ng 1.25

**為什麼這樣**：所有路徑都基於 `REPO_ROOT`，腳本可被搬到任何位置都能跑。

### 區段 2：依賴檢查 + 自動 install

```bash
REQUIRED_BREW=(autoconf automake bash binutils ...)
for pkg in "${REQUIRED_BREW[@]}"; do
    if ! brew list --formula "${pkg}" >/dev/null 2>&1; then
        brew install "${pkg}"
    fi
done
```

**做什麼**：對每個 package 檢查 brew 裝了沒，沒裝就自動 install。

**為什麼這樣**：給 user friendly 第一次 setup — 不用手動敲一串 `brew install`。

### 區段 3：PATH 排序（最關鍵的一段）

```bash
export PATH="\
/bin:/usr/bin:\
${BREW_PREFIX}/opt/make/libexec/gnubin:\
${BREW_PREFIX}/opt/gnu-sed/libexec/gnubin:\
${BREW_PREFIX}/opt/gnu-tar/libexec/gnubin:\
${BREW_PREFIX}/opt/bison/bin:\
${BREW_PREFIX}/opt/libtool/libexec/gnubin:\
${PATH}:\
${BREW_PREFIX}/opt/binutils/bin"
```

PATH 內每段為什麼出現在這位置：

| PATH 段 | 為什麼 | 不在這位置會怎樣 |
|---|---|---|
| `/bin:/usr/bin` 第一 | 讓 `bash` 解析到 `/bin/bash` 3.2（沒 CoreFoundation linkage）給 autoconf subshell 用 | 會撞 macOS 26 fork-safety SIGSEGV |
| brew GNU `make` 接著 | ct-ng 內部要 GNU make 4 (有些 ct-ng feature 用 4 only) | 跑 macOS 系統 `make` 3.81 → 部分 ct-ng feature 失效 |
| brew `gnu-sed` 接著 | ct-ng 內部 sed pattern 用 GNU 擴充 | BSD sed 解析錯 |
| brew `gnu-tar` 接著 | 同上 (BSD tar 不認 `--strip-components`) | 解 source tarball fail |
| brew `bison` 接著 | GCC / glibc source 編譯需要新 bison | macOS 內建 `yacc` 太舊 |
| brew `libtool` 接著 | 部分 component build 要 GNU libtool（不是 BSD） | autotools rebuild fail |
| `${PATH}` user 原 PATH | 留 user 原本的 PATH (gpg / git 等) | 把 user 環境清掉 |
| brew `binutils` 最後 | 補 `objcopy` `objdump` `readelf`（Apple 沒提供） | 部分 step 找不到工具 |

**為什麼 binutils 在最後不在前面**：ct-ng issue [#1788](https://github.com/crosstool-ng/crosstool-ng/issues/1788) 討論 PATH ordering — 我們經驗：brew binutils 的 `ar` 跟 macOS `/usr/bin/ar` 行為差異會弄壞 ncurses build。讓 `/usr/bin/ar` 贏 → 把 brew binutils 放後面（自驗，issue 線討論一致）。

### 區段 4：Bash / locale / fork-safety 環境

```bash
export BASH=/bin/bash
export CONFIG_SHELL=/bin/bash
export OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES
export LANG=C
export LC_ALL=C
```

**做什麼**：
- `BASH` / `CONFIG_SHELL` 都指 `/bin/bash` → autoconf 生成的 configure 用它跑（避開 brew bash 5 + CoreFoundation 那個 SIGSEGV）
- `OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES` 是備用設定（雖然其實不解 CF fork-safety，但 ObjC fork-safety 還是有用）
- `LANG=C LC_ALL=C` → 強制 POSIX locale，避免某些 awk script 因 locale 不一致 silent fail（gawk 對 LANG unset 會出空輸出，本 build script 額外解了那個）

**不設會怎樣**：autoconf subshell 在 macOS 26 SIGSEGV、awk 出空輸出 build 不出 libncurses.a 等。

### 區段 5：CFLAGS / LDFLAGS / CPPFLAGS

```bash
# 不放 -I/opt/homebrew/opt/binutils/include — 會撞 binutils 2.38 source own ansidecl.h
export LDFLAGS="-L${BREW_PREFIX}/opt/bison/lib -L${BREW_PREFIX}/opt/ncurses/lib"
export CPPFLAGS="-I${BREW_PREFIX}/opt/ncurses/include"
export PKG_CONFIG_PATH="${BREW_PREFIX}/share/pkgconfig:${PKG_CONFIG_PATH:-}"
```

**做什麼**：
- 給 brew bison + ncurses 的 lib / include 路徑
- pkg-config 路徑加上 brew 的

**為什麼不加 binutils**：Fix #7 — brew binutils 2.46 的 `ansidecl.h` 移除了 `PTR` macro，shadow binutils 2.38 source 自己的 ansidecl.h → libiberty 編不過。

### 區段 6：brew GCC 14 wrapper

```bash
GCC14_PREFIX="${BREW_PREFIX}/opt/gcc@14"
WRAPPERS="${REPO_ROOT}/tmp/gcc14-wrappers"
if [[ -x "${GCC14_PREFIX}/bin/gcc-14" ]]; then
    rm -rf "${WRAPPERS}"
    mkdir -p "${WRAPPERS}"
    ln -sf "${GCC14_PREFIX}/bin/gcc-14" "${WRAPPERS}/gcc"
    ln -sf "${GCC14_PREFIX}/bin/g++-14" "${WRAPPERS}/g++"
    ln -sf "${GCC14_PREFIX}/bin/gcc-14" "${WRAPPERS}/cc"
    ln -sf "${GCC14_PREFIX}/bin/g++-14" "${WRAPPERS}/c++"
    export PATH="${WRAPPERS}:${PATH}"
fi
```

**做什麼**：建一個目錄含 4 個 symlink 把 brew gcc-14 假裝成 `gcc`、放 PATH 第一個。

**為什麼**：見 Fix #9 詳解。簡言之：Apple Clang 21 + libc++ 21 撞 GCC 11 source。要換 host compiler 但 ct-ng 拒 `CC=` env var → 走 wrapper symlink。

### 區段 7：Sparseimage 自動建立

```bash
mkdir -p "${WORK_DIR}"
touch "${WORK_DIR}/.cscheck-A" "${WORK_DIR}/.cscheck-a"
CS_COUNT=$(find "${WORK_DIR}" -maxdepth 1 -name '.cscheck-*' | wc -l | tr -d ' ')
rm -f "${WORK_DIR}/.cscheck-A" "${WORK_DIR}/.cscheck-a"

if [[ "${CS_COUNT}" -lt 2 ]]; then
    # 建 case-sensitive sparseimage, attach, remap WORK_DIR
    hdiutil create -type SPARSE -size 30g -fs "Case-sensitive Journaled HFS+" ...
fi
```

**做什麼**：
1. 建測試檔 `.cscheck-A` 跟 `.cscheck-a`
2. `find` 算有幾個檔
3. 如果 case-insensitive (一個檔)，就建 sparseimage

**為什麼**：見 Mechanism 3。Linux source 有大小寫差別檔，需要 case-sensitive FS。我們用 HFS+ 不用 APFS（APFS metadata 跟 ncurses parallel build race，messense CI 也選 HFS+）。

### 區段 8：ct-ng 跑 build + log trap

```bash
cd "${WORK_DIR}"
DEFCONFIG="${DEFCONFIG}" ct-ng defconfig
# Override CT_PREFIX_DIR 改寫到 sparseimage 上
awk -v new="..." '/^CT_PREFIX_DIR=/{...}' .config

trap extract_logs EXIT
ct-ng build
```

**做什麼**：
1. cd 到 work dir 跑 `ct-ng defconfig` 把 defconfig 套用
2. awk 改 `.config` 內 `CT_PREFIX_DIR` 指向 sparseimage（兩個目錄都要 case-sensitive）
3. 設 trap：fail 或 success 都 copy 出 build.log + 各 component config.log 到 `tmp/last-build-logs-1.25/`
4. 跑 `ct-ng build`

**為什麼用 awk 改 .config 不用 sed**：
- BSD sed `-i ''` 跟 GNU sed `-i.bak` syntax 不相容
- 我們 PATH 第一個是 GNU sed，但腳本本身想可攜 → 用 awk 三段式 (`{ pattern; next }; 1`) 通用

**為什麼設 trap**：sparseimage detach 後就看不到內部 log，事後想 debug 沒料。trap 確保 fail 也 copy 出來。

---

## 附錄 C：defconfig 完整逐行解析

`toolchain/configs/x86_64-centos6-glibc212.defconfig` 每一行：

### 開頭 metadata

```
CT_CONFIG_VERSION="4"
```
ct-ng config schema 版號。1.25 用 4。改變代表 config 格式變動，ct-ng 會提示升級。

### 允許 obsolete / experimental

```
CT_OBSOLETE=y
CT_EXPERIMENTAL=y
```
**OBSOLETE**：glibc 2.12.1 在 ct-ng 1.25 標 obsolete（package.desc 內 `obsolete='yes'`）。沒這 flag 選不到。
**EXPERIMENTAL**：允許實驗 flag。我們其實不直接用 experimental feature，但保留以防某 dependency chain 要。

### Architecture

```
CT_ARCH_X86=y
CT_ARCH_64=y
```
target 架構：x86_64。`CT_ARCH_X86=y` 包 x86 family，`CT_ARCH_64=y` 確認是 64-bit。

### Target tuple vendor

```
CT_TARGET_VENDOR="centos6"
```
target tuple 第二段。`x86_64-{vendor}-linux-gnu` → `x86_64-centos6-linux-gnu`。GCC 不會根據 vendor 改 ABI 行為（見 Mechanism 5）。寫 `centos6` 純為跟 reference 對齊。

### macOS arm64 救援

```
CT_OVERRIDE_CONFIG_GUESS_SUB=y
```
macOS arm64 host 必設。autoconf 的 `config.guess` 在 2024 之前不認得 Apple Silicon → ct-ng abort。設 `OVERRIDE_CONFIG_GUESS_SUB=y` 讓 ct-ng 跳過 config.guess 自我測，直接用 defconfig 推算。

### Install location

```
CT_PREFIX_DIR="${HOME}/x-tools/${CT_TARGET}"
```
最終 toolchain 安裝到哪。`${CT_TARGET}` 在 ct-ng 內展開成 `x86_64-centos6-linux-gnu`。實際路徑變 `~/x-tools/x86_64-centos6-linux-gnu/`。但 build script 在 sparseimage case 會 awk 改寫成 `/Volumes/.../x-tools/${CT_TARGET}`。

### Linux kernel headers

```
CT_KERNEL_LINUX=y
CT_LINUX_V_2_6_32=y           # ★ boolean choice（不是 string）必須有
CT_LINUX_VERSION="2.6.32.71"  # 從 boolean 推出來、雖然多餘但保留
```
**為什麼 2.6.32**：CentOS 6 實際 kernel 版本。bigger picture 上，target binary 會帶 `LC_BUILD_VERSION` 或 ELF note 標 kernel ABI ≥ 2.6.32 → 跑得了任何 ≥ 2.6.32 kernel。
**為什麼必須 boolean choice**：見 Fix #4。

### glibc

```
CT_LIBC_GLIBC=y               # 選 glibc (vs musl / uClibc)
CT_GLIBC_V_2_12_1=y           # ★ boolean choice 必須有
CT_GLIBC_VERSION="2.12.1"
CT_THREADS="nptl"             # POSIX threads model
```
**為什麼 NPTL**：glibc 2.12 era 已只剩 NPTL（LinuxThreads 早被 deprecated）。這欄寫 `nptl` 即可。

```
CT_GLIBC_KERNEL_VERSION_NONE=y
```
glibc configure 的 `--enable-kernel=` 改 NONE。設 NONE 表示 glibc binary 仍可跑在比 build 時 kernel 更舊的系統。我們設 NONE 是因為 reference 也不限定 kernel min。

```
CT_GLIBC_FORCE_UNWIND=y
```
強制 glibc build 自己的 unwinder（不要 rely host gcc 提供）。stage-1 GCC 殘缺 → 沒 host libgcc-eh 可給 → glibc 必須帶自己的。

```
CT_GLIBC_BUILD_SSP=y
CT_GLIBC_SSP_DEFAULT=y
```
編 glibc 時開 stack protector（SSP），且 default-on。cgo Go binary 預設 `-fstack-protector` 期望 libssp_nonshared.a 存在。

```
CT_GLIBC_ENABLE_OBSOLETE_RPC=y
```
留 `<rpc/*.h>` headers。Bitdefender SDK 之類 legacy 程式可能 `#include <rpc/types.h>` 之類。glibc 2.26+ 才把 RPC 移走，2.12 本來就有，這旗開不開影響不大但保險。

```
CT_GLIBC_EXTRA_CFLAGS="-Wno-error -Wno-array-bounds -Wno-stringop-overflow -Wno-maybe-uninitialized -Wno-missing-attributes"
```
build glibc 時加的 CFLAGS。glibc 2.12 source 是 2010 寫的，新 GCC 11 偵測到很多 false positive（陣列邊界、stringop 溢位等）。glibc 預設 `-Werror` → 這些 warning 會被升 error → 編不過。`-Wno-*` 把 false positive 一一禁。

### binutils

```
CT_BINUTILS_VERSION="2.38"
CT_BINUTILS_LINKER_LD=y
CT_BINUTILS_LINKER_DEFAULT="bfd"
CT_BINUTILS_FORCE_LD_BFD_DEFAULT=y
```
binutils 2.38 是 ct-ng 1.25 ships 最新版。LINKER_LD=y → build `ld.bfd`。default bfd → 用 bfd linker（不用 gold）。binutils 2.44+ 已移除 gold linker，2.38 還有但不啟用。

```
CT_BINUTILS_PLUGINS=y
CT_BINUTILS_DETERMINISTIC_ARCHIVES=y
CT_BINUTILS_EXTRA_CONFIG_ARRAY="--with-system-zlib"
```
- `PLUGINS=y` → 開 binutils plugin（gold + LTO 用）
- `DETERMINISTIC_ARCHIVES=y` → `ar` 產生的 `.a` 不含 timestamp，可重現 build
- `--with-system-zlib` → binutils link 系統的 libz 而非 bundle 自己的

### GCC

```
CT_CC_GCC=y
CT_GCC_VERSION="11.2.0"        # 跟 reference 對齊
CT_CC_LANG_C=y
CT_CC_LANG_CXX=y
CT_CC_GCC_LIBSTDCXX=y
```
標準三件套：選 GCC、開 C 跟 C++、build libstdc++.so。

```
CT_CC_GCC_LIBQUADMATH=n        # 跟 reference 對齊（disable）
CT_CC_GCC_LIBGOMP=n
CT_CC_GCC_LIBSSP=n
CT_CC_GCC_LIBSANITIZER=n
CT_CC_GCC_LIBMPX=y
CT_CC_GCC_LIBSTDCXX_VERBOSE=n
```
- `LIBQUADMATH=n` 不 build `__float128` 支援
- `LIBGOMP=n` 不 build OpenMP
- `LIBSSP=n` 不 build GCC 自家 stack protector helper（有 glibc 那份就夠）
- `LIBSANITIZER=n` 不 build asan/ubsan/msan/tsan（依賴 glibc 2.27+ 內部 symbol，2.12 沒）
- `LIBMPX=y` Intel MPX (memory bounds check)，GCC 9- 才有，11 還支援
- `LIBSTDCXX_VERBOSE=n` `terminate()` handler 不 pull stdio in（binary 比較小）

```
CT_CC_GCC_USE_LTO=y
CT_CC_GCC_ENABLE_TARGET_OPTSPACE=y
CT_CC_GCC_SYSTEM_ZLIB=y
CT_CC_GCC_USE_SYSROOTED_HEADERS=y
CT_CC_GCC_BUILD_ID=y
```
- `USE_LTO=y` 開 Link-Time Optimization
- `ENABLE_TARGET_OPTSPACE=y` target libgcc 用 `-Os` 編（smaller code）
- `SYSTEM_ZLIB=y` 用系統 zlib
- `USE_SYSROOTED_HEADERS=y` GCC 用 sysroot 內 header（不用 host）
- `BUILD_ID=y` ELF 內加入 build-id（debug 用）

```
CT_CC_GCC_LNK_HASH_STYLE_BOTH=y
```
**重要**：產出的 binary 同時 emit DT_HASH (sysv 樣式) + DT_GNU_HASH。CentOS 6 era ld.so 預設只認 DT_HASH，新 GCC 預設只 emit DT_GNU_HASH → 部署到舊機器 ld.so 找不到 hash → 開不了 ELF。設 BOTH 兩種都有，舊 / 新 ld.so 都吃。

### Companion library 版本（ct-ng 內部用）

```
CT_GMP_VERSION="6.2.1"
CT_MPFR_VERSION="4.1.0"
CT_MPC_VERSION="1.2.1"
CT_ISL_VERSION="0.24"
```
這些是 GCC 內部要 link 的數學 library。版本選 ct-ng 1.25 ships 的最新。

### gdb (optional, skipped)

```
# CT_DEBUG_GDB is not set
```
不 build cross-gdb。開了的話會增加 ~5 min build time + 一些 ncurses 依賴。要 debug target binary 可以後續再開。

### Build hygiene

```
CT_PARALLEL_JOBS=0             # 0 = 用 nproc 全部 core
CT_USE_PIPES=y                 # gcc -pipe 比寫中間 .s 檔快
CT_LOCAL_TARBALLS_DIR="${HOME}/.crosstool-ng-tarballs"
CT_SAVE_TARBALLS=y             # 下載過的 tarball 留下，下次 build 不用再下
CT_VERIFY_DOWNLOAD_DIGEST=y    # 對下載 tarball 驗 SHA512
CT_VERIFY_DOWNLOAD_DIGEST_SHA512=y
CT_LOG_EXTRA=y
CT_LOG_LEVEL_MAX="EXTRA"       # log verbosity (silent < info < extra < debug < all)
CT_LOG_TO_FILE=y
CT_LOG_FILE_COMPRESS=y         # build.log.bz2 而非 build.log
CT_REMOVE_DOCS=y               # 不 install info / man pages（toolchain 變小）
CT_INSTALL_LICENSES=y          # 留每個 component 的 LICENSE 檔
CT_STRIP_HOST_TOOLCHAIN_EXECUTABLES=y    # 把 toolchain 二進制 strip 過
CT_RM_RF_PREFIX_DIR=y          # build 開始前 rm -rf prefix（fresh start）
```

### Apple Clang strictness rollback (Build #11 後清空)

```
CT_EXTRA_CFLAGS_FOR_HOST=""
CT_EXTRA_CFLAGS_FOR_BUILD=""
```
原本是 `-Wno-error=incompatible-function-pointer-types ...` 給 Apple Clang 21 用。換 GCC 14 後 GCC 不認那 flag → 清空。

---

## 附錄 D：兩個 patches 完整內容

### Patch 1：`0001-fix-unifdef-strlcpy-macos.patch`（Linux 2.6.32.71）

位置：`tmp/ct-ng-1.25/share/crosstool-ng/packages/linux/2.6.32.71/0001-fix-unifdef-strlcpy-macos.patch`

完整內容：
```diff
Remove unifdef.c's local `strlcpy` declaration that conflicts with Apple SDK.

Linux 2.6.32 era unifdef.c declares `size_t strlcpy(...)` as a forward
prototype because some Linux distros' glibc didn't have strlcpy at the time
(it's a BSD extension that landed in glibc 2.38). On macOS, strlcpy IS in
<string.h>, AND _FORTIFY_SOURCE rewrites the call to __builtin___strlcpy_chk.
The prototype mismatch crashes Apple Clang 21:

    scripts/unifdef.c:84:8: error: expected parameter declarator
    scripts/unifdef.c:84:8: error: conflicting types for '__builtin___strlcpy_chk'

We delete the local prototype since macOS's <string.h> already declares it.

--- a/scripts/unifdef.c	2009-12-03 14:51:21.000000000 -0800
+++ b/scripts/unifdef.c	2026-05-08 11:55:00.000000000 -0700
@@ -81,8 +81,6 @@
 #include <string.h>
 #include <unistd.h>

-size_t strlcpy(char *dst, const char *src, size_t siz);
-
 /* types of input lines: */
 typedef enum {
 	LT_TRUEI,		/* a true #if with ignore flag */
```

**逐行解釋**：
- 開頭 commit message style 說明：解釋 patch 用意，給未來讀的人 context
- `--- a/scripts/unifdef.c` 跟 `+++ b/...` 是 diff 標準前置 (a = before, b = after)
- `@@ -81,8 +81,6 @@` 是 hunk header — 從原檔 line 81 開始 8 行、改成新檔 line 81 開始 6 行（差 2 行 = 我們刪兩行）
- 沒 `+`/`-` prefix 的 3 行是 context (`#include <string.h>` `#include <unistd.h>` `/* types of input lines: */`) — 用來定位這個 hunk 在原檔哪
- 空白行也算
- `-` prefix 兩行是要刪的 (`size_t strlcpy(...)` 跟它後面空行)

**ct-ng 怎麼用這 patch**：build glibc 2.12 之前 ct-ng 會自動 apply `packages/linux/2.6.32.71/` 內所有 `.patch` 檔，按字母順序。我們這支 `0001-` 起頭，在所有上游 patches 之前。

### Patch 2：`0002-fix-fdopen-macos.patch`（zlib 1.2.12）

位置：`tmp/ct-ng-1.25/share/crosstool-ng/packages/zlib/1.2.12/0002-fix-fdopen-macos.patch`

完整內容：
```diff
Remove the bogus `#define fdopen(fd,mode) NULL` redefinition.

On modern macOS (TARGET_OS_MAC defined via TargetConditionals.h), zlib 1.2.12's
zutil.h activates a Mac OS Classic-era (System 7-9) workaround that #defines
fdopen to NULL. When stdio.h gets included later (by gzguts.h), Apple's
prototype expands as `FILE *NULL(int, const char *)`, which is syntactically
invalid and the build aborts with:

    _stdio.h:322:7: error: expected identifier or '('
        FILE *fdopen(int, const char *) __DARWIN_ALIAS_STARTING(...)

Modern macOS (Darwin/POSIX) provides fdopen via stdio.h, so the placeholder
isn't needed. Fixed in zlib 1.2.13 by excluding __APPLE__ from the condition;
we just delete the offending define.

--- a/zutil.h	2022-03-26 11:30:00.000000000 -0700
+++ b/zutil.h	2026-05-08 10:30:00.000000000 -0700
@@ -144,9 +144,7 @@
 #    if defined(__MWERKS__) && __dest_os != __be_os && __dest_os != __win32_os
 #      include <unix.h> /* for fdopen */
 #    else
-#      ifndef fdopen
-#        define fdopen(fd,mode) NULL /* No fdopen() */
-#      endif
+       /* fdopen is provided by Apple stdio.h on modern macOS */
 #    endif
 #  endif
 #endif
```

**逐行解釋**：
- 跟 patch 1 一樣的 diff 格式
- `@@ -144,9 +144,7 @@` 從 zutil.h line 144 開始 9 行、改成 line 144 開始 7 行（差 2 行 = 刪 3 行加 1 行）
- 刪掉的 3 行：`#      ifndef fdopen`、`#        define fdopen(fd,mode) NULL /* No fdopen() */`、`#      endif`
- 加 1 行 comment 說明為什麼這 block 空著

**ct-ng 怎麼用**：同上，build zlib 之前 apply `packages/zlib/1.2.12/` 內的 patches，按字母順序：`0000-mingw-static-only.patch` → `0001-crossbuild-macos-libtool.patch` → `0002-fix-fdopen-macos.patch`（我們的）。

---

## 附錄 E：ct-ng 安裝後手動修改清單

ct-ng 從 source build install 之後，要動的 4 個檔（這些**沒辦法**透過 defconfig 解決，必須直接改 ct-ng 安裝樹）：

### 1. `tmp/ct-ng-1.25/bin/ct-ng`（Makefile 形式的 entrypoint）

```diff
- export bash         = /bin/bash
+ export bash         = /opt/homebrew/opt/bash/bin/bash
```
**為什麼**：ct-ng 跑自己 script 用這 bash。`/bin/bash` 3.2 不支援 `${var^^}` (Fix #2)。

### 2. `tmp/ct-ng-1.25/share/crosstool-ng/paths.sh`

```diff
- export bash="/bin/bash"
+ export bash="/opt/homebrew/opt/bash/bin/bash"
```
**為什麼**：同上。paths.sh 是被各個 build script source 進去的，bash 變數從這出來。

### 3. `tmp/ct-ng-1.25/share/crosstool-ng/packages/zlib/package.desc`

```diff
- mirrors='http://downloads.sourceforge.net/project/libpng/zlib/${CT_ZLIB_VERSION} https://www.zlib.net/'
+ mirrors='https://www.zlib.net/fossils https://www.zlib.net/'
```
**為什麼**：zlib 1.2.12 從上游撤掉 (CVE)，新 mirror 在 fossils archive (Fix #3)。

### 4. `tmp/ct-ng-1.25/share/crosstool-ng/config/versions/zlib.in`（auto-generated kconfig）

```diff
- default "http://downloads.sourceforge.net/project/libpng/zlib/${CT_ZLIB_VERSION} https://www.zlib.net/"
+ default "https://www.zlib.net/fossils https://www.zlib.net/"
```
**為什麼**：這是 ct-ng 安裝時從 package.desc 自動生成的 kconfig。改 package.desc 後它不會自動重 gen，要手動同步。否則 ct-ng `defconfig` 從 kconfig 讀 default mirror 還是舊的 → 又踩 404。

### 還有一個自動生成的：`tmp/ct-ng-1.25/share/crosstool-ng/scripts/build/companion_libs/220-ncurses.sh`

ct-ng 1.25 build script 內 ncurses 配置 — 我們加了 macOS 28 + locale 救援邏輯：

```diff
     CT_DoLog EXTRA "Configuring ncurses"
+    # macOS workaround: ncurses' autoconf-generated configure unsets LANG
+    # at line 70 (`$as_unset LANG ...`). With LANG unset, gawk silently
+    # fails to produce mk-1st.awk's output, leaving libncurses.a build rule
+    # missing. Patch the autoconf locale-unset lines to force LANG=C instead.
+    /opt/homebrew/opt/gnu-sed/bin/gsed -i \
+        -e 's|^\$as_unset LANG .*|LANG=C; export LANG|' \
+        -e 's|^\$as_unset LC_ALL .*|LC_ALL=C; export LC_ALL|' \
+        "${CT_SRC_DIR}/ncurses/configure"
     CT_DoExecLog CFG                                                    \
     CFLAGS="${cflags}"                                                  \
     LDFLAGS="${ldflags}"                                                \
+    LANG=C LC_ALL=C                                                     \
     ${CONFIG_SHELL}                                                     \
     "${CT_SRC_DIR}/ncurses/configure"                                   \
```

**為什麼**：autoconf 生成的 `configure` script 為了確定性會 unset LANG。但 gawk 5.4 在 LANG unset 時某些 locale-aware code path 默默 fail，輸出空 → ncurses Makefile 缺 libncurses.a 規則 → build fail。我們 (a) 預先 patch ncurses configure script、把 `$as_unset LANG` 改 `LANG=C; export LANG`，(b) line 內也加 `LANG=C LC_ALL=C` 雙保險。

---

## 附錄 F：ct-ng 1.25 從 source build 步驟

repo 不入 git 的 `tmp/ct-ng-1.25/` 是手動 build 出來的。流程：

```bash
# Step 1: 下載 ct-ng 1.25.0 release tarball (含 pre-bootstrap configure)
cd toolchain/vendor
curl -fsSL -o ct-ng-1.25.0-release.tar.xz \
    "https://github.com/crosstool-ng/crosstool-ng/releases/download/crosstool-ng-1.25.0/crosstool-ng-1.25.0.tar.xz"
mkdir -p release-extract
tar xJf ct-ng-1.25.0-release.tar.xz -C release-extract

# Step 2: 進去 source dir，準備 macOS-friendly env
cd release-extract/crosstool-ng-1.25.0
export PATH="/opt/homebrew/opt/gnu-sed/libexec/gnubin:/opt/homebrew/opt/gnu-tar/libexec/gnubin:..."
export CONFIG_SHELL=/bin/bash
export LANG=C LC_ALL=C
export OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES

# Step 3: configure 跑 autoconf 預生 Makefile
./configure --prefix=/Users/frank.liu/vms/shared/capsule8/tmp/ct-ng-1.25

# Step 4: build (ct-ng 自己是 C 程式 + bash script)
make -j$(sysctl -n hw.ncpu)

# Step 5: install 到 prefix
make install

# Step 6: 套用上面附錄 E 列的 4 個手動修改
sed -i '' 's|^export bash *= */bin/bash|export bash         = /opt/homebrew/opt/bash/bin/bash|' bin/ct-ng
sed -i '' 's|^export bash="/bin/bash"|export bash="/opt/homebrew/opt/bash/bin/bash"|' share/crosstool-ng/paths.sh
# (zlib mirror, ncurses LANG=C 等)
```

### F.1：「pre-bootstrap」是什麼？為什麼我們要 release tarball

autoconf-based project 的標準 build flow 有 **4 階段**：

```
1. bootstrap     — 跑 ./bootstrap (= autoreconf -if)
                   從 configure.ac → 生 configure script
                   從 Makefile.am → 生 Makefile.in
                   ↓
2. configure     — 跑 ./configure
                   檢查系統環境 (gcc / bash 版本 / 等等)
                   從 Makefile.in → 生 Makefile
                   ↓
3. make          — 編譯
                   ↓
4. make install  — 安裝到 prefix
```

第 1 步「bootstrap」是把 autoconf source code 轉成可跑的 configure。每個 release 出包時，**維護者會先跑 step 1**、再把產出的 `configure` 腳本一起塞進 release tarball。

**GitHub source archive** `archive/refs/tags/v1.25.0.tar.gz`：
```
configure.ac     ← source
Makefile.am      ← source
bootstrap        ← shell script (待跑)
(沒 configure 檔)
→ user 必須自己 ./bootstrap
```

**Release tarball** `releases/download/.../v1.25.0.tar.xz`：
```
configure.ac     ← source (留著 reference)
configure        ← ★ 已預生成 (pre-bootstrap done)
Makefile.in      ← ★ 已預生成
→ user 直接 ./configure 就行
```

「**pre-bootstrap**」字面意思 = **bootstrap 已經預先做過了**。

### F.2：為什麼這對 macOS 26 重要

ct-ng 1.25 的 `bootstrap` script 用了 bash 4+ 才有的 syntax (例如 `${var^^}` parameter expansion uppercase)。macOS **`/bin/bash` 是 3.2.57**（Apple 因為 bash 5 是 GPLv3、拒絕升級），跑 bootstrap 會 fail：

```
$ ./bootstrap
Your BASH shell version (3.2.57(1)-release) is too old.
Run bootstrap on a machine with BASH 4.x
```

兩條解法：
- (a) 裝 brew bash 5 → 跑 bootstrap → 跑 configure ...（多一步、多一個依賴）
- (b) 直接用 release tarball → **跳過 step 1**，從 step 2 ./configure 開始 ★

我們選 **(b)**，省事、不依賴 brew bash 在 bootstrap 階段。

### F.3：為什麼裝在 `tmp/ct-ng-1.25/` 不裝 `/opt/homebrew/`

brew 的 ct-ng 是 **1.28**（跟我們要的 1.25 衝突）。**本地 install 獨立**避開：
- brew 的 1.28 不被覆蓋（你 mac 上其他用途還能用 brew 的）
- cleanup 容易（整個 `tmp/ct-ng-1.25/` 目錄 rm -rf 就好）
- 4 個手動修法可以放心做、不污染 brew

### F.4：完整流程（用 toolchain/scripts/bootstrap-ctng.sh 自動化）

repo 內提供 `toolchain/scripts/bootstrap-ctng.sh`，跑一次就 OK：

```bash
bash toolchain/scripts/bootstrap-ctng.sh
```

這 script 做了 6 步：

| Step | 動作 |
|---|---|
| 1 | brew install 必要 deps (autoconf, bash, gnu-sed, ...) |
| 2 | 解壓 `toolchain/vendor/ct-ng-1.25.0-release.tar.xz` 到 `release-extract/` |
| 3 | `./configure --prefix=$REPO/tmp/ct-ng-1.25 && make && make install` |
| 4 | 套 4 個手動修法 (paths.sh / ct-ng Makefile bash / zlib mirror / ncurses LANG=C) |
| 5 | copy `toolchain/patches/` 內 2 個 patch 到 ct-ng package 目錄 |
| 6 | 驗 `ct-ng version` 起得來 |

完整 install 大概 **13 MB**，存 `tmp/ct-ng-1.25/`、不入 git（在 .gitignore 內）。

之後跑 `bash toolchain/scripts/build.sh` 就能開始 toolchain build。

### F.5：rebuild toolchain — 用哪個 defconfig + script

```bash
# 預設 (用 toolchain/configs/x86_64-centos6-glibc212.defconfig)
bash toolchain/scripts/build.sh

# 指定不同 defconfig
bash toolchain/scripts/build.sh path/to/other.defconfig
```

| 檔 | 用途 | 是否使用 |
|---|---|---|
| `toolchain/configs/x86_64-centos6-glibc212.defconfig` | 我們現在的 1.25 + GCC 11.2 + glibc 2.12.1 路線 | ✅ 用這個 |
| `toolchain/configs/_legacy/x86_64-glibc212.defconfig` | 舊 1.28 + GCC 15 路線 (失敗) 備份 | ❌ 不要用，純歷史紀錄 |

build 完 toolchain 在：
```
~/x-tools/x86_64-centos6-linux-gnu/                            (333 MB toolchain 整包)
~/x-tools/x86_64-centos6-linux-gnu/bin/x86_64-centos6-linux-gnu-gcc   ← invoke 這個 cross-gcc
```

---

## 附錄 G：`#include <>` 怎麼找到 header（初學者向）

這節解釋一個常見混淆：「為什麼我寫 `#include <stdio.h>` 它就找得到？」「我把 header 放 sysroot / -I / find_package，差別在哪？」

### G.1：`<>` vs `""` 只差搜尋順序

```c
#include <stdio.h>      // 只搜「system 清單」
#include "myheader.h"   // 先搜當前 .c 檔的目錄、找不到再搜 system 清單
```

兩者搜的「system 清單」**完全一樣**。差別只在 `""` 多一個「source 檔當前目錄優先」。

很多人以為 `<>` 跟 `""` 是兩套不同的搜尋機制，其實不是。

### G.2：「system 清單」由 4 種來源構成

GCC 啟動時拼出一個有序的 include 搜尋清單，依下列來源組合：

```
1. GCC 內建 default (cross-gcc 從 sysroot 自動推算):
     <sysroot>/usr/include/c++/11.2.0/                      ← C++ headers
     <sysroot>/usr/include/c++/11.2.0/x86_64-centos6-linux-gnu/
     <sysroot>/usr/include/c++/11.2.0/backward
     <prefix>/lib/gcc/.../include/                          ← gcc 自家 headers
     <prefix>/lib/gcc/.../include-fixed/
     <sysroot>/usr/include/                                 ← glibc / Linux headers

2. command-line -I /path:
     gcc -I/foo/include test.c
     → /foo/include 加進清單 (在 -I 順序內優先)

3. command-line -isystem /path:
     gcc -isystem /foo/include test.c
     → 跟 -I 類似但 GCC 視為「system 路徑」
       (= -Wno-error 等不會 trigger 在這目錄內 header 上)

4. env var CPATH:
     CPATH=/foo:/bar gcc test.c
     → /foo 跟 /bar 加進清單
```

驗你自己的搜尋清單：
```bash
echo '#include <stdio.h>' | x86_64-centos6-linux-gnu-gcc -E -v - 2>&1 | grep -A20 "search starts here"
```

### G.3：3 種讓 `<header>` 能 work 的做法

#### 做法 A：放進 sysroot（toolchain-wide install）

```bash
SYSROOT=~/x-tools/x86_64-centos6-linux-gnu/x86_64-centos6-linux-gnu/sysroot
cp myheaders/foo.h    $SYSROOT/usr/include/
cp mylibs/libfoo.so   $SYSROOT/usr/lib/
cp mylibs/libfoo.a    $SYSROOT/usr/lib/

# 之後沒任何 flag 就能用:
cross-gcc test.c -lfoo -o test
# #include <foo.h> 自動找到 sysroot/usr/include/foo.h
# -lfoo 自動找到 sysroot/usr/lib/libfoo.{so,a}
```

**何時用**：foo 是「整個 toolchain 都該有」的東西（例如 Bitdefender SDK 裡面的 header / lib，或其他 vendor 標準 lib）。

**缺點**：sysroot 變動 → 不同專案要不同版時打架。

#### 做法 B：command-line `-I` / `-L`（per-project install）

```bash
cross-gcc -I/path/to/foo/include -L/path/to/foo/lib -lfoo test.c -o test
```

**何時用**：foo 只給這個專案用、不適合污染整個 sysroot。

**缺點**：每次編譯都要手動帶 flag（一般用 Makefile 之類自動化）。

#### 做法 C：CMake `find_package` / pkg-config（自動化做法 B）

```cmake
find_package(Foo REQUIRED)
target_link_libraries(myapp PRIVATE Foo::Foo)
```

或：
```bash
gcc test.c $(pkg-config --cflags --libs foo) -o test
```

CMake / pkg-config 都不是新機制 — 它們只是**幫你查 foo 在哪、自動加 `-I` `-L` flag**。最終還是落到做法 B。

之所以 `find_package` 之後 `#include <foo/foo.h>` 也能 work，是因為 CMake 偷偷把 `-I/path/to/foo/include` 加進 compile flag。

### G.4：cgo 的 `#cgo CFLAGS` 是做法 B

```go
/*
#cgo CFLAGS: -I/path/to/foo/include    // ← 做法 B 的 -I
#cgo LDFLAGS: -L/path/to/foo/lib -lfoo  // ← 做法 B 的 -L -l
#include <foo.h>                         // 因為上面 -I 加了，這 include 能 work
*/
import "C"
```

cgo 編 C 部分時 invoke cross-gcc 並傳這些 flag。

### G.5：核心結論

```
「#include <header> 能不能 work」唯一條件:
  /某個地方/header 必須存在 + /某個地方/ 必須在 GCC 的 system 清單內

進清單的途徑都是手段:
  - 預設 (cross-gcc 從 sysroot 自動加)
  - -I 旗標 (CMake / cgo / 手動)
  - -isystem 旗標
  - CPATH env var
```

**`<>` 不是「只能用 system header」**。只要該 header 的目錄進得了清單，`<>` 都能用。同理 `""` 也能用 — 兩者沒本質差別。

---

## 附錄 H：常見編譯 error 速查

build 跨平台 binary 時的常見坑跟救援。

### H.1：`cc1: error: out of memory`（或 `cc1plus terminated: out of memory`）

**Error 訊息**：
```
cc1plus: out of memory allocating 16777216 bytes
cc1: terminated due to signal SIGKILL (out of memory)
g++: internal compiler error: Killed (program cc1plus)
```

**為什麼**：cc1 (= GCC 的 C 前端) / cc1plus (= C++ 前端) 是真正在編譯的 binary。它們吃光 RAM 通常因為：

1. **C++ template 太重**
   - 大量 templated code (Eigen / Boost / 自寫 metaprogramming) 編到一個翻譯單元 (.cpp) 內
   - 每個 template instantiation 都要 cc1plus 在記憶體內 hold 大型 AST
   - 一個 .cpp 可能要 4-8 GB cc1plus heap

2. **LTO (Link-Time Optimization) 開啟**
   - `-flto` 讓 cc1 在 link 階段 hold 整個 program 的 IR
   - 大專案 +LTO = cc1 一個 process 吃 8-16 GB
   - 配 parallel make `-j8` = 8 個 cc1 同時跑 = 64-128 GB needed

3. **小檔案被 LTO 累積**
   - 一個小 hello.c 看似不會 OOM
   - 但 link 時整個 program 的 LTO IR 都在 cc1 內

4. **machine RAM 不夠 / swap 不夠**
   - macOS 預設 swap 大小有限 (動態擴張但有上限)
   - 16 GB Mac 配 -j8 + LTO 重 C++ 專案 → swap 爆 → SIGKILL

5. **cc1 被 32-bit 限制 (罕見)**
   - 老版 GCC 在某些 distro 是 32-bit binary，4 GB virtual memory 上限
   - 我們的 cross-gcc 是 64-bit、不會踩這個

**修法（按優先）**：

```bash
# 1. 降低 parallel: 從 -j8 / -j$(nproc) 降到 -j2 或 -j1
make -j2

# 2. 關 LTO (defconfig 內或 -fno-lto)
# defconfig:
CT_CC_GCC_USE_LTO=n   # 關掉 cross-gcc 自家 LTO support

# user code 編譯時:
cross-gcc -fno-lto test.cpp ...

# 3. 拆大 .cpp
# 一個 .cpp 不要 #include 整個 Boost / Eigen，拆成多個小 .cpp
# 或用 forward declaration 減少 template instantiation

# 4. 用 ccache 跟 distcc 卸載到別台機器
brew install ccache
export CC="ccache cross-gcc"
# distcc 可以把編譯送給遠端機器跑

# 5. 加 swap (macOS 不太能調，Linux 可以):
# Linux:
sudo dd if=/dev/zero of=/swapfile bs=1M count=8192
sudo mkswap /swapfile && sudo swapon /swapfile

# 6. 換有更多 RAM 的機器 build (CI runner 升級)
```

**對我們 cross-toolchain 的影響**：build ct-ng 自己時 cc1plus 編 GCC source 也會吃幾 GB RAM。我們 16 GB+ Mac 沒踩到，但若是 8 GB Mac 跑 `CT_PARALLEL_JOBS=0` (= 全部 core) 可能 OOM。**修法**：defconfig 改 `CT_PARALLEL_JOBS=2` 之類。

**Reference**：
- GCC manual `-flto` memory cost：<https://gcc.gnu.org/onlinedocs/gcc/Optimize-Options.html#index-flto>
- cc1plus OOM 在 GCC bootstrap 是已知現象（GCC mailing list / Stack Overflow 多筆討論；無單一權威 thread，本段內容為 Mac 16GB+ 自身實測）

---

### H.2：`undefined reference to 'symbol@GLIBC_2.X'`

**Error 訊息**：
```
/usr/bin/ld: hello.o: undefined reference to `__libc_start_main@GLIBC_2.34'
collect2: error: ld returned 1 exit status
```

**為什麼**：你 binary reference 一個 GLIBC version 比目標機器 glibc 還新的 symbol。

**修法**：要嘛降目標機器 glibc 期望、要嘛改 toolchain glibc 版本（你想要哪個就調 defconfig）。

**Reference**：見 Insight 2、Mechanism 6 Finding #D。

---

### H.3：`/usr/bin/ld: cannot find -lXYZ`

**Error 訊息**：
```
/usr/bin/ld: cannot find -lcrypto
collect2: error: ld returned 1 exit status
```

**為什麼**：linker 找不到 `libcrypto.so` 或 `libcrypto.a`。3 種可能：

1. **lib 沒裝進 sysroot**
   ```bash
   ls $SYSROOT/usr/lib/libcrypto.*
   ```
2. **路徑不在 -L 清單**
   ```bash
   cross-gcc -L/path/to/openssl/lib -lcrypto ...
   ```
3. **lib 是 host (Mac) 版、不能 link target (Linux)**
   ```bash
   file $SYSROOT/usr/lib/libcrypto.so
   # 應該看 ELF, x86-64 不是 Mach-O
   ```

**Reference**：附錄 G 的「system 清單來源」概念。

---

### H.4：binary `for GNU/Linux X.Y` 不對

**Error 訊息**：
```bash
$ ./hello
./hello: cannot execute binary file: Exec format error  # 或
./hello: This binary requires Linux 5.X or newer
```

**為什麼**：binary 內 `LC_BUILD_VERSION` 或 ELF note 寫的最低 kernel 比目標機器 kernel 新。

**修法**：
- 確認 cross-toolchain 的 `CT_LINUX_VERSION` 是 target 預期的 kernel
- 或用 `objcopy --remove-section=.note.ABI-tag` 強制移除 ABI tag (危險)

**Reference**：Mechanism 1 Step 8 (kernel headers)。

---

### H.5：`error: '__abi_tag__' attribute only applies to ...`

跟 Fix #9 相同。host compiler (Apple Clang 21) + libc++ 21 太新撞 GCC 11 source。**換 brew gcc-14 當 host**。

---

### H.6：`Don't set CC. It screws up the build.`

ct-ng 自己拒絕。**不要設 `CC` env var**，改用 PATH manipulation (wrapper symlink)。見 Fix #10。

---

### H.7：`cannot execute binary file: Exec format error` 跑 .o 檔

**Error 訊息**：
```bash
$ ./test
-bash: ./test: cannot execute binary file: Exec format error

$ file test
test: ELF 64-bit LSB relocatable, x86-64
              ↑↑↑↑↑↑↑↑↑↑↑
              是 .o 物件檔，不是 executable
```

**為什麼**：你大概用 `gcc -c test.cpp -o test`，`-c` 是「**只 compile 不 link**」，產出是 .o object 檔，沒 entry point。

**修法**：拿掉 `-c`。
```bash
gcc test.cpp -o test    # 沒 -c
file test
# ELF 64-bit LSB executable, ...   ← 對了
```

**Reference**：GCC `-c` flag：<https://gcc.gnu.org/onlinedocs/gcc/Overall-Options.html>。

---

### H.8：sparseimage 解 detach 不了 (`resource busy`)

**Error 訊息**：
```bash
$ hdiutil detach /Volumes/ct-x86_64-centos6
hdiutil: couldn't unmount "disk5" - 資源忙碌中
```

**為什麼**：有 process cwd 或開檔在 mount point 內。

**修法**：
```bash
# 找誰在用:
lsof /Volumes/ct-x86_64-centos6 2>/dev/null

# 多半是 shell cwd:
# 該 shell `cd ~/` 或關掉

# 或強制:
hdiutil detach -force /Volumes/ct-x86_64-centos6
```

**Reference**：`man 1 hdiutil`、`man 8 lsof`。

---

## 註腳 / 參考

[^1]: crosstool-NG 官方文件：<https://crosstool-ng.github.io/docs/>。Source repo: <https://github.com/crosstool-ng/crosstool-ng>。

[^2]: crosstool-NG configuration manual：<https://crosstool-ng.github.io/docs/configuration/>。BUILD/HOST/TARGET 詞義在 GNU Autoconf manual: <https://www.gnu.org/savannah-checkouts/gnu/autoconf/manual/autoconf-2.71/html_node/Specifying-Target-Triplets.html>。

[^3]: Ulrich Drepper "How To Write Shared Libraries"：<https://www.akkadia.org/drepper/dsohowto.pdf>。Section 3 描述 symbol-versioning。Drepper 是 2000-2010 glibc 維護者。

[^4]: `objdump -T` 印 dynamic symbol table；`grep -oE 'GLIBC_[0-9.]+'` 抽出版本標。GNU binutils 文件：<https://sourceware.org/binutils/docs/binutils/objdump.html>。

[^5]: ct-ng case-sensitive check 在 `scripts/functions` 的 `CT_TestAndAbort`：<https://github.com/crosstool-ng/crosstool-ng/blob/master/scripts/functions>。

[^6]: Apple File System Reference：<https://developer.apple.com/documentation/foundation/file_system/about_apple_file_system>。

[^7]: `man 1 hdiutil` (macOS)。`hdiutil create -type SPARSE` 產 sparse disk image。

[^8]: GCC libsanitizer：<https://gcc.gnu.org/wiki/AddressSanitizer>。需要 glibc 2.27+ 內部 symbol。

[^9]: AmanoTeam/obggcc：<https://github.com/AmanoTeam/obggcc>。Linux-host build 的 cross-toolchain 含 glibc 2.3-2.39 selectable sysroot。

[^10]: Bash reference manual `set` builtin：<https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html>。`pipefail` semantics 跟 `SIGPIPE`。

[^11]: messense/homebrew-macos-cross-toolchains x86_64-unknown-linux-gnu config：<https://github.com/messense/homebrew-macos-cross-toolchains/blob/main/x86_64-unknown-linux-gnu/.config>。我們參考它的 ct-ng 設定（不過他們 glibc 是 2.28、我們是 2.12）。

[^12]: Tetragon (Cilium) Makefile：<https://github.com/cilium/tetragon/blob/main/Makefile>。`CGO_ENABLED=0` 完全避 cgo。

[^13]: Tracee (Aqua) builder：<https://github.com/aquasecurity/tracee/blob/main/builder/Dockerfile.ubuntu-tracee-make>。

[^14]: Cilium builder image：<https://github.com/cilium/cilium/blob/main/images/builder/Dockerfile>。

[^15]: Elastic Beats `golang-crossbuild`：<https://github.com/elastic/golang-crossbuild/tree/main/go>。

[^16]: Parca-Agent + goreleaser-cross：<https://github.com/parca-dev/parca-agent/blob/main/Makefile>。

[^17]: Microsoft vscode-linux-build-agent ct-ng configs：<https://github.com/microsoft/vscode-linux-build-agent>。各 GCC + glibc 組合給舊企業相容。

[^18]: Rust dist-arm-linux-gnueabi defconfig：<https://github.com/rust-lang/rust/blob/master/src/ci/docker/host-x86_64/dist-arm-linux-gnueabi/arm-linux-gnueabi.defconfig>。savedefconfig 緊湊 style 範例。

[^19]: ct-ng Oracle Linux 9 sample：<https://github.com/crosstool-ng/crosstool-ng/blob/master/samples/aarch64-ol9u6-linux-gnu/crosstool.config>。提供 `-Wno-*` workaround 範例。

[^20]: ct-ng macOS OS setup page：<https://crosstool-ng.github.io/docs/os-setup/>。第一個該讀的文件。

[^21]: ct-ng job-flag 處理：`scripts/crosstool-NG.sh` 中 `CT_JOBSFLAGS`：<https://github.com/crosstool-ng/crosstool-ng/blob/master/scripts/crosstool-NG.sh>。

[^22]: ct-ng issue #1788 binutils PATH ordering：<https://github.com/crosstool-ng/crosstool-ng/issues/1788>。

[^23]: crosstool-NG macOS 不支援聲明 (2018-11-26)：<https://crosstool-ng.github.io/2018/11/26/macos.html>。

[^24]: messense Build CI workflow：<https://github.com/messense/homebrew-macos-cross-toolchains/blob/main/.github/workflows/Build.yml>。CI 只跑 macos-14/15，沒設 deployment target。

[^25]: `_FORTIFY_SOURCE` 文件：<https://sourceware.org/glibc/manual/2.40/html_node/Source-Fortification.html>。Apple SDK 把 strlcpy / memcpy 等 wrap 成 `__builtin___X_chk` 做安全檢查。

[^26]: GCC bootstrap process：<https://gcc.gnu.org/install/build.html>。3-stage bootstrap 模型解釋為什麼 gcc 要編 3 次。

[^27]: `objdump -T` vs `nm -D` 輸出格式差異。前者用 `(GLIBC_X.Y)` 括號標記、後者用 `@GLIBC_X.Y` 連字號。寫文件抄指令時搞混過一次。

---

*Document version: tested against crosstool-ng 1.25.0, GCC 11.2.0, glibc 2.12.1, macOS 26.x arm64, brew gcc 14.3.0 host. 2026-05-08 build verified successful.*
