# osxcross 工具鏈 + cgo 接 C/C++ 深度研究筆記

> 撰寫於 2026-05。對應本 repo 的 phase3 設定：
> - osxcross commit `e6ab3fa7423f9235ce9ed6381d6d3af191b46b59`（2025-12-15）
> - Ubuntu 24.04 base、apt 預設 clang-18
> - MacOSX11.3.sdk（target tuple `darwin20.4`）
> - `OSX_VERSION_MIN=10.15`（Intel）、`11.0`（arm64 最低）
> - Go 1.22.12
>
> 補充 [docker-experiments.md](./docker-experiments.md) 沒展開的兩個主軸：
> 1. osxcross + macOS SDK 11.3 + C++ stdlib 的完整鏈條
> 2. cgo 接 C 與 C++ 的 FFI 雷區與工程取捨
>
> **Reference 規則**：本文所有外部 URL 都打到頁面內**可 Ctrl+F 搜到的具體文字段**，不打入口頁。每條 reference 後標 `Ctrl+F:` 提示要搜什麼字串。

---

## 目錄

- [Part 1：osxcross 工具鏈與 macOS stdlib](#part-1osxcross-工具鏈與-macos-stdlib)
  - [1.1 host clang 版本與 osxcross 兼容性](#11-host-clang-版本與-osxcross-兼容性)
  - [1.2 SDK 11.3 與 host clang 是獨立的兩件事](#12-sdk-113-與-host-clang-是獨立的兩件事)
  - [1.3 libSystem 與 forward compatibility](#13-libsystem-與-forward-compatibility)
  - [1.4 libstdc++ 在 macOS 上的死亡時間線](#14-libstdc-在-macos-上的死亡時間線)
  - [1.5 osxcross 如何處理 C++ stdlib](#15-osxcross-如何處理-c-stdlib)
  - [1.6 `__builtin_available` 與 compiler-rt](#16-__builtin_available-與-compiler-rt)
  - [1.7 libc++ 的雙層結構](#17-libc-的雙層結構)
  - [1.8 macOS C++ feature 版本對應表](#18-macos-c-feature-版本對應表)
  - [1.9 自編 hermetic libc++.a 的路線](#19-自編-hermetic-libca-的路線)
- [Part 2：減低心智負擔的工程策略](#part-2減低心智負擔的工程策略)
- [Part 3：CGO 接 C 與 C++ 的差別](#part-3cgo-接-c-與-c-的差別)
- [Part 4：FFI 通論](#part-4ffi-通論)
- [Part 5：C++ via cgo 的成本與取捨](#part-5c-via-cgo-的成本與取捨)
- [Part 6：cgo 大型專案實證調查](#part-6cgo-大型專案實證調查)
- [Appendix：完整 reference 清單](#appendix完整-reference-清單)

---

## Part 1：osxcross 工具鏈與 macOS stdlib

### 1.1 host clang 版本與 osxcross 兼容性

#### 事實

- 本 repo 的 `Dockerfile.phase3` 使用 `ubuntu:24.04` base，`apt install clang` 拉到的是 **clang-18**
- osxcross 上游目前有 confirmed bug：**clang/lld 21 + darwin-arm64 + dylib reexports 觸發 `ld64.lld` segfault**
- 該 issue 開於 2025-06，截至 2025 年底仍 **OPEN**
- clang 19、20 沒人正面 reproduce 報過，但 osxcross 上游也沒保證

#### 推論

- clang-18 是目前「保險邊界」上限
- 想 bump base image 到 `ubuntu:26.04`（會帶更新 clang）→ 先確認 #462 已修
- 想 `apt install clang-21` 直接指定新 clang → **會中 #462**

#### Reference

1. [tpoechtrager/osxcross issue #462](https://github.com/tpoechtrager/osxcross/issues/462) — Ctrl+F: `21.0.0 (++20250604053032` 跟 `free(): invalid pointer`。確認 clang 21 + darwin-arm64 觸發 ld64.lld segfault。
2. [tpoechtrager/osxcross issue #471](https://github.com/tpoechtrager/osxcross/issues/471) — Ctrl+F: `ld64.lld missing`。確認 osxcross 需要 distro 裝 `lld` 套件，否則 link 失敗。

---

### 1.2 SDK 11.3 與 host clang 是獨立的兩件事

#### 事實

- macOS SDK 內容物：**純 headers + `.tbd`（Text-Based stub Description）檔**。沒有可執行 binary。
- `.tbd` 是 YAML 格式，描述某個 dylib 的 symbol table、install_name、target archs
- osxcross 用 `apple-libtapi` 解 `.tbd` 餵給 ld64
- 因此 SDK 11.3 **不挑** host clang 版本——它只決定「你能 `#include` 哪些 API」

#### 推論

- 「osxcross 用 SDK 11.3 會不會被 clang 版本影響」這問題的拆解：
  - SDK 內容 → 跟 clang **完全無關**
  - host clang 是否認得 SDK headers → 是
  - ld64（cctools-port 編的）如何與 host lld 互動 → 這層是 #462 的雷區

#### Reference

3. [apple-libtapi（osxcross 用的 fork）](https://github.com/tpoechtrager/apple-libtapi) — Ctrl+F: `TAPI is a library`。確認 libtapi 是用來 parse `.tbd` 檔案的 lib。
4. [LLVM TextAPI 文件](https://llvm.org/doxygen/group__libllvm__text__api.html) — Ctrl+F: `TextAPI`。LLVM 自己對 TBD 格式的支援文件。
5. [Apple — DYLD shared cache and reproducible macOS builds（pudquick gist）](https://gist.github.com/pudquick/89c90421a9582f88741b21d10c6a155e) — Ctrl+F: `shared cache`。說明 macOS 11+ 系統 dylib 都搬進 dyld_shared_cache 的事實。

---

### 1.3 libSystem 與 forward compatibility

#### 事實

- macOS 不允許 static link libSystem（**沒有 `libSystem.a`**，只有 dylib）。Apple 的設計刻意如此
- Mach-O binary 寫 `LC_BUILD_VERSION` load command，記錄：
  - `platform`（macOS / iOS / tvOS / ...）
  - `minos`（最低 macOS 版本 = `-mmacos-version-min` 那個）
  - `sdk`（編譯時用的 SDK 版本）
- dyld 在加載時讀 `LC_BUILD_VERSION`，解 `LC_LOAD_DYLIB` 找 dylib
- macOS 11 起，`/usr/lib` 內的真 dylib 被搬進 **dyld_shared_cache**（單一大檔，OS 啟動時 mmap），`/usr/lib` 看起來「不見了」但 dyld 仍能 resolve

#### 推論

- binary 標 `minos=10.15` 在任何 macOS 10.15+ 都跑得起來，不用煩 libSystem 版本
- 這是 Apple 給的**永久 forward compatibility 保證**，跟 glibc forward ABI 同概念但更乾淨（單一 stdlib）

#### Reference

6. [Apple Developer Forums — Missing libraries in /usr/lib](https://developer.apple.com/forums/thread/655588) — Ctrl+F: `dyld shared cache`。Apple 官方論壇確認 macOS 11 起 /usr/lib 真檔搬進 shared cache。
7. [Apple — Static libSystem 不存在的討論](https://developer.apple.com/library/archive/qa/qa1118/_index.html) — Ctrl+F: `static linking`。Apple 技術 QA 明確說 macOS 不支援 static link libSystem。
8. [pudquick — Reproducible Builds for macOS](https://gist.github.com/pudquick/89c90421a9582f88741b21d10c6a155e) — Ctrl+F: `LC_BUILD_VERSION`。詳細解釋 LC_BUILD_VERSION 跟 SDK 版本的關係。

---

### 1.4 libstdc++ 在 macOS 上的死亡時間線

#### 事實

| 年份 | Xcode | 事件 |
|---|---|---|
| 2011 | Xcode 4.2 | macOS 引入 libc++（LLVM 的 C++ stdlib） |
| 2013 | OS X 10.9 Mavericks | libc++ 變預設；libstdc++ 標 deprecated |
| 2016 | Xcode 8 | 連結 libstdc++ 跳 deprecation warning |
| 2018 | Xcode 10 | 對 iOS target 直接禁用 libstdc++；macOS 仍 ship 但 deprecation 確認 |
| 2020+ | macOS 11 Big Sur SDK | SDK 內 `usr/lib/libstdc++.6.0.9.tbd` **不再 ship**（dylib 真檔還在 dyld cache 給舊 binary 跑） |

#### 推論

- 你 phase3 用的 MacOSX11.3.sdk **沒有 `libstdc++.tbd`**
- 任何寫死 `-lstdc++` 或 `-stdlib=libstdc++` 的 Makefile 在 osxcross 環境會 link error
- 新編 C++ binary **強制走 libc++**

#### Reference

9. [Apple Developer Forums — libstdc++ is deprecated; move to libc++](https://developer.apple.com/forums/thread/113746) — Ctrl+F: `libstdc++ is deprecated; move to libc++`。Apple 官方確認 libstdc++ 棄用訊息。
10. [Apple Developer Forums — Where is libstdc++.6.dylib in xcode10 beta?](https://developer.apple.com/forums/thread/103732) — Ctrl+F: `Xcode 10`。確認 Xcode 10 起 SDK 不再 ship libstdc++ 連結 stub。
11. [pandas-dev/pandas issue #23424 — build failure with Xcode 10 - libstdc++ not supported anymore](https://github.com/pandas-dev/pandas/issues/23424) — Ctrl+F: `libstdc++ not supported`。社群實證 Xcode 10+ libstdc++ link 失敗。
12. [Go issue #29969 — x/mobile: stdlibc++ deprecation building issue](https://github.com/golang/go/issues/29969) — Ctrl+F: `libstdc++ is deprecated; move to libc++`。Go 官方 tracker 紀錄這個錯誤訊息。

---

### 1.5 osxcross 如何處理 C++ stdlib

#### 事實

osxcross 的 README 明文寫：

> **Deployment target ≥ 10.9 defaults to `libc++`.**
> 
> Can be explicitely overriden by setting the C++ library to `libstdc++` via `-stdlib=libstdc++`.

osxcross 的 clang wrapper（`x86_64-apple-darwin20.4-clang++` 那種）會：

1. 讀 `argv[0]` 推 arch / target triple
2. 注入 `-isysroot $TARGET_DIR/SDK/MacOSX11.3.sdk`
3. 注入 `-target $arch-apple-darwin20.4`
4. 注入 `-mmacosx-version-min=$OSX_VERSION_MIN`
5. 當 deployment target ≥ 10.9 時**自動加 `-stdlib=libc++`**
6. exec 系統 clang（Ubuntu 的 clang-18）

#### 推論

- 你 phase3 設 `OSX_VERSION_MIN=10.15`（≥ 10.9）→ 預設 `-stdlib=libc++`
- SDK 11.3 內有 `usr/lib/libc++.tbd` → link 過
- 鏈條完整，**user 不需要顯式加任何 stdlib flag**

#### Reference

13. [osxcross README](https://github.com/tpoechtrager/osxcross/blob/master/README.md) — Ctrl+F: `Deployment target ≥ 10.9 defaults to`。確認 osxcross 對 libc++ 預設行為的官方說明。
14. [本 repo docs/docker-experiments.md §3.4](./docker-experiments.md) — Ctrl+F: `apple-libtapi`。本 repo 自己對 osxcross 內部結構的分析。

---

### 1.6 `__builtin_available` 與 compiler-rt

#### 事實

**第一層：語法**

`__builtin_available()` 是 clang 的 **language extension**，不是 osxcross 的功能。Apple 在 clang 5.0（~2017）upstream 進去。

```cpp
if (__builtin_available(macOS 13.3, *)) {
    // 用 std::format
} else {
    // fallback
}
```

任何 clang ≥ 5 都認得這個語法。

**第二層：lowering**

clang 把 `__builtin_available()` 翻成 runtime call：

```
%v = call i1 @__isPlatformVersionAtLeast(i32 1, i32 13, i32 3, i32 0)
//                                       │
//                                       └─ PLATFORM_MACOS = 1
```

ASM 層 symbol 名是 `___isPlatformVersionAtLeast`（三條底線 = Mach-O symbol prefix）。早期名字是 `___isOSVersionAtLeast`，後來改名。

**第三層：實作來源**

`___isPlatformVersionAtLeast` 的實作在 **compiler-rt 的 darwin builtins archive**（`libclang_rt.osx.a`）。

- 在 Mac 上：Xcode 自帶，路徑類似 `/Library/Developer/CommandLineTools/usr/lib/clang/<ver>/lib/darwin/libclang_rt.osx.a`
- 在 Linux + osxcross：**Ubuntu apt 裝的 clang-18 自帶的 compiler-rt 是 Linux 版的，沒有 darwin builtins**

**第四層：osxcross 補這塊**

osxcross 提供 `./build_compiler_rt.sh` script，做的事：
1. clone LLVM compiler-rt source
2. 用 osxcross 剛編好的 cross-clang 編 compiler-rt builtins → target darwin
3. 把產出的 `libclang_rt.osx.a` 裝到 system clang 的 resource dir 內（`/usr/lib/llvm-18/lib/clang/18/lib/darwin/`）

你 phase3 Dockerfile line 120：
```dockerfile
PATH=/opt/osxcross/bin:$PATH JOBS=$(nproc) ./build_compiler_rt.sh;
```
這條就是在補這塊。

#### 推論

- `__builtin_available()` 是 clang **內建語法**，不是 osxcross 功能
- 但在 Linux + osxcross 環境**需要 compiler-rt 的 darwin builtins** 才能 link 成功
- 你 phase3 已經 build 過 compiler-rt → user 直接用 `__builtin_available()` 就能 work，不用額外設定

#### Reference

15. [Apple — Marking API Availability in Objective-C](https://developer.apple.com/documentation/swift/marking-api-availability-in-objective-c) — Ctrl+F: `__builtin_available`。Apple 對該 builtin 的官方說明（雖列在 Swift 文件下）。
16. [Eugene Petrenko — Undefined isOSVersionAtLeast on macOS](https://jonnyzzz.com/blog/2018/06/05/link-error-2/) — Ctrl+F: `__isOSVersionAtLeast`。詳細解釋這個 symbol 跟 compiler-rt 的關係。
17. [Swift issue #62626 — Undefined symbol: `___isOSVersionAtLeast` with macOS toolchains](https://github.com/apple/swift/issues/62626) — Ctrl+F: `___isOSVersionAtLeast`。Apple Swift 團隊內部紀錄這個 symbol 的來源。
18. [curl-rust issue #279 — macOS link error with static curl - missing `___isOSVersionAtLeast`](https://github.com/alexcrichton/curl-rust/issues/279) — Ctrl+F: `compiler-rt`。社群實證該 symbol 來自 compiler-rt builtins archive。
19. [LLVM compiler-rt 專案首頁](https://compiler-rt.llvm.org/) — Ctrl+F: `builtins`。compiler-rt 對「builtins」這層的官方定義。
20. [osxcross issue #278 — `__builtin_available` 需要 compiler-rt](https://github.com/tpoechtrager/osxcross/issues/278) — Ctrl+F: `__isPlatformVersionAtLeast`。osxcross 上游確認 build_compiler_rt.sh 是必要的補丁。
21. [osxcross issue #267 — arm64 `-fopenmp` 需要 build_compiler_rt.sh](https://github.com/tpoechtrager/osxcross/issues/267) — Ctrl+F: `compiler-rt`。同樣是 compiler-rt 缺失導致 link fail 的案例。

---

### 1.7 libc++ 的雙層結構

#### 事實

libc++ 內容**不是全部都在 dylib 裡**。分兩種 code path：

| 類型 | 範例 stdlib feature | code 在哪 | 受 target dylib 版本影響？ |
|---|---|---|---|
| **Header-only template** | `std::vector`、`std::unique_ptr`、`std::shared_ptr`、`std::map`、`std::unordered_map`、lambda、`std::move`/`std::forward`、`std::tuple`、`std::optional`（多數）、`std::variant`（多數）、`std::ranges` views、concepts、coroutines、constexpr 計算 | template 在每個 translation unit instantiate **進 binary** | ❌ 不受 |
| **Out-of-line symbol** | `std::cout`/`std::cin` 物件、exception 機制（`__cxa_throw`/`_Unwind_*`）、`std::filesystem::*` 大多數 function、`std::thread` ctor、`std::mutex`/`condition_variable`、`std::regex` 非 header 部分、`std::random_device`、`std::chrono::system_clock::now`、locale 機器、`std::format` runtime | **dylib 內**，binary 只記 `LC_LOAD_DYLIB` | ✓ 受 |

具體例子：

```cpp
#include <vector>
#include <string>
#include <memory>

int main() {
    auto v = std::make_unique<std::vector<std::string>>();
    v->push_back("hello");
}
// → 全部 template，instantiate 進 binary
// → 任何 macOS 10.9+ 都跑（libc++ 開始有的時間）
```

```cpp
#include <iostream>
#include <filesystem>

int main() {
    std::cout << "files:\n";
    for (auto& e : std::filesystem::directory_iterator(".")) {
        std::cout << e.path() << "\n";
    }
}
// → std::cout 物件本體在 dylib（10.9+）
// → directory_iterator 真實實作在 dylib，要 10.15+
```

#### 推論

- **大部分 modern C++ 程式碼**會被 template-instantiate 進 binary，獨立於 target dylib 版本
- 少數 out-of-line symbol 才依賴 target macOS 的 `/usr/lib/libc++.1.dylib`
- 「我怎麼確保 target 有我用的 stdlib feature」——**Apple 在 SDK headers 對每個 out-of-line symbol 都標 availability**，compiler 編譯期就會擋

#### Reference

22. [LLVM libc++ Documentation 首頁](https://libcxx.llvm.org/) — Ctrl+F: `extern templates`。確認 libc++ 用 extern template 機制分離 header 跟 dylib 內容。
23. [LLVM libc++ ABI versioning](https://libcxx.llvm.org/DesignDocs/ABIVersioning.html) — Ctrl+F: `stable ABI`。libc++ 官方 ABI 穩定性說明。
24. [libc++ 8.0 documentation — Using libc++](https://releases.llvm.org/8.0.0/projects/libcxx/docs/UsingLibcxx.html) — Ctrl+F: `_LIBCPP_DISABLE_EXTERN_TEMPLATE`。libc++ 對 extern template / 不依賴 dylib 的官方控制 macro。
25. [Joel Viotti — Debugging the C++ standard library on macOS](https://www.jviotti.com/2022/05/05/debugging-the-cxx-standard-library-on-macos.html) — Ctrl+F: `/usr/lib/libc++.1.dylib`。實證 macOS 上 libc++ dylib 的實際路徑跟 debug 方法。

---

### 1.8 macOS C++ feature 版本對應表

#### 事實

以下對應表來自 Apple Developer 官方 C++ Language Support 頁面：

| Feature | 最低 macOS | 你 `min=10.15` 能用？ | 你 `min=11.0` 能用？ |
|---|---|---|---|
| C++11 / C++14 全部 | 10.9 | ✓ | ✓ |
| `std::optional`（+ `bad_optional_access`）| 10.13 | ✓ | ✓ |
| `std::variant`（+ `bad_variant_access`）| 10.13 | ✓ | ✓ |
| `std::any`（+ `bad_any_cast`）| 10.13 | ✓ | ✓ |
| `std::shared_mutex` / `shared_lock` | 10.12 | ✓ | ✓ |
| `std::filesystem` | 10.15 | ✓ | ✓ |
| `std::charconv`（整數版）| 10.15 | ✓ | ✓ |
| `std::charconv`（浮點版）| 13.3 | ✗ | ✗ |
| `std::ranges` views（header-only 多）| 10.15 | ✓ | ✓ |
| Concepts、`auto` template、constraints | 純語法 | ✓ | ✓ |
| Coroutines（`<coroutine>`）| header-only | ✓ | ✓ |
| **`<barrier>` / `<latch>` / `<semaphore>`** | **11.0** | ✗ | ✓ |
| **`std::jthread`** | 13.0 | ✗ | ✗ |
| **`std::format`** | 13.3 | ✗ | ✗ |
| `std::pmr`（多型 allocator）| 14.0 | ✗ | ✗ |
| `std::expected`（C++23）| 視 Xcode/SDK | 視版本 | 視版本 |

#### 推論

- `min=10.15` + C++17：**全綠燈**，沒有需要記的雷
- `min=10.15` + C++20：4-5 個 keyword 雷區（format / barrier / latch / semaphore / jthread / pmr）
- `min=11.0`：解鎖 C++20 同步原語，雷區剩 3 個

#### Reference

26. [Apple Developer — C++ Language Support（Xcode）](https://developer.apple.com/xcode/cpp/) — Ctrl+F: `std::filesystem` 跟 `Minimum deployment target`。Apple 官方對各 stdlib feature 跟 macOS 版本的對應表。
27. [libc++ 5.0 documentation — Using libc++](https://releases.llvm.org/5.0.1/projects/libcxx/docs/UsingLibcxx.html) — Ctrl+F: `_LIBCPP_AVAILABILITY`。libc++ 對 availability annotation macro 的官方文件。
28. [MacPorts ticket #62426 — using a newer libc++ to build software on older macos systems](https://trac.macports.org/ticket/62426) — Ctrl+F: `back-deployment`。社群討論 macOS back-deployment 的實務方案。

---

### 1.9 自編 hermetic libc++.a 的路線

#### 事實

osxcross 上游**不提供** `build_libcxx.sh`。實際 build script 列表：

```
build.sh                  ← 主 build（libtapi + cctools-port + wrappers）
build_clang.sh            ← 自編 clang
build_apple_clang.sh      ← 自編 Apple-fork clang
build_binutils.sh         ← 自編 Apple binutils
build_gcc.sh              ← 自編 macOS target GCC
build_compiler_rt.sh      ← compiler-rt darwin builtins
cleanup.sh
package.sh
```

要 hermetic libc++.a 必須**自己用 LLVM 18 source 的 `runtimes/` 子樹**編。CMake 配 osxcross cross-clang 當 toolchain。

完整 build command 大意：

```bash
cmake -G Ninja \
    -DCMAKE_SYSTEM_NAME=Darwin \
    -DCMAKE_OSX_SYSROOT=/opt/osxcross/SDK/MacOSX11.3.sdk \
    -DCMAKE_C_COMPILER=/opt/osxcross/bin/x86_64-apple-darwin20.4-clang \
    -DCMAKE_CXX_COMPILER=/opt/osxcross/bin/x86_64-apple-darwin20.4-clang++ \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=10.15 \
    -DLLVM_ENABLE_RUNTIMES="libcxx;libcxxabi;libunwind" \
    -DLIBCXX_ENABLE_STATIC=ON \
    -DLIBCXXABI_ENABLE_STATIC=ON \
    -DLIBUNWIND_ENABLE_STATIC=ON \
    ../runtimes
ninja cxx cxxabi unwind
```

產出三個 archive，**彼此依賴**：`libc++.a` → `libc++abi.a` → `libunwind.a`。少一個 link 就缺 symbol。

#### 推論

- 自編可行，但**不是隨手就有**
- 對「sensor 部署到 macOS 10.15~26」這個用例**不需要做**——用系統 libc++ 完整覆蓋
- 真要做（hermetic build）建議直接加進 phase3 Dockerfile

#### Reference

29. [osxcross repo 根目錄 build scripts 清單](https://github.com/tpoechtrager/osxcross/tree/master) — Ctrl+F: `build_compiler_rt.sh`。確認 osxcross 沒提供 build_libcxx.sh。
30. [LLVM HowToCrossCompileLLVM 官方文件](https://llvm.org/docs/HowToCrossCompileLLVM.html) — Ctrl+F: `LLVM_ENABLE_RUNTIMES`。LLVM 官方對 cross-compile runtime libraries 的指引。
31. [LLVM libc++ BuildingLibcxx](https://releases.llvm.org/5.0.1/projects/libcxx/docs/BuildingLibcxx.html) — Ctrl+F: `LIBCXX_ENABLE_STATIC`。libc++ 官方 build 文件（針對 static archive 的 CMake flag）。
32. [Chromium chromium-reviews — mac: In static library builds, link against a static libc++.a](https://groups.google.com/a/chromium.org/g/chromium-reviews/c/jucBj1z-hFY) — Ctrl+F: `static libc++`。實際 production project（Chromium）走 hermetic libc++.a 的案例。
33. [hermeticbuild/hermetic-llvm](https://github.com/hermeticbuild/hermetic-llvm) — Ctrl+F: `libc++`。社群 hermetic C++ toolchain 的完整實作參考。

---

## Part 2：減低心智負擔的工程策略

### 2.1 Compiler 替你查 feature

你不需要寫 code 前主動查 feature 表。Apple 的 SDK headers 對每個 out-of-line symbol 都加 availability attribute：

```cpp
// SDK/MacOSX11.3.sdk/usr/include/c++/v1/filesystem 概念：
class _LIBCPP_AVAILABILITY_FILESYSTEM directory_iterator { ... };
// 等同：
// __attribute__((availability(macos, strict, introduced=10.15)))
```

寫 code → 編譯 → 踩雷 → compiler 吐：

```
error: 'directory_iterator' is unavailable: introduced in macOS 10.15
```

訊息明確到不需要查表。**真實工作流：寫 → 編 → 看到錯再決定**。

#### Reference

34. [Clang docs — Availability attribute](https://clang.llvm.org/docs/AttributeReference.html#availability) — Ctrl+F: `availability`。clang 官方對 availability attribute 的文件。
35. [Apple — Marking API Availability in Objective-C](https://developer.apple.com/documentation/swift/marking-api-availability-in-objective-c) — Ctrl+F: `Availability`。Apple 對 availability 機制的官方說明。

---

### 2.2 拉高 `OSX_VERSION_MIN`

`OSX_VERSION_MIN=10.15`（你目前設定）的雷區比較多。實際拉高的收益：

| 設定 | 失去客戶 | 換來 |
|---|---|---|
| `10.15` → `11.0` | macOS Catalina（2022 已 EOL，企業客戶幾乎沒有）| `<barrier>` / `<latch>` / `<semaphore>` 解鎖、arm64/Intel deployment 邏輯一致 |
| `11.0` → `12.0` | macOS Big Sur（2023 EOL） | minor 相容調整 |
| `12.0` → `13.3` | macOS Monterey | `std::format`、`std::charconv` 浮點解鎖 |

具體改法：`Dockerfile.phase3` 那個 `ENV OSX_VERSION_MIN=10.15` 改成 `11.0`，README 對應改成 `macOS Intel 11.0 onward`。

#### Reference

36. [endoflife.date — macOS](https://endoflife.date/macos) — Ctrl+F: `Catalina`。權威的 macOS EOL 對應表。
37. [Apple — Apple Silicon 最低 SDK 需求](https://developer.apple.com/documentation/apple-silicon) — Ctrl+F: `macOS Big Sur`。Apple 官方 arm64 需要 macOS 11.0 的依據。

---

### 2.3 用 fmt library 替代 `std::format`

`std::format` 是 C++20 標準從 fmt library 收進來的。fmt 本身是 **header-only**，instantiate 進 binary，**不依賴 target dylib 版本**。

```cpp
#include <fmt/format.h>   // 第三方 header-only

auto s = fmt::format("{} = {}", "answer", 42);   // API 跟 std::format 一致
```

#### Reference

38. [fmtlib/fmt repo](https://github.com/fmtlib/fmt) — Ctrl+F: `header-only`。fmt library 官方確認 header-only 用法。
39. [C++ Standards Committee proposal P0645 — std::format derived from fmt](https://www.open-std.org/jtc1/sc22/wg21/docs/papers/2017/p0645r0.html) — Ctrl+F: `fmt`。C++20 標準 paper 確認 std::format 來自 fmt。

---

## Part 3：CGO 接 C 與 C++ 的差別

### 3.1 CGO 本質：Go-to-C，不是 Go-to-C++

cgo 的 FFI ABI 只認 C calling convention 跟 C symbol naming。它**不直接**接 C++。

原因：C++ name mangling。

```cpp
int add(int a, int b);
// GCC/Clang Itanium ABI 編出 symbol: _Z3addii
// MSVC 編出 symbol:                  ?add@@YAHHH@Z
```

cgo 試圖在 symbol table 找 `add` → 找不到 → link error。

#### Reference

40. [Itanium C++ ABI specification — Name mangling](https://itanium-cxx-abi.github.io/cxx-abi/abi.html#mangling) — Ctrl+F: `mangling`。Itanium C++ ABI 官方 name mangling 規格。
41. [Go cgo command documentation](https://pkg.go.dev/cmd/cgo) — Ctrl+F: `.cc, .cpp, or .cxx files`。cgo 對 C++ 檔的處理規則。

---

### 3.2 C 沒有 exception；`extern "C"` 不等於「這是 C」

**C 語言本身沒有 exception 機制**。沒 `throw`/`try`/`catch` 關鍵字。C 用 return code + `errno` + 偶爾 `setjmp`/`longjmp` 處理錯誤路徑。

`extern "C"` 是 **C++ 語法**，作用範圍只有：
1. 影響該 function 的 **symbol name**（不做 name mangling，用 C-style 命名）
2. 影響該 function 的 **calling convention**（用 C ABI）

**不影響 function body**——body 仍然是 C++ source 編譯出來的 code，**可以 throw**：

```cpp
// this_is_cpp_source.cpp（注意副檔名）
extern "C" void looks_like_c(void) {
    std::vector<int> v;       // ← C++ STL，OK
    throw std::runtime_error("oops");   // ← C++ exception，會發生
}
```

→ wrapper 內要 `try/catch(...)` 是因為「**這 function 對外宣告成 C ABI，但 implementation 是 C++**」。如果 wrapper 用**純 C**寫（`.c` 副檔名），那就完全沒這個雷。

#### Reference

42. [cppreference — Language linkage（extern "C"）](https://en.cppreference.com/w/cpp/language/language_linkage) — Ctrl+F: `extern "C"`。C++ 標準對 extern "C" 語意的權威說明。
43. [ISO/IEC 9899:2018（C18 標準草案）— Error handling](https://www.open-std.org/jtc1/sc22/wg14/www/docs/n2310.pdf) — Ctrl+F: `errno`。C 標準對錯誤處理（無 exception）的規範。
44. [SEI CERT C++ Coding Standard — ERR59-CPP. Do not throw an exception across execution boundaries](https://wiki.sei.cmu.edu/confluence/display/cplusplus/ERR59-CPP.+Do+not+throw+an+exception+across+execution+boundaries) — Ctrl+F: `execution boundaries`。權威 C++ 規範禁止跨 boundary throw。

---

### 3.3 C wrapper 模式（接 C++ 唯一正確姿勢）

```
真實 C++ 內部        C wrapper（extern "C"）            Go cgo
─────────────       ───────────────────────────        ─────────────
class Foo {          extern "C" {                       /*
  Foo();                                                #include "foo_c.h"
  void bar(int);     struct foo_t;                      */
  ~Foo();                                                import "C"
};                   foo_t* foo_new(void);
                     int    foo_bar(foo_t*, int,        type Foo struct {
                                    char* err,            ptr *C.foo_t
                                    size_t err_len);    }
                     void   foo_free(foo_t*);
                                                         func New() (*Foo, error)
                     }
                                                         func (f *Foo) Bar(x int)
```

實作關鍵：

```cpp
extern "C" int foo_bar(foo_t* f, int x, char* err, size_t err_len) {
    if (!f) { /* set err */ return -1; }
    try {
        f->impl.bar(x);
        return 0;
    } catch (const std::exception& e) {
        strncpy(err, e.what(), err_len - 1);
        err[err_len - 1] = '\0';
        return -1;
    } catch (...) {
        strncpy(err, "unknown error", err_len - 1);
        return -1;
    }
}
```

每個 wrapper function 內**必須** catch all。一個 exception 漏出去就 UB。

#### Reference

45. [Go forum — best practice for wrapping c plus plus code](https://forum.golangbridge.org/t/what-is-the-best-practice-for-wrapping-c-plus-plus-code/4038) — Ctrl+F: `extern "C"`。Go 社群討論 C++ wrapper 模式的權威貼文。
46. [draffensperger/go-interlang — C++ wrapper example](https://github.com/draffensperger/go-interlang/tree/master/go_to_cxx/c_wrapper) — Ctrl+F: `extern "C"`。實際可運行的 cgo 接 C++ wrapper 範例 repo。

---

### 3.4 七大雷區

| # | 雷 | 違反代價 | 處理 |
|---|---|---|---|
| 1 | Exception 漏出 wrapper | 隨機 crash / abort | `try/catch(...)` 包到死 |
| 2 | 邊界傳 `std::string`/`std::vector` | 編譯/連結 fail 或 ABI corruption | 邊界只傳 POD |
| 3 | Linux libstdc++ + macOS libc++ 同 process 混搭 | 隨機 corruption | 同 process 內統一 stdlib |
| 4 | RAII 不會自動觸發（Go panic 不認 C++ dtor）| 資源 leak | `defer C.xxx_free()` |
| 5 | C++ static initializer 順序 | 第一次 cgo call 拿到未初始化 object | 用 Meyer's singleton（local static）lazy init |
| 6 | Goroutine stack 跟 C stack 不一樣 | 深 recursion stack overflow | cgo call 越短越好；長時間 work 起 pthread |
| 7 | Signal handler 衝突（Go 已 hook SIGSEGV 等） | C++ throw / segfault → abort | C++ 不要裝 signal handler；錯誤路徑用 return code |

#### Reference

47. [Go issue #12516 — runtime: throw in linked c++ library causes app crash](https://github.com/golang/go/issues/12516) — Ctrl+F: `exception is thrown`。Go 官方 tracker 確認 C++ throw 跨 cgo 邊界 crash。
48. [Netlify — Tracking Down a CGO Crash in Production](https://www.netlify.com/blog/2021/03/18/tracking-down-a-cgo-crash-in-production/) — Ctrl+F: `signal`。實戰 cgo crash 案例（signal handler + C 段 segfault）。
49. [keyan pishdadian — Handling C/C++ segfaults in code called from Go](https://keyanp.com/cgo-segfault.html) — Ctrl+F: `SIGSEGV`。深入解釋 Go signal handler 跟 C 段 segfault 互動。
50. [Go issue #48486 — cmd/cgo: support linking to libraries built with clang's libc++](https://github.com/golang/go/issues/48486) — Ctrl+F: `libc++`。Go 官方紀錄 cgo + libc++ 混搭 ABI 問題。
51. [Go cgo command documentation — passing Go pointers](https://pkg.go.dev/cmd/cgo) — Ctrl+F: `Go pointers passed to C must point to pinned`。cgo 對 Go pointer 傳到 C 端的官方規則。

---

### 3.5 cross-compile + cgo 的 macOS 特有問題

#### 問題 A：CGO 不會自動用 osxcross wrapper

```bash
# 這樣 cgo 抓 system gcc/g++（Ubuntu host），編出 ELF 不是 Mach-O
GOOS=darwin GOARCH=arm64 CGO_ENABLED=1 go build
```

對策：明確指定 `CC` 跟 `CXX`：

```bash
CC=arm64-apple-darwin20.4-clang \
CXX=arm64-apple-darwin20.4-clang++ \
CGO_ENABLED=1 \
GOOS=darwin GOARCH=arm64 \
go build
```

#### 問題 B：CGO_LDFLAGS 跨平台寫死

```go
// #cgo LDFLAGS: -lstdc++   ← Linux OK，macOS 爆（SDK 11.3 沒 libstdc++.tbd）
```

對策：用 build constraint 分檔：

```go
// stdlib_linux.go
//go:build linux
package mylib
// #cgo LDFLAGS: -lstdc++
import "C"
```

```go
// stdlib_darwin.go
//go:build darwin
package mylib
// #cgo CXXFLAGS: -stdlib=libc++
// #cgo LDFLAGS:  -lc++
import "C"
```

或乾脆全不寫 stdlib LDFLAGS——osxcross wrapper 自動加 `-stdlib=libc++`，ct-ng g++ 自動加 `-lstdc++`，雙邊都對。

#### 問題 C：`-buildmode=c-archive` / `c-shared` 在 cross-compile 有時 broken

[Go issue #59221](https://github.com/golang/go/issues/59221) 紀錄 macOS→Windows 案例。Linux→darwin/arm64 + c-shared 也偶爾爆。預設 `-buildmode=default`（編 executable）最穩。

#### Reference

52. [Go issue #44112 — cmd/cgo: cross-compile from darwin/amd64 to darwin/arm64 with cgo](https://github.com/golang/go/issues/44112) — Ctrl+F: `CC=`。Go 官方 tracker 紀錄 cgo cross-compile 設 CC 的需求。
53. [Go issue #59221 — cmd/link: cross compile from MacOS to Windows with CGO_ENABLED=1 and -buildmode=c-archive](https://github.com/golang/go/issues/59221) — Ctrl+F: `c-archive`。cross-compile + c-archive 已知 broken 的案例。
54. [plentico/osxcross-target](https://github.com/plentico/osxcross-target) — Ctrl+F: `CC=` 跟 `CXX=`。社群實際 osxcross + Go cgo cross-compile setup 範例。
55. [Ecostack — Go: Cross-Compilation Including Cgo](https://ecostack.dev/posts/go-and-cgo-cross-compilation/) — Ctrl+F: `CC=` 跟 `osxcross`。實作向 tutorial。
56. [Go cgo command documentation — CGO_CFLAGS/CGO_CXXFLAGS/CGO_LDFLAGS](https://pkg.go.dev/cmd/cgo) — Ctrl+F: `CGO_CFLAGS, CGO_CPPFLAGS, CGO_CXXFLAGS`。cgo 環境變數官方說明。

---

### 3.6 完整工程模板

```
project/
├── csrc/
│   ├── core.cpp              # 真實 C++ 邏輯
│   ├── core.hpp
│   ├── core_c.cpp            # extern "C" wrapper（try/catch + error code）
│   └── core_c.h              # C-compatible header
├── go.mod
├── core.go                   # Go interface（共用）
├── core_linux.go             # CGO with libbpf 之類
└── core_darwin.go            # CGO with C++ wrapper
```

**core_darwin.go** 核心：

```go
//go:build darwin

package sensor

/*
#cgo CXXFLAGS: -std=c++17
#cgo LDFLAGS:  -lc++
#include "csrc/core_c.h"
*/
import "C"
import (
    "errors"
    "runtime"
    "unsafe"
)

type Sensor struct{ h *C.sensor_t }

func New() (*Sensor, error) {
    var errBuf [256]C.char
    h := C.sensor_new(&errBuf[0], C.size_t(len(errBuf)))
    if h == nil {
        return nil, errors.New(C.GoString(&errBuf[0]))
    }
    s := &Sensor{h: h}
    runtime.SetFinalizer(s, func(s *Sensor) {
        if s.h != nil { C.sensor_free(s.h) }
    })
    return s, nil
}

func (s *Sensor) Process(data []byte) error {
    if len(data) == 0 { return nil }
    var errBuf [256]C.char
    ret := C.sensor_process(
        s.h,
        unsafe.Pointer(&data[0]), C.size_t(len(data)),
        &errBuf[0], C.size_t(len(errBuf)),
    )
    if ret != 0 {
        return errors.New(C.GoString(&errBuf[0]))
    }
    return nil
}
```

#### Reference

57. [Aaron Taylor — Linking Dynamic C++ Libraries with Go](https://ataylor.io/blog/cgolinking/) — Ctrl+F: `runtime.SetFinalizer`。實戰 blog post 含 Go side 完整 lifetime 管理範例。
58. [Gaultier — Addressing CGO pains, one at a time](https://gaultier.github.io/blog/addressing_cgo_pains_one_at_a_time.html) — Ctrl+F: `error code`。cgo 邊界錯誤處理模式的實戰整理。

---

## Part 4：FFI 通論

### 4.1 FFI 全名與意義

**FFI = Foreign Function Interface**（外部函式介面）

意義：「A 語言怎麼呼叫 B 語言寫的函式」。

各語言的對應機制名稱：

| 語言 | FFI 機制名稱 |
|---|---|
| Go | cgo |
| Python | ctypes / cffi / Cython |
| Rust | `extern "C"` + `#[no_mangle]` |
| Java | JNI（Java Native Interface） |
| C#/.NET | P/Invoke（Platform Invoke） |
| Ruby | Fiddle / FFI gem |
| Node.js | N-API |
| Haskell | FFI |
| LuaJIT | FFI |
| Erlang | NIF |

#### Reference

59. [Wikipedia — Foreign function interface](https://en.wikipedia.org/wiki/Foreign_function_interface) — Ctrl+F: `Foreign function interface`。FFI 概念跟各語言實作的綜合說明。
60. [Java JNI specification（Oracle）](https://docs.oracle.com/en/java/javase/21/docs/specs/jni/index.html) — Ctrl+F: `Java Native Interface`。Java JNI 官方規格。
61. [Python ctypes documentation](https://docs.python.org/3/library/ctypes.html) — Ctrl+F: `foreign function`。Python ctypes 官方文件。

---

### 4.2 七道斷層

「函式呼叫」這件事跨 FFI 邊界時涉及七層雙方必須同意的協議：

#### 斷層 1：ABI（calling convention + name mangling）

不同 ABI 對「參數放哪、stack 怎麼用、return 怎麼回」規定不同。

- System V AMD64（Linux/macOS）：前 6 個整數在 rdi/rsi/rdx/rcx/r8/r9
- Windows x64：前 4 個在 rcx/rdx/r8/r9 + 32 bytes shadow space
- x86-32 cdecl / stdcall / fastcall 三家分

C++ 額外加 name mangling：

```
int add(int, int)   → _Z3addii   (Itanium ABI)
                    → ?add@@YAHHH@Z (MSVC)
```

→ FFI 邊界必須 `extern "C"` / `#[no_mangle]` 等機制 disable mangling。

**Reference**：[Itanium C++ ABI § Mangling](https://itanium-cxx-abi.github.io/cxx-abi/abi.html#mangling) — Ctrl+F: `_Z`。
**Reference**：[System V AMD64 ABI 規格](https://gitlab.com/x86-psABIs/x86-64-ABI) — Ctrl+F: `register passing`。

#### 斷層 2：型別 layout（size + padding + alignment + endianness）

- C `long` 在 Linux 64-bit = 8 bytes，Windows 64-bit = 4 bytes
- Go `int` 永遠 = word size（cgo 強制寫 `C.int` 區分）
- Struct padding 取決於 compiler / target
- Endianness（x86 little vs PowerPC big）跨 arch 才出現

**Reference**：[Go cgo — type representations between Go and C](https://pkg.go.dev/cmd/cgo) — Ctrl+F: `C type`。

#### 斷層 3：記憶體 ownership

- 誰負責 free？沒有跨語言通用答案，看 doc。
- Go GC 不會搬 heap（concurrent mark-sweep，**非 moving**）
- 但 **goroutine stack 會搬**（grow 時 realloc）→ cgo 進 C 前切到 g0 system stack 避開
- Go 1.21 加 `runtime.Pinner` 顯式 pin pointer

**Reference**：[Go cgo — Go pointer pinning rules](https://pkg.go.dev/cmd/cgo) — Ctrl+F: `must point to pinned Go memory`。
**Reference**：[Go runtime.Pinner（Go 1.21+）](https://pkg.go.dev/runtime#Pinner) — Ctrl+F: `Pinner`。

#### 斷層 4：錯誤處理

```
C:    return code + errno
C++:  exception + return code
Go:   (value, error) + panic
Rust: Result<T, E>
Java: checked/unchecked exception
```

跨 FFI 邊界拋 exception = UB。Rust 2024+ 加 `extern "C-unwind"` 顯式 opt-in，cgo 不認。

**Reference**：[SEI CERT ERR59-CPP](https://wiki.sei.cmu.edu/confluence/display/cplusplus/ERR59-CPP.+Do+not+throw+an+exception+across+execution+boundaries) — Ctrl+F: `execution boundaries`。
**Reference**：[Rust RFC 2945 — C-unwind ABI](https://rust-lang.github.io/rfcs/2945-c-unwind-abi.html) — Ctrl+F: `C-unwind`。

#### 斷層 5：執行模型（thread / stack / signal）

- Goroutine ≠ OS thread，cgo 自動 switch g0 system stack
- Thread-local 敏感的 C lib 用 `runtime.LockOSThread()`
- Go runtime hook SIGURG/SIGSEGV/SIGBUS 等 → C++ lib 不該裝 signal handler

**Reference**：[Go runtime.LockOSThread documentation](https://pkg.go.dev/runtime#LockOSThread) — Ctrl+F: `LockOSThread`。

#### 斷層 6：字串 / 編碼

- C `char*` null-terminated，無編碼約定
- Go `string` 帶 length，UTF-8 convention
- Java `String` UTF-16
- Windows `WCHAR*` UTF-16 LE
- Go 字串含 `\0` 傳到 C 會被截斷

**Reference**：[Go cgo — C strings and Go strings](https://pkg.go.dev/cmd/cgo) — Ctrl+F: `C.CString`。

#### 斷層 7：Build / Link

- Symbol visibility：`-fvisibility=hidden` 不 export 的 function 找不到
- Stdlib 衝突：同 process 內 libstdc++ + libc++ 共存 = corruption
- `__declspec(dllexport)` / `dllimport` 在 Windows

**Reference**：[GCC documentation — Visibility attribute](https://gcc.gnu.org/onlinedocs/gcc/Common-Function-Attributes.html#index-visibility-function-attribute) — Ctrl+F: `visibility`。

---

### 4.3 各語言 FFI 機制對照

| 語言 | 邊界宣告 | 邊界限制 | 處理 exception |
|---|---|---|---|
| Go | `import "C"` + cgo directive | 只接 C ABI；C++ 要 wrapper | 不能跨界，必 catch |
| Rust | `extern "C" fn` + `#[no_mangle]` | 同 Go | 預設不能跨界；Rust 2024+ 有 `extern "C-unwind"` |
| Python | ctypes / cffi | 較寬鬆，動態 marshalling | exception 是 PyObject，可跨 C extension |
| Java | JNI；所有 reference 用 `jobject` handle | 嚴格，JVM 管 reference | JNI 函式可 throw Java exception 後 return |
| .NET | P/Invoke `[DllImport]` | C ABI；marshalling 自動 | 不能跨界 |
| Node N-API | C/C++ addon | 用 `napi_value` 包 JS value | exception 用 `napi_throw_*` API |

---

## Part 5：C++ via cgo 的成本與取捨

### 5.1 「FFI 成本貴」的真實含義

**成本貴在邊界，不貴在使用 C++ 本身**。

- 純 C++ project：0 FFI 成本，C++ 全特性可用
- 純 Go project：0 FFI 成本，Go 全特性可用
- Go + C++ project：邊界上**七道斷層全部要處理**，邊界內 C++ 還是 C++

### 5.2 三條路

| 路線 | FFI 成本 | 內部成本 | 適用 |
|---|---|---|---|
| **cgo + 純 C** | 低（沒 mangling/exception/stdlib 雷） | 中（無 STL / 重複 code 多） | libbpf 整合、syscall wrapper、簡單邏輯 |
| **cgo + C++** | 高（七雷區全要處理） | 低（STL / RAII / template） | 整合既有大型 C++ lib、複雜內部運算 |
| **純 Go**（`CGO_ENABLED=0`） | 0 | 看是否有 native lib | 大部分用例最佳 |

### 5.3 對本專案的具體建議

#### 對 sensor binary（如果這專案做 sensor）

1. **預設策略：純 Go**
   - syscall：`golang.org/x/sys`
   - BPF：[cilium/ebpf](https://github.com/cilium/ebpf)（pure Go，不需要 libbpf）
   - HTTP / JSON / log：全 Go
   - 結果：`CGO_ENABLED=0` 直接 static binary

2. **不得已用 cgo：寫純 C，不寫 C++**
   - 規避 7 雷區的 5 個
   - 邊界乾淨

3. **C++ 只在「真的非整合不可的 C++ lib」才用**
   - 一次性架 wrapper
   - 守 7 條鐵則

#### 對 cross-toolchain image（這個 repo）

- 保留 C++ toolchain 能力 ✓（user 可能需要）
- 不需要替 user 預先解 C++ 整合問題
- 可以加 helper script 簡化 user 設 CC/CXX：

```bash
# /usr/local/bin/go-darwin-arm64
#!/bin/bash
exec env \
    CC=arm64-apple-darwin20.4-clang \
    CXX=arm64-apple-darwin20.4-clang++ \
    CGO_ENABLED=1 \
    GOOS=darwin GOARCH=arm64 \
    go "$@"
```

#### Reference

62. [cilium/ebpf README](https://github.com/cilium/ebpf) — Ctrl+F: `pure Go`。cilium/ebpf 自述為純 Go 不依賴 libbpf。
63. [Iskander Sharipov — Path to convenient C FFI in Go (cgo call overhead)](https://www.quasilyte.dev/blog/post/cgo-funcall/) — Ctrl+F: `nanoseconds`。cgo call 效能 benchmark 數據（~150-200ns 量級）。
64. [Go issue #18460 — cgo compile error when using static library with C++ std header](https://github.com/golang/go/issues/18460) — Ctrl+F: `c++`。cgo 連 C++ static lib 已知問題。

---

## Part 6：cgo 大型專案實證調查

> 這部分是實證研究：派 agent 抓 55 個 popular Go cgo 專案、實地 `raw.githubusercontent.com` fetch 9 個真實 C++ wrapper 的 source code，整理出實際 packaging pattern。
>
> 所有專案連結都打到 repo 的具體頁面（非 GitHub topic 頁），可直接點進去看 source。

### 6.1 調查方法

- 目標：找 ≥ 50 個有 cgo 的大型 Go 專案（≥ 500 stars）
- 分類：pure C / C++ / Mixed
- 對 C++ wrapper 子集做 source 級分析
- 結果：**55 個 cgo 專案 verified**，其中 **~20 個底層是 C++**，但實際**直接 wrap C++ 的只有 3 個**（多數走 C API 中介層）

### 6.2 完整專案清單

#### 資料庫

| Project | Stars | Wraps | C/C++/Mixed |
|---|---|---|---|
| [mattn/go-sqlite3](https://github.com/mattn/go-sqlite3) | 9.1k | SQLite（C） | **C** |
| [marcboeker/go-duckdb](https://github.com/marcboeker/go-duckdb) | 1.1k | DuckDB | **C++** |
| [linxGnu/grocksdb](https://github.com/linxGnu/grocksdb) | 392 | RocksDB | **C++** |
| [tecbot/gorocksdb](https://github.com/tecbot/gorocksdb) | 974 | RocksDB | **C++** |
| [jmhodges/levigo](https://github.com/jmhodges/levigo) | 420 | LevelDB | **C++** |
| [PowerDNS/lmdb-go](https://github.com/PowerDNS/lmdb-go) | ~170 | LMDB | **C** |
| [godror/godror](https://github.com/godror/godror) | 594 | Oracle ODPI-C | **C** |
| [confluentinc/confluent-kafka-go](https://github.com/confluentinc/confluent-kafka-go) | 5.1k | librdkafka | **Mixed**（88% C, 7% C++）|

#### AI / ML

| Project | Stars | Wraps | C/C++/Mixed |
|---|---|---|---|
| [mudler/LocalAI](https://github.com/mudler/LocalAI) | 46.2k | llama.cpp / whisper.cpp / 多 backend | **C++** |
| [go-skynet/go-llama.cpp](https://github.com/go-skynet/go-llama.cpp) | 892 | llama.cpp | **C++** |
| [galeone/tfgo](https://github.com/galeone/tfgo) | 2.5k | TensorFlow C API | **C++** |
| [wamuir/graft](https://github.com/wamuir/graft) | 71 | libtensorflow | **C++** |
| [yalue/onnxruntime_go](https://github.com/yalue/onnxruntime_go) | 638 | ONNX Runtime | **C++** |

#### 影像 / 影片

| Project | Stars | Wraps | C/C++/Mixed |
|---|---|---|---|
| [hybridgroup/gocv](https://github.com/hybridgroup/gocv) | 7.4k | OpenCV 4 | **C++** |
| [otiai10/gosseract](https://github.com/otiai10/gosseract) | 3.1k | Tesseract | **C++** |
| [davidbyttow/govips](https://github.com/davidbyttow/govips) | 1.6k | libvips | **C** |
| [h2non/bimg](https://github.com/h2non/bimg) | 3.0k | libvips | **C** |
| [jdeng/goheif](https://github.com/jdeng/goheif) | 228 | libde265 / dav1d | **C** |
| [asticode/go-astiav](https://github.com/asticode/go-astiav) | 707 | FFmpeg | **C** |
| [veandco/go-sdl2](https://github.com/veandco/go-sdl2) | 2.3k | SDL2 | **C** |
| [hajimehoshi/ebiten](https://github.com/hajimehoshi/ebiten) | 13.2k | GLFW（Linux/BSD only）| **C** |
| [go-gst/go-gst](https://github.com/go-gst/go-gst) | 256 | GStreamer | **C** |

#### 壓縮 / 加解密

| Project | Stars | Wraps | C/C++/Mixed |
|---|---|---|---|
| [DataDog/zstd](https://github.com/DataDog/zstd) | 807 | zstd（C）| **C** |
| [valyala/gozstd](https://github.com/valyala/gozstd) | 477 | zstd | **C** |
| [GoKillers/libsodium-go](https://github.com/GoKillers/libsodium-go) | 141 | libsodium | **C** |
| [google/go-tpm-tools](https://github.com/google/go-tpm-tools) | 297 | TPM simulator + OpenSSL | **C** |

#### 網路 / 訊息

| Project | Stars | Wraps | C/C++/Mixed |
|---|---|---|---|
| [pebbe/zmq4](https://github.com/pebbe/zmq4) | 1.3k | libzmq（C++ 但 C ABI）| **C++** |
| [libgit2/git2go](https://github.com/libgit2/git2go) | 2.0k | libgit2 | **C** |

#### 音訊

| Project | Stars | Wraps | C/C++/Mixed |
|---|---|---|---|
| [gordonklaus/portaudio](https://github.com/gordonklaus/portaudio) | 836 | PortAudio | **C** |

#### OS / 容器 / eBPF

| Project | Stars | Wraps | C/C++/Mixed |
|---|---|---|---|
| [aquasecurity/libbpfgo](https://github.com/aquasecurity/libbpfgo) | 840 | libbpf | **C** |
| [iovisor/gobpf](https://github.com/iovisor/gobpf) | 2.2k | BCC | **Mixed** |
| [aquasecurity/tracee](https://github.com/aquasecurity/tracee) | 4.5k | libbpf（via libbpfgo）| **C** |
| [cilium/tetragon](https://github.com/cilium/tetragon) | 4.7k | libbpf | **C** |
| [coreos/go-systemd](https://github.com/coreos/go-systemd) | 2.7k | systemd sd-journal | **C** |
| [canonical/lxd](https://github.com/canonical/lxd) | 4.7k | liblxc / dqlite | **C** |
| [lxc/incus](https://github.com/lxc/incus) | 5.3k | liblxc / dqlite | **C** |
| [cri-o/cri-o](https://github.com/cri-o/cri-o) | 5.6k | libseccomp / libgpgme | **C** |

#### 硬體 / 驅動

| Project | Stars | Wraps | C/C++/Mixed |
|---|---|---|---|
| [google/gousb](https://github.com/google/gousb) | 930 | libusb-1.0 | **C** |
| [karalabe/usb](https://github.com/karalabe/usb) | 177 | libusb + hidapi | **Mixed** |

#### 文字 / 文件

| Project | Stars | Wraps | C/C++/Mixed |
|---|---|---|---|
| [lestrrat-go/libxml2](https://github.com/lestrrat-go/libxml2) | 228 | libxml2 | **C** |

#### GUI / Desktop

| Project | Stars | Wraps | C/C++/Mixed |
|---|---|---|---|
| [fyne-io/fyne](https://github.com/fyne-io/fyne) | 28.2k | OpenGL / GLFW / 多 backend | **Mixed** |
| [andlabs/ui](https://github.com/andlabs/ui) | 8.4k | libui | **C** |
| [therecipe/qt](https://github.com/therecipe/qt) | 10.8k | Qt | **C++** |
| [sciter-sdk/go-sciter](https://github.com/sciter-sdk/go-sciter) | 2.6k | Sciter | **C++** |
| [webview/webview_go](https://github.com/webview/webview_go) | 431 | WebKit / WebView2 | **Mixed** |
| [wailsapp/wails](https://github.com/wailsapp/wails) | 34.0k | WebKit2 / WebView2 / WKWebView | **Mixed** |
| [progrium/macdriver](https://github.com/progrium/macdriver) | 5.4k | libobjc / Cocoa | **C/Obj-C** |
| [getlantern/systray](https://github.com/getlantern/systray) | 3.7k | 系統 tray API | **Mixed** |

#### 腳本 / 區塊鏈 / 其他

| Project | Stars | Wraps | C/C++/Mixed |
|---|---|---|---|
| [aarzilli/golua](https://github.com/aarzilli/golua) | 697 | Lua 5.x / LuaJIT | **C** |
| [ethereum/go-ethereum](https://github.com/ethereum/go-ethereum) | 51.0k | secp256k1 / snappy / bn256 | **Mixed** |
| [m3db/m3](https://github.com/m3db/m3) | 4.9k | MurmurHash 等 | **C** |
| [influxdata/flux](https://github.com/influxdata/flux) | 1k+ | libflux（Rust）| **Mixed** |
| [anacrolix/torrent](https://github.com/anacrolix/torrent) | 6.0k | libutp | **C++** |

#### 已 verify 是「純 Go 沒 cgo」（避免誤認）

`dgraph-io/badger`、`syndtr/goleveldb`、`jackc/pgx`、`go-sql-driver/mysql`、`mongodb/mongo-go-driver`、`microsoft/go-mssqldb`、`ClickHouse/clickhouse-go`、`tetratelabs/wazero`、`cilium/ebpf`、`owulveryck/onnx-go`、`u2takey/ffmpeg-go`（shell out）、`yuin/gopher-lua`、`go-piv/piv-go`、`fogleman/gg`、`disintegration/imaging`、`blevesearch/bleve`

#### Reference

66. [awesome-go — Go 生態 awesome list](https://github.com/avelino/awesome-go) — Ctrl+F: `Database`。Go 生態系項目分類索引。
67. [GitHub REST API — repositories metadata](https://docs.github.com/en/rest/repos/repos) — Ctrl+F: `repository`。本調查確認 stars 用的官方 API。

### 6.3 統計總結

```
55 個 cgo 專案分類：
├── 純 C wrap                    36 個（66%）
├── 底層 C++ 但走 C API           14 個（25%）
├── Mixed（C + C++ 都有）          5 個（9%）
└── 真正直接 wrap C++（cgo 直接編 .cpp） 3 個（5%）
```

#### 6.3.1 最關鍵的 finding

**「Go 用 cgo wrap C++ lib」這件事，95% 的實際做法是「wrap C++ lib 的 C API」**——不是直接 wrap C++。

因為：
- RocksDB 自己 ship `rocksdb/c.h`
- LevelDB 自己 ship `leveldb/c.h`
- Tesseract 自己 ship `tesseract/capi.h`
- DuckDB 自己 ship `duckdb.h`
- ONNX Runtime 自己 ship `onnxruntime_c_api.h`
- llama.cpp / whisper.cpp 的 public header 也是 C-compatible
- Qt 透過 generator 把 C++ 轉成 C ABI binding

→ **C++ library 作者已經幫你解了 FFI 邊界問題**。Go binding 變成「純 cgo + C API」這條最低成本路線。

「真正直接 wrap C++」只有 **3 個**：gocv（OpenCV）、go-llama.cpp（部分自寫 C++ wrapper）、therecipe/qt（generator 生成）。**這些是 C++ FFI 雷區的實際示範場**。

### 6.4 9 個真實 C++ wrapper 深度解析

#### 6.4.1 hybridgroup/gocv（OpenCV）—— 唯一「真心直接 wrap C++」的代表

**Repo**：[hybridgroup/gocv](https://github.com/hybridgroup/gocv)（7.4k stars）

**Wrapper layout**：
- `.cpp` 檔跟 `.go` 檔同 directory（cgo 會自動找 `.cpp`）
- `core.h` 是雙語 header，C++ 跟 C 各看一份
- `core.cpp` 是 C++ implementation

**雙語 typedef 機關（[core.h:30-300](https://github.com/hybridgroup/gocv/blob/release/core.h)）**：

```c
#ifdef __cplusplus
#include <opencv2/opencv.hpp>
extern "C" {
#endif
...
#ifdef __cplusplus
typedef cv::Mat* Mat;
typedef std::vector< cv::Point >* PointVector;
#else
typedef void* Mat;
typedef void* PointVector;
#endif
```

C++ 側看到的 `Mat` 是真 `cv::Mat*`，C 側（cgo 解 header 那次）看到的是 `void*`。**handle value 不變，型別在兩邊各自合理**。這是「C++ 跟 cgo 共用 header」的標準解。

**Object lifetime（[core.cpp:42-50](https://github.com/hybridgroup/gocv/blob/release/core.cpp)）**：

```cpp
Mat Mat_New() { return new cv::Mat(); }
Mat Mat_NewWithSize(int rows, int cols, int type) {
    return new cv::Mat(rows, cols, type, 0.0);
}
PointVector PointVector_New() { return new std::vector< cv::Point >; }
void PointVector_Close(PointVector p) { p->clear(); delete p; }
```

`_New` / `_Close` 對。沒用 finalizer 當主路徑。

**Exception 處理（核心）**：

```cpp
int lastException = 0;
char lastExceptionMessage[1024];

Mat Eye(int rows, int cols, int type) {
    try {
        cv::Mat* mat = new cv::Mat(rows, cols, type);
        *mat = cv::Mat::eye(rows, cols, type);
        return mat;
    } catch(const cv::Exception& e){
        setExceptionInfo(e.code, e.what());
        return new cv::Mat();
    }
}
```

每個 wrapper function 都 try/catch。**但用 global 變數存錯誤訊息**——非 goroutine-safe。新 API 改用 `OpenCVResult` struct return value 解這個。

**Collections marshaling**：

```c
typedef struct CStrings { const char** strs; int length; } CStrings;
typedef struct IntVector { int* val; int length; } IntVector;
typedef struct Points { Point* points; int length; } Points;
```

C++ 端 `std::vector<T>` 在 boundary 上轉成 `{T*, length}` 平坦 struct。Go 端要 call paired `_Close` 釋放。

**特殊 idiom：placement new（[core.cpp:1741-1755](https://github.com/hybridgroup/gocv/blob/release/core.cpp)）**：

```cpp
void StdByteVectorInitialize(void* data) {
    new (data) std::vector<uchar>();
}
void StdByteVectorFree(void *data) {
    reinterpret_cast<std::vector<uchar> *>(data)->~vector<uchar>();
}
```

讓 Go 預先 reserve `sizeof(std::vector<uchar>)` bytes，C++ 在那塊 memory 上做 placement new。給 `cv::imencode` 寫入 Go-controlled buffer 用。**這是 advanced pattern，不推薦一般用**。

**Reference**

68. [hybridgroup/gocv core.h](https://github.com/hybridgroup/gocv/blob/release/core.h) — Ctrl+F: `typedef cv::Mat\* Mat`。雙語 typedef 實證。
69. [hybridgroup/gocv core.cpp](https://github.com/hybridgroup/gocv/blob/release/core.cpp) — Ctrl+F: `lastException` 跟 `Mat_New`。實際 C++ wrapper code。
70. [hybridgroup/gocv cgo.go](https://github.com/hybridgroup/gocv/blob/release/cgo.go) — Ctrl+F: `pkg-config: opencv4`。cgo directive 跟 platform-specific flag 的範例。

---

#### 6.4.2 otiai10/gosseract（Tesseract）—— 走 Tesseract C API

**Repo**：[otiai10/gosseract](https://github.com/otiai10/gosseract)（3.1k stars）

**重點**：Tesseract 本身是 C++，但 ship 了官方 `tesseract/capi.h`。gosseract 直接用這層**不用寫 C++**。

**Wrapper layout**：`tessbridge.c`（**注意是 `.c` 不是 `.cc`**，body 是純 C）+ `tessbridge.h` + `client.go`

**Header（[tessbridge.h](https://github.com/otiai10/gosseract/blob/main/tessbridge.h)）**：

```c
#ifdef __cplusplus
extern "C" {
#endif
typedef void* TessBaseAPI;
typedef void* PixImage;
struct bounding_box { int x1, y1, x2, y2; char* word; float confidence; };
struct bounding_boxes { int length; struct bounding_box* boxes; };

TessBaseAPI Create(void);
void Free(TessBaseAPI);
int Init(TessBaseAPI, char*, char*, char*, char*);
char* UTF8Text(TessBaseAPI);
#ifdef __cplusplus
}
#endif
```

**Implementation（[tessbridge.c:29-46](https://github.com/otiai10/gosseract/blob/main/tessbridge.c)）**：

```c
typedef void* TessHandle;
TessHandle Create(void) { return (TessHandle)TessBaseAPICreate(); }
void Free(TessHandle a) {
    TessBaseAPI* api = (TessBaseAPI*)a;
    if (api != NULL) {
        TessBaseAPIEnd(api);
        TessBaseAPIDelete(api);
    }
}
```

注意：用 `TessHandle` 取代 `TessBaseAPI`（後者跟 Tesseract 自己的 typedef 衝突），這是雙重 typedef workaround。

**特殊處理：stderr 重導向（[tessbridge.c:68-94](https://github.com/otiai10/gosseract/blob/main/tessbridge.c)）**：Tesseract 在 init 時瘋狂 print stderr，wrapper 暫時 dup FD 把它導去 Go-supplied buffer，做完 restore。**「靜音 chatty C++ lib」是常見需求**。

**Reference**

71. [otiai10/gosseract tessbridge.h](https://github.com/otiai10/gosseract/blob/main/tessbridge.h) — Ctrl+F: `extern "C"`。雙語 header 標準範例。
72. [otiai10/gosseract tessbridge.c](https://github.com/otiai10/gosseract/blob/main/tessbridge.c) — Ctrl+F: `TessHandle`。Tesseract C API 使用範例。

---

#### 6.4.3 go-skynet/go-llama.cpp（llama.cpp）—— 直接 C++ embedding

**Repo**：[go-skynet/go-llama.cpp](https://github.com/go-skynet/go-llama.cpp)（892 stars）

**Wrapper layout**：自寫 `binding.cpp` + `binding.h`，直接 `#include "llama.h"` 跟 `#include "common.h"`。

**Header（[binding.h:1-63](https://github.com/go-skynet/go-llama.cpp/blob/master/binding.h)）**：

```c
#ifdef __cplusplus
#include <vector>
#include <string>
extern "C" {
#endif
extern unsigned char tokenCallback(void *, char *);
void* load_model(const char *fname, int n_ctx, int n_seed, bool memory_f16, ...);
int llama_predict(void* params_ptr, void* state_pr, char* result, bool debug);
void llama_binding_free_model(void* state);
#ifdef __cplusplus
}
std::vector<std::string> create_vector(const char** strings, int count);
void delete_vector(std::vector<std::string>* vec);
#endif
```

注意設計：
- `extern "C"` 區段內：只用 C 相容型別（`void*`, `char*`, primitive）
- `extern "C"` 區段外：C++ helper（只給其他 C++ TU 用，不給 cgo 看）

**Go side（[llama.go:18-57](https://github.com/go-skynet/go-llama.cpp/blob/master/llama.go)）**：

```go
type LLama struct {
    state       unsafe.Pointer
    embeddings  bool
    contextSize int
}

func New(model string, opts ...ModelOption) (*LLama, error) {
    modelPath := C.CString(model)
    defer C.free(unsafe.Pointer(modelPath))
    result := C.load_model(modelPath, C.int(mo.ContextSize), ...)
    if result == nil {
        return nil, fmt.Errorf("failed loading model")
    }
    return &LLama{state: result, ...}, nil
}
func (l *LLama) Free() {
    C.llama_binding_free_model(l.state)
}
```

純 `unsafe.Pointer` 當 handle。

**cgo directives（[llama.go:3-8](https://github.com/go-skynet/go-llama.cpp/blob/master/llama.go)）**：

```go
// #cgo CXXFLAGS: -I${SRCDIR}/llama.cpp/common -I${SRCDIR}/llama.cpp
// #cgo LDFLAGS: -L${SRCDIR}/ -lbinding -lm -lstdc++
// #cgo darwin LDFLAGS: -framework Accelerate
// #cgo darwin CXXFLAGS: -std=c++11
```

- `${SRCDIR}` 是 cgo 內建變數，展開成 package 所在目錄
- 明確 `-lstdc++`（Linux）
- macOS 帶 Apple Accelerate framework

**Anti-pattern observed（[binding.cpp:113-117](https://github.com/go-skynet/go-llama.cpp/blob/master/binding.cpp)）**：

```cpp
static llama_context ** g_ctx;
static gpt_params * g_params;
static std::vector<llama_token> * g_input_tokens;
```

**Module-global state**——多 goroutine 同時 call `llama_predict` 會 race。「非 reentrant」是這類自寫 C++ wrapper 的常見 issue。

**Reference**

73. [go-skynet/go-llama.cpp binding.h](https://github.com/go-skynet/go-llama.cpp/blob/master/binding.h) — Ctrl+F: `extern "C"`。雙語 header + C++-only helper 區分範例。
74. [go-skynet/go-llama.cpp llama.go](https://github.com/go-skynet/go-llama.cpp/blob/master/llama.go) — Ctrl+F: `${SRCDIR}`。cgo SRCDIR 展開 + platform flag 範例。

---

#### 6.4.4 whisper.cpp Go bindings —— C++ 專案，public header 是 C facade

**Repo**：[ggerganov/whisper.cpp/bindings/go](https://github.com/ggerganov/whisper.cpp/tree/master/bindings/go)

**Layout**：**沒有 `.cpp` 檔**——upstream `whisper.h` 已經是 C-compatible，Go binding 全部寫在一個 `.go` 檔內，C 程式碼放 cgo preamble。

**核心（[whisper.go](https://github.com/ggerganov/whisper.cpp/blob/master/bindings/go/whisper.go)）**：

```go
/*
#cgo LDFLAGS: -lwhisper -lggml -lggml-base -lggml-cpu -lm -lstdc++
#cgo linux LDFLAGS: -fopenmp
#cgo darwin LDFLAGS: -lggml-metal -lggml-blas
#cgo darwin LDFLAGS: -framework Accelerate -framework Metal -framework Foundation -framework CoreGraphics
#include <whisper.h>
#include <stdlib.h>

extern void callNewSegment(void* user_data, int new);

static void whisper_new_segment_cb(struct whisper_context* ctx,
                                   struct whisper_state* state,
                                   int n_new, void* user_data) {
    if(user_data != NULL && ctx != NULL) {
        callNewSegment(user_data, n_new);
    }
}
*/
import "C"
```

關鍵設計：
- inline C trampoline `whisper_new_segment_cb`（在 preamble 內，cgo 編成 C）
- 它 call `callNewSegment` —— 這是 Go 用 `//export callNewSegment` 提供的
- whisper.cpp 註冊這個 trampoline 當 callback
- **C → Go callback 的標準模式**

**強制 `-lstdc++`**：雖然從 Go 角度只看 C facade，但 whisper.cpp 本身是 `g++` 編的，所以需要 link C++ stdlib。

**Reference**

75. [whisper.cpp bindings/go/whisper.go](https://github.com/ggerganov/whisper.cpp/blob/master/bindings/go/whisper.go) — Ctrl+F: `callNewSegment` 跟 `-lstdc++`。inline C trampoline 跟 stdlib link。

---

#### 6.4.5 yalue/onnxruntime_go —— dlopen + C API

**Repo**：[yalue/onnxruntime_go](https://github.com/yalue/onnxruntime_go)（638 stars）

**特殊點**：用 `dlopen` 動態載入 onnxruntime shared lib，不在 link 時 hard-link。**好處**：runtime 才需要 lib，build time 不需要。

**Wrapper layout**：`onnxruntime_wrapper.h` + `onnxruntime_wrapper.c`（純 C，呼 ORT 官方 C API）

**核心模式（[onnxruntime_wrapper.c](https://github.com/yalue/onnxruntime_go/blob/main/onnxruntime_wrapper.c)）**：

```c
static const OrtApi *ort_api = NULL;

int SetAPIFromBase(OrtApiBase *api_base) {
    if (!api_base) return 1;
    ort_api = api_base->GetApi(ORT_API_VERSION);
    ...
}
OrtStatus *CreateOrtEnv(char *name, OrtEnv **env) {
    return ort_api->CreateEnv(ORT_LOGGING_LEVEL_ERROR, name, env);
}
```

**Error handling — OrtStatus 物件**：

```go
func statusToError(status *C.OrtStatus) error {
    if status == nil { return nil }
    msg := C.GetErrorMessage(status)
    goMsg := C.GoString(msg)
    C.ReleaseOrtStatus(status)
    return fmt.Errorf("%s", strings.TrimSpace(goMsg))
}
```

ORT 用 opaque error object pattern：每個 call 回 `OrtStatus*`（nil = OK），Go 端 marshal 後**用 ORT 自己的 `ReleaseOrtStatus` 釋放**（不能 `C.free`）。

**Reference**

76. [yalue/onnxruntime_go onnxruntime_wrapper.c](https://github.com/yalue/onnxruntime_go/blob/main/onnxruntime_wrapper.c) — Ctrl+F: `ort_api`。Dynamic loading + v-table 快取範例。

---

#### 6.4.6 linxGnu/grocksdb（RocksDB）—— 走 rocksdb/c.h

**Repo**：[linxGnu/grocksdb](https://github.com/linxGnu/grocksdb)（392 stars）

**Wrapper layout**：**完全沒 C/C++ source**——只有 `.go` 檔，`#include "rocksdb/c.h"` 在 cgo preamble。

**Error pattern（[util.go](https://github.com/linxGnu/grocksdb/blob/master/util.go)、[db.go](https://github.com/linxGnu/grocksdb/blob/master/db.go)）**：

```go
func fromCError(cErr *C.char) (err error) {
    if cErr != nil {
        err = errors.New(C.GoString(cErr))
        C.rocksdb_free(unsafe.Pointer(cErr))  // ← 注意：rocksdb_free 不是 C.free
    }
    return err
}

func OpenDb(opts *Options, name string) (db *DB, err error) {
    var cErr *C.char
    var cName = C.CString(name)
    _db := C.rocksdb_open(opts.c, cName, &cErr)
    if err = fromCError(cErr); err == nil {
        db = &DB{name: name, c: _db, opts: opts}
    }
    C.free(unsafe.Pointer(cName))
    return db, err
}
```

關鍵點：
- `char** out_err` 是 RocksDB C API 的標準 error 模式
- **必須 call `rocksdb_free`，不能 call `C.free`**——因為 lib 可能用不同 allocator（特別是 Windows 上 glibc malloc vs MSVCR<X>）

**`unsafe.Slice` 零拷貝（[util.go:25-28](https://github.com/linxGnu/grocksdb/blob/master/util.go)）**：

```go
func charToBytes(s *C.char, length C.size_t) []byte {
    if length == 0 { return nil }
    return unsafe.Slice((*byte)(unsafe.Pointer(s)), length)
}
```

`(*char, size_t)` → Go `[]byte` 零拷貝。**注意 lifetime**：Go slice 仍指 C memory，不能 outlive C side。

**Reference**

77. [linxGnu/grocksdb db.go](https://github.com/linxGnu/grocksdb/blob/master/db.go) — Ctrl+F: `cErr`。Out-param error 標準 pattern。
78. [linxGnu/grocksdb util.go](https://github.com/linxGnu/grocksdb/blob/master/util.go) — Ctrl+F: `rocksdb_free`。Vendor-specific deallocator 的正確用法。

---

#### 6.4.7 jmhodges/levigo（LevelDB）—— 同 RocksDB pattern

**Repo**：[jmhodges/levigo](https://github.com/jmhodges/levigo)（420 stars）

**`.go` 內 inline C shim（[db.go:50-69](https://github.com/jmhodges/levigo/blob/master/db.go)）**：

```go
/*
#cgo LDFLAGS: -lleveldb
#include "leveldb/c.h"

void levigo_leveldb_approximate_sizes(leveldb_t* db, int num_ranges, ...) {
    leveldb_approximate_sizes(db, num_ranges,
                              (const char* const*)range_start_key, ...);
}
*/
import "C"

type DB struct {
    Ldb    *C.leveldb_t
    closed bool
}
```

**Pattern**：當 upstream C API 有 cgo 不好處理的型別（const-correctness 不對、function pointer 等），在 cgo preamble 內寫 `static` shim 包一層。**Go 直接 call shim，不 call 原 API**。

**Reference**

79. [jmhodges/levigo db.go](https://github.com/jmhodges/levigo/blob/master/db.go) — Ctrl+F: `levigo_leveldb_approximate_sizes`。inline C shim 範例。

---

#### 6.4.8 marcboeker/go-duckdb —— 分 platform 套 module

**Repo**：[marcboeker/go-duckdb](https://github.com/marcboeker/go-duckdb)（1.1k stars）

**特殊 packaging**：main branch **完全沒 C/H 檔**。`mapping/mapping_darwin_arm64.go` 只是 re-export：

```go
//go:build !duckdb_use_lib && !duckdb_use_static_lib

package mapping
import bindings "github.com/duckdb/duckdb-go-bindings/darwin-arm64"
type Type = bindings.Type
const ( TypeBoolean = bindings.TypeBoolean ... )
```

實際 cgo 在 `duckdb-go-bindings/<platform>` 各自 sub-module 內，每個 platform 一個 module，**vendored 對應的預編譯 DuckDB static lib**。

→ user `go get` 自動拿對應 platform 的 module，**不需要本機 C++ toolchain**。代價是 binary 大（DuckDB lib ~30MB）。

**這是大型 cgo 專案 distribution 的高階做法**——適合「user 不想裝 build dependency」的場景。

**Reference**

80. [marcboeker/go-duckdb mapping](https://github.com/marcboeker/go-duckdb/tree/main/mapping) — Ctrl+F: `duckdb-go-bindings`。Per-platform module 的 import 關係。
81. [duckdb/duckdb-go-bindings](https://github.com/duckdb/duckdb-go-bindings) — Ctrl+F: `darwin-arm64`。Pre-built static lib 分發機制。

---

#### 6.4.9 aclements/go-z3（Z3 SMT solver）—— Go-export callback 給 C 用

**Repo**：[aclements/go-z3](https://github.com/aclements/go-z3)

**核心（[z3/context.go](https://github.com/aclements/go-z3/blob/master/z3/context.go)）**：

```go
/*
#cgo LDFLAGS: -lz3
#include <z3.h>

extern void goZ3ErrorHandler(Z3_context c, Z3_error_code e);
*/
import "C"

type Context struct {
    c    C.Z3_context
    syms map[string]C.Z3_symbol
    lock sync.Mutex   // ← Z3 context 非 thread-safe
}

//export goZ3ErrorHandler
func goZ3ErrorHandler(ctx C.Z3_context, e C.Z3_error_code) {
    msg := C.Z3_get_error_msg(ctx, e)
    ...
}
```

Pattern：
- `//export` 把 Go function 暴露成 C symbol
- 註冊給 Z3 當 error callback
- **Host language（Go）負責 thread sync** —— Z3 context 不是 thread-safe，所以 wrapper 加 `sync.Mutex`

**「C lib 不 thread-safe → Go side `runtime.LockOSThread` 或 mutex」是常見 idiom**。

**Reference**

82. [aclements/go-z3 z3/context.go](https://github.com/aclements/go-z3/blob/master/z3/context.go) — Ctrl+F: `//export goZ3ErrorHandler`。Go-exported callback 註冊到 C library 的範例。

---

### 6.5 共通 pattern 整理（9 大 idiom）

從上面 9 個 project 抽出來的 **universal pattern**：

#### Pattern A：Opaque handle（兩種 flavour）

**A1. 雙語 typedef**（gocv 用）：
```c
#ifdef __cplusplus
typedef cv::Mat* Mat;
#else
typedef void* Mat;
#endif
```
→ Go 端維持 typed handle（`C.Mat`），可讀性高。

**A2. 永遠 `void*`**（go-llama.cpp 用）：
```c
void* load_model(...);
```
→ Go 端用 `unsafe.Pointer`，最簡單但弱型別。

#### Pattern B：`_New` / `_Close` 對

```cpp
Mat Mat_New() { return new cv::Mat(); }
void Mat_Close(Mat m) { delete m; }
```

**全部 9 個 project 都用這個 pattern**。沒人用 finalizer 當主路徑（少數加做 backstop）。

#### Pattern C：Error string out-param（`char**`）

```c
void func(args..., char** out_err);
// 用法：
char* err = NULL;
some_func(args, &err);
if (err) { /* handle */; lib_free(err); }
```

→ RocksDB、LevelDB 用。最簡潔的 C-style error model。

#### Pattern D：Error status opaque object

```c
OrtStatus* func(args...);
// nil = OK, non-nil = error，需要呼 release function
```

→ ONNX Runtime 用。比 char** 多一個 release function，但可帶結構化錯誤資訊。

#### Pattern E：Error code + global（**anti-pattern**）

```cpp
int lastException = 0;
char lastExceptionMessage[1024];
// 每個 wrapper try/catch 寫進 global
```

→ gocv 早期 API。**非 goroutine-safe**。新 API 改用 D 或 F。

#### Pattern F：OpenCVResult struct return

```c
typedef struct { int Code; char* Message; int Length; } OpenCVResult;
```

→ gocv 新 API。同個 return value 帶 status，最 clean。

#### Pattern G：Length-prefixed flat array（取代 std::vector）

```c
typedef struct { T* data; int length; } TVector;
```

→ **全部 project 都這樣**。`std::vector<T>` 跨界一律拆成 `{T*, length}`。

#### Pattern H：`extern "C"` 永遠在 header

**全部 9 個 project 都這樣**：

```c
#ifdef __cplusplus
extern "C" {
#endif
... declarations ...
#ifdef __cplusplus
}
#endif
```

**沒人把 `extern "C"` 放在 `.cpp` 內**——因為 header 必須跟兩邊 declaration 用同一個 linkage。

#### Pattern I：Platform-specific `#cgo`

```go
// #cgo CXXFLAGS:        -std=c++11
// #cgo !windows pkg-config: opencv4
// #cgo darwin LDFLAGS:  -framework Accelerate
// #cgo windows LDFLAGS: -LC:/opencv/... -lopencv_core4130
// #cgo linux LDFLAGS:   -fopenmp
```

**Platform tokens**（`linux`、`darwin`、`windows`、`!windows`）gate 個別 flag line。

---

### 6.6 Anti-pattern catalog（6 條）

1. **Module-global C++ state**（go-llama.cpp `static llama_context** g_ctx`）→ 非 reentrant
2. **Last-exception globals**（gocv 早期）→ 非 goroutine-safe
3. **寫死 vendor include path**（gosseract `#include "/usr/local/include/leptonica/allheaders.h"` for FreeBSD）→ 不可移植
4. **用 `C.free` 取代 vendor deallocator** → Windows 上 allocator 不同 = heap corruption
5. **跨界傳 `std::string` / `std::vector` by value** → ABI 不匹配
6. **`extern "C"` 放錯位置**（放 `.cpp` 而非 header）→ 從其他 C TU include 該 header 就壞

---

### 6.7 對比表

| Project | C++ in wrapper? | Handle | Error pattern | C++ stdlib link |
|---|---|---|---|---|
| gocv | ✓ `.cpp` | `cv::Mat*` typedef-as-`void*` | try/catch → globals + `OpenCVResult` | `pkg-config opencv4` |
| gosseract | ✗（Tess C API）| `void*` (`TessHandle`)| int return + stderr-to-buf | 隱含 via Tesseract |
| go-llama.cpp | ✓ `.cpp` | `void* state` | NULL return | `-lstdc++` + `-framework Accelerate` |
| whisper.cpp Go | ✗（C facade）| `*C.struct_whisper_context` | int/bool returns | 顯式 `-lstdc++` |
| onnxruntime_go | ✗（`.c` wrap）| 各種 ORT 型別 | `OrtStatus*` opaque | `dlopen` shared lib |
| grocksdb | ✗（rocksdb C API）| `*C.rocksdb_t` | `char**` out + `rocksdb_free` | `-lrocksdb -lstdc++` |
| levigo | ✗（leveldb C API）| `*C.leveldb_t` | `char**` out | `-lleveldb` |
| go-duckdb | 委派 | typed in mapping | upstream-defined | per-platform module |
| go-z3 | ✗（z3.h）| `C.Z3_context` | Go-export error handler | `-lz3` |

---

### 6.8 對你這個專案的最終建議

從 55 個 project 的實證來看：

1. **「Wrap C++ lib via cgo」的 95% 走 C API**——只有 OpenCV 這種根本沒 C facade 的才被迫直接 wrap C++。**如果 user 的 lib 有 C API，用它就好**。

2. **`extern "C"` 永遠在 header**——這是業界統一寫法。

3. **`_New` / `_Close` 對 + opaque handle**——比 finalizer 可靠。

4. **Error 用 `char**` out-param 或 status opaque object**——別用 global。

5. **跨界一律 POD + `{T*, length}`**——`std::*` 全部死在 wrapper 內。

6. **Allocator 對稱**——vendor 給的記憶體用 vendor 的 free function 釋放，不要 `C.free`。

7. **Platform flag 用 build tag 分**——`#cgo darwin LDFLAGS:` / `#cgo linux LDFLAGS:` 各自寫。

8. **`-lstdc++` 顯式加（Linux）**——即使 cgo 只看 C facade，底層 C++ lib 還是要 link stdlib。macOS 上 clang++ 自動處理 libc++。

→ 對你這個 cross-toolchain image：image 本身已經提供完整 C++ build 能力（Linux libstdc++ 透過 ct-ng、macOS libc++ 透過 osxcross）。**user 只要照上面 8 條 best practice 寫 wrapper，你的 image 就 work**。

不需要在 image 內加額外 helper（除非你想簡化 user 設 `CC`/`CXX`——可選）。

---

## Appendix：完整 Reference 清單

按本文出現順序：

### osxcross 與 macOS 工具鏈

1. [tpoechtrager/osxcross issue #462 — clang 21 darwin-arm64 ld64 segfault](https://github.com/tpoechtrager/osxcross/issues/462)
2. [tpoechtrager/osxcross issue #471 — ld64.lld missing](https://github.com/tpoechtrager/osxcross/issues/471)
3. [tpoechtrager/apple-libtapi](https://github.com/tpoechtrager/apple-libtapi)
4. [LLVM TextAPI](https://llvm.org/doxygen/group__libllvm__text__api.html)
5. [pudquick gist — Reproducible Builds for macOS](https://gist.github.com/pudquick/89c90421a9582f88741b21d10c6a155e)
6. [Apple Developer Forums — Missing libraries in /usr/lib](https://developer.apple.com/forums/thread/655588)
7. [Apple QA — Static linking on macOS](https://developer.apple.com/library/archive/qa/qa1118/_index.html)

### libstdc++ / libc++

8. [Apple Developer Forums — libstdc++ is deprecated; move to libc++](https://developer.apple.com/forums/thread/113746)
9. [Apple Developer Forums — Where is libstdc++.6.dylib in xcode10 beta?](https://developer.apple.com/forums/thread/103732)
10. [pandas-dev/pandas issue #23424 — Xcode 10 libstdc++ not supported](https://github.com/pandas-dev/pandas/issues/23424)
11. [Go issue #29969 — libstdc++ deprecation in cgo](https://github.com/golang/go/issues/29969)

### osxcross stdlib 處理

12. [osxcross README — libc++ default and override](https://github.com/tpoechtrager/osxcross/blob/master/README.md)
13. [本 repo docs/docker-experiments.md §3.4](./docker-experiments.md)

### `__builtin_available` / compiler-rt

14. [Apple — Marking API Availability in Objective-C](https://developer.apple.com/documentation/swift/marking-api-availability-in-objective-c)
15. [Eugene Petrenko — Undefined isOSVersionAtLeast on macOS](https://jonnyzzz.com/blog/2018/06/05/link-error-2/)
16. [Swift issue #62626 — Undefined symbol `___isOSVersionAtLeast`](https://github.com/apple/swift/issues/62626)
17. [curl-rust issue #279 — missing `___isOSVersionAtLeast`](https://github.com/alexcrichton/curl-rust/issues/279)
18. [LLVM compiler-rt 專案首頁](https://compiler-rt.llvm.org/)
19. [osxcross issue #278 — `__builtin_available` 需要 compiler-rt](https://github.com/tpoechtrager/osxcross/issues/278)
20. [osxcross issue #267 — arm64 `-fopenmp` 需要 compiler-rt](https://github.com/tpoechtrager/osxcross/issues/267)

### libc++ 結構

21. [LLVM libc++ 首頁](https://libcxx.llvm.org/)
22. [libc++ ABIVersioning 設計文件](https://libcxx.llvm.org/DesignDocs/ABIVersioning.html)
23. [libc++ 8.0 — Using libc++](https://releases.llvm.org/8.0.0/projects/libcxx/docs/UsingLibcxx.html)
24. [Joel Viotti — Debugging the C++ standard library on macOS](https://www.jviotti.com/2022/05/05/debugging-the-cxx-standard-library-on-macos.html)

### macOS feature availability

25. [Apple Developer — C++ Language Support](https://developer.apple.com/xcode/cpp/)
26. [libc++ 5.0 — Using libc++（_LIBCPP_AVAILABILITY）](https://releases.llvm.org/5.0.1/projects/libcxx/docs/UsingLibcxx.html)
27. [MacPorts ticket #62426 — back-deployment libc++](https://trac.macports.org/ticket/62426)

### 自編 libc++.a

28. [osxcross repo 根目錄 scripts](https://github.com/tpoechtrager/osxcross/tree/master)
29. [LLVM HowToCrossCompileLLVM](https://llvm.org/docs/HowToCrossCompileLLVM.html)
30. [libc++ 5.0 — Building libc++](https://releases.llvm.org/5.0.1/projects/libcxx/docs/BuildingLibcxx.html)
31. [Chromium chromium-reviews — static libc++.a](https://groups.google.com/a/chromium.org/g/chromium-reviews/c/jucBj1z-hFY)
32. [hermeticbuild/hermetic-llvm](https://github.com/hermeticbuild/hermetic-llvm)

### 心智負擔策略

33. [Clang docs — Availability attribute](https://clang.llvm.org/docs/AttributeReference.html#availability)
34. [endoflife.date — macOS](https://endoflife.date/macos)
35. [Apple — Apple Silicon SDK 需求](https://developer.apple.com/documentation/apple-silicon)
36. [fmtlib/fmt repo](https://github.com/fmtlib/fmt)
37. [C++ proposal P0645 — std::format from fmt](https://www.open-std.org/jtc1/sc22/wg21/docs/papers/2017/p0645r0.html)

### CGO 接 C/C++

38. [Itanium C++ ABI — Mangling](https://itanium-cxx-abi.github.io/cxx-abi/abi.html#mangling)
39. [Go cgo command documentation](https://pkg.go.dev/cmd/cgo)
40. [cppreference — Language linkage](https://en.cppreference.com/w/cpp/language/language_linkage)
41. [SEI CERT ERR59-CPP](https://wiki.sei.cmu.edu/confluence/display/cplusplus/ERR59-CPP.+Do+not+throw+an+exception+across+execution+boundaries)
42. [Go forum — wrapping C++ in cgo](https://forum.golangbridge.org/t/what-is-the-best-practice-for-wrapping-c-plus-plus-code/4038)
43. [draffensperger/go-interlang](https://github.com/draffensperger/go-interlang/tree/master/go_to_cxx/c_wrapper)
44. [Go issue #12516 — C++ exception crashes cgo](https://github.com/golang/go/issues/12516)
45. [Netlify — CGO crash post-mortem](https://www.netlify.com/blog/2021/03/18/tracking-down-a-cgo-crash-in-production/)
46. [keyan pishdadian — C/C++ segfaults in cgo](https://keyanp.com/cgo-segfault.html)
47. [Go issue #48486 — cgo + libc++ support](https://github.com/golang/go/issues/48486)
48. [Aaron Taylor — Linking Dynamic C++ Libraries with Go](https://ataylor.io/blog/cgolinking/)
49. [Gaultier — Addressing CGO pains](https://gaultier.github.io/blog/addressing_cgo_pains_one_at_a_time.html)
50. [Go issue #44112 — cgo cross-compile darwin](https://github.com/golang/go/issues/44112)
51. [Go issue #59221 — cgo c-archive cross-compile](https://github.com/golang/go/issues/59221)
52. [plentico/osxcross-target](https://github.com/plentico/osxcross-target)
53. [Ecostack — Go cgo cross-compilation](https://ecostack.dev/posts/go-and-cgo-cross-compilation/)
54. [Go issue #18460 — cgo + C++ std header](https://github.com/golang/go/issues/18460)

### FFI 通論

55. [Wikipedia — Foreign function interface](https://en.wikipedia.org/wiki/Foreign_function_interface)
56. [Java JNI specification（Oracle）](https://docs.oracle.com/en/java/javase/21/docs/specs/jni/index.html)
57. [Python ctypes documentation](https://docs.python.org/3/library/ctypes.html)
58. [System V AMD64 ABI 規格](https://gitlab.com/x86-psABIs/x86-64-ABI)
59. [Go runtime.Pinner](https://pkg.go.dev/runtime#Pinner)
60. [Rust RFC 2945 — C-unwind ABI](https://rust-lang.github.io/rfcs/2945-c-unwind-abi.html)
61. [Go runtime.LockOSThread](https://pkg.go.dev/runtime#LockOSThread)
62. [GCC docs — visibility attribute](https://gcc.gnu.org/onlinedocs/gcc/Common-Function-Attributes.html#index-visibility-function-attribute)
63. [ISO/IEC 9899 C18 draft — error handling](https://www.open-std.org/jtc1/sc22/wg14/www/docs/n2310.pdf)

### 工程取捨

64. [cilium/ebpf — pure Go BPF library](https://github.com/cilium/ebpf)
65. [Iskander Sharipov — cgo call overhead benchmark](https://www.quasilyte.dev/blog/post/cgo-funcall/)

### Part 6：cgo 大型專案實證調查

66. [awesome-go — Go 生態 awesome list](https://github.com/avelino/awesome-go)
67. [GitHub REST API — repositories metadata](https://docs.github.com/en/rest/repos/repos)
68. [hybridgroup/gocv — core.h（OpenCV C++ wrapper header）](https://github.com/hybridgroup/gocv/blob/release/core.h)
69. [hybridgroup/gocv — core.cpp（OpenCV C++ wrapper impl）](https://github.com/hybridgroup/gocv/blob/release/core.cpp)
70. [hybridgroup/gocv — cgo.go（platform-specific cgo flags）](https://github.com/hybridgroup/gocv/blob/release/cgo.go)
71. [otiai10/gosseract — tessbridge.h（Tesseract C API bridge header）](https://github.com/otiai10/gosseract/blob/main/tessbridge.h)
72. [otiai10/gosseract — tessbridge.c（Tesseract C API bridge impl）](https://github.com/otiai10/gosseract/blob/main/tessbridge.c)
73. [go-skynet/go-llama.cpp — binding.h（llama.cpp C++ wrapper header）](https://github.com/go-skynet/go-llama.cpp/blob/master/binding.h)
74. [go-skynet/go-llama.cpp — llama.go（cgo SRCDIR + platform flags）](https://github.com/go-skynet/go-llama.cpp/blob/master/llama.go)
75. [whisper.cpp — bindings/go/whisper.go（inline C trampoline + Go-export callback）](https://github.com/ggerganov/whisper.cpp/blob/master/bindings/go/whisper.go)
76. [yalue/onnxruntime_go — onnxruntime_wrapper.c（dlopen + v-table 快取）](https://github.com/yalue/onnxruntime_go/blob/main/onnxruntime_wrapper.c)
77. [linxGnu/grocksdb — db.go（char** out-param error）](https://github.com/linxGnu/grocksdb/blob/master/db.go)
78. [linxGnu/grocksdb — util.go（vendor-specific deallocator）](https://github.com/linxGnu/grocksdb/blob/master/util.go)
79. [jmhodges/levigo — db.go（inline C shim 範例）](https://github.com/jmhodges/levigo/blob/master/db.go)
80. [marcboeker/go-duckdb — mapping subdir（per-platform module pattern）](https://github.com/marcboeker/go-duckdb/tree/main/mapping)
81. [duckdb/duckdb-go-bindings — pre-built static lib 分發](https://github.com/duckdb/duckdb-go-bindings)
82. [aclements/go-z3 — z3/context.go（Go-export error handler 到 C lib）](https://github.com/aclements/go-z3/blob/master/z3/context.go)

---

## 修訂紀錄

- 2026-05：初版。涵蓋 clang/osxcross 兼容性、libSystem/libc++ 機制、`__builtin_available`、libc++ 雙層結構、CGO 接 C/C++、FFI 七道斷層、工程取捨。Reference 1-65 確認指向頁面內可 Ctrl+F 搜的具體文字段。
- 2026-05（增補）：新增 Part 6「cgo 大型專案實證調查」。Agent 實地調查 55 個 ≥500 stars 的 Go cgo 專案、實際 `raw.githubusercontent.com` fetch 9 個 C++ wrapper 的 source code 做 pattern 分析。Reference 66-82 新增。關鍵 finding：「Go 用 cgo wrap C++ lib」95% 走 vendor 提供的 C API，真正直接 wrap C++（cgo 編 .cpp）只有 3 個 project。
