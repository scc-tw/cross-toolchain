# ct-ng 1.25 backport: GCC 15.2.0

> **狀態**：實驗。ct-ng upstream 沒測過這個組合。

## 這目錄是什麼

把 ct-ng 1.28 (2025-09 釋出) 才有的 **GCC 15.2.0** 註冊資訊，反向移植到 ct-ng 1.25.0 (2022-05) — 因為 ct-ng 1.25 是最後一版 ship glibc 2.12.1（CentOS 6 ABI floor）。

純 metadata + 我們自己的 patches。**不**修改 ct-ng 1.25 的 build script 邏輯（如果 build 失敗才會考慮）。

## Layout（mirror ct-ng 內部 packages/ 結構）

```
packages/
├── gcc/15.2.0/
│   ├── chksum         GCC 15.2.0 tarball 的 MD5/SHA1/SHA256/SHA512（ct-ng 1.28 同等）
│   ├── version.desc   空檔（ct-ng convention）
│   └── .gitkeep + 0NNN-*.patch（撞 build error 才補）
├── glibc/2.12.1/
│   └── .gitkeep + 0NNN-*.patch（最可能撞，因為 GCC 15 default 嚴格）
└── binutils/2.38/
    └── .gitkeep + 0NNN-*.patch
```

ct-ng 在 patch-apply 階段會掃 `packages/<pkg>/<ver>/*.patch`，按編號 lexical 順序套到解出來的 source。

## 怎麼套進 ct-ng 1.25 的 source tree

Dockerfile 解 ct-ng 1.25 release tarball 後做：

```
cp -r toolchain/patches/ct-ng-1.25-gcc15-backport/packages/* /tmp/ct-ng-src/packages/
```

外加 sed 改兩個 ct-ng 內部 config（不在這個目錄裡）：
- `packages/gcc/package.desc` — milestones 加 `15`
- `config/versions/gcc.in` — 加 `config GCC_V_15` 條目

## 為什麼不直接從 ct-ng 1.28 copy 它的 GCC 15 patches？

ct-ng 1.28 的 `packages/gcc/15.2.0/` 內 11 個 patch，多數**跟我們無關**：
- `0000-libtool-leave-framework-alone.patch` — Mac framework
- `0007-Add-newlib-...-as-default-C-library-choices.patch` — picolibc/newlib
- `0008-Support-picolibc-targets.patch` — picolibc
- 其他針對 ARM softfloat、UCLIBC 等

我們 target 是 glibc 2.12 + Linux x86_64，這些跟我們不沾邊。所以**不預先 copy**，只在 build 撞 error 時針對性寫 patch。

## 紀錄在哪

每個錯誤 + survey + patch 會記錄到 `toolchain/docker_experiments.md`，beginner-friendly 寫法，含：
- 錯誤訊息 verbatim
- 觸發指令
- survey 過程（搜什麼、看什麼）
- 假設 + reference link
- 嘗試 + 結果

---

*Created 2026-05-09. Updated as Phase 1 build progresses.*
