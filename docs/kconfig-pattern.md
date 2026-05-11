# kconfig 模式：從初學者角度理解 + 對應到軟體設計

這份文件講兩件事：

1. **kconfig 到底是什麼、怎麼運作**（用「邊讀邊記的秘書」心智模型，從 0 開始）
2. **kconfig 的設計精神在軟體界其它地方怎麼被借用**（package manager、Bazel、TypeScript、SPL/FOSD 學術領域、GoF pattern 對應）

跟 [`docker-experiments.md`](./docker-experiments.md) 的 Error #22 / #23 phase 1/2 build 紀錄性質不同——那邊是「我們踩到雷怎麼修」，這邊是「為什麼 kconfig 這樣設計、這個 design 還被誰學去用」。

讀過 Error #22 / #23 之後想徹底搞懂 kconfig 機制可以讀這份。

---

## 目錄

- [Part 1：心智模型——engine 就是邊讀邊記的秘書](#part-1心智模型engine-就是邊讀邊記的秘書)
  - [Round 1：最簡單的 `.in` 檔（兩個獨立 option）](#round-1最簡單的-in-檔兩個獨立-option)
  - [Round 2：加 `choice`——一組必須選一個的 option](#round-2加-choice一組必須選一個的-option)
  - [Round 3：加 `if X ... endif`——條件區塊](#round-3加-if-x--endif條件區塊)
  - [Round 4：加 `source "other.in"`——跨檔引用](#round-4加-source-otherin跨檔引用)
  - [Round 5：user defconfig 進來，秘書對著筆記本比對](#round-5user-defconfig-進來秘書對著筆記本比對)
  - [Round 6：秘書「結算」——把每個 option 的最終值算出來](#round-6秘書結算把每個-option-的最終值算出來)
  - [Round 7：寫 `.config`](#round-7寫-config)
  - [用語對照表](#用語對照表)
- [Part 2：抽象出 kconfig pattern 的精神](#part-2抽象出-kconfig-pattern-的精神)
- [Part 3：直接同血統（DSL + engine 二分）](#part-3直接同血統dsl--engine-二分)
- [Part 4：同精神，不同 form](#part-4同精神不同-form)
- [Part 5：學術領域——SPL / FOSD](#part-5學術領域spl--fosd)
- [Part 6：GoF 經典 design pattern 對應](#part-6gof-經典-design-pattern-對應)
- [Part 7：對 cross-toolchain repo 的具體啟示](#part-7對-cross-toolchain-repo-的具體啟示)

---

## Part 1：心智模型——engine 就是邊讀邊記的秘書

把 engine 想成一個秘書，桌上一本筆記本。他的工作只有兩件事：

1. **讀檔**：拿到一個 `.in` 檔，**一行一行從上往下讀**
2. **記筆記**：根據每行寫了什麼，往筆記本上加東西、改東西

讀完所有檔之後，筆記本上會有「**世界上存在哪些 option、它們各自的規則**」這份清單。

接下來從一個 4 行的迷你 `.in` 檔開始，看這位秘書到底在記什麼。

### Round 1：最簡單的 `.in` 檔（兩個獨立 option）

假設我們有 `fruit.in`：

```kconfig
config APPLE
    bool "Apple"

config BANANA
    bool "Banana"
```

#### Engine 從第 1 行開始讀

```
讀到：「config APPLE」
```

秘書想：「`config` 是 keyword，表示『接下來宣告一個新 option』。option 名字是 `APPLE`。」

筆記本動作：

```
筆記本：
┌─────────────────────────┐
│ option name: APPLE       │
│   type: ?                │
│   label: ?               │
└─────────────────────────┘
```

剛開新的一格，type 跟 label 還不知道——等下面的行補。

#### Engine 讀第 2 行

```
讀到：「    bool "Apple"」
```

注意這行**前面有 4 個空白**（indent）。秘書看到 indent 就知道：「這行不是新的 declaration，是**前一個 declaration 的補充屬性**。」

`bool` = type 是 boolean（y 或 n）；`"Apple"` 引號內 = 給 user 看的 label。

筆記本動作（更新 APPLE 那格）：

```
筆記本：
┌─────────────────────────┐
│ option name: APPLE       │
│   type: bool             │ ← 補上
│   label: "Apple"         │ ← 補上
└─────────────────────────┘
```

#### Engine 讀第 3 行

```
讀到：「」（空白行）
```

秘書：「啥都沒有，跳過。」

#### Engine 讀第 4 行

```
讀到：「config BANANA」
```

`config` 又出現了 → 新 declaration。秘書心想：「上一個 `APPLE` 算結束了（沒 indent 行 = 不再屬於它）。開新格。」

筆記本動作：

```
筆記本：
┌─────────────────────────┐
│ option name: APPLE       │
│   type: bool             │
│   label: "Apple"         │
├─────────────────────────┤  ← 新格開始
│ option name: BANANA      │
│   type: ?                │
│   label: ?               │
└─────────────────────────┘
```

#### Engine 讀第 5 行

```
讀到：「    bool "Banana"」
```

跟前面同套邏輯：indent 行補屬性給 `BANANA`。

筆記本最終：

```
筆記本：
┌─────────────────────────┐
│ option name: APPLE       │
│   type: bool             │
│   label: "Apple"         │
├─────────────────────────┤
│ option name: BANANA      │
│   type: bool             │
│   label: "Banana"        │
└─────────────────────────┘
```

**讀檔結束**。engine 現在「知道世界上有兩個 option：APPLE 跟 BANANA，都是 boolean」。

→ 這就是技術書常叫「symbol table」的東西。**它不是什麼神秘東西**——就是這本筆記本上的兩格。「symbol」=「option 名字」。「table」=「整本筆記」。

→ 同理「AST（abstract syntax tree）」也是。當 engine 讀到 `config APPLE` 然後下面接 `bool "Apple"`，他知道 `bool` 是屬於 APPLE 的——這種「誰是誰的下面 / 誰附屬於誰」的結構在數學上長得像棵樹，所以叫 AST。**初學者不用記這個名詞**，知道「筆記本」就夠了。

### Round 2：加 `choice`——一組必須選一個的 option

現在改檔成這樣：

```kconfig
choice
    bool "Pick a fruit"

config APPLE
    bool "Apple"

config BANANA
    bool "Banana"

endchoice
```

外面包了 `choice ... endchoice`。秘書讀：

#### Engine 讀第 1 行 `choice`

秘書：「`choice` 是 keyword，表示『開一個 group，下面的 config 都是這個 group 的 members，只能選一個』。」

筆記本：

```
筆記本：
┌──────────────────────────────┐
│ === CHOICE GROUP ===          │ ← 新開一個「群組」區塊
│   prompt: ?                   │
│   members: []                 │
└──────────────────────────────┘
```

#### 第 2 行 `    bool "Pick a fruit"`

是 choice 的屬性。

```
筆記本：
┌──────────────────────────────┐
│ === CHOICE GROUP ===          │
│   prompt: "Pick a fruit"      │ ← 補
│   members: []                 │
└──────────────────────────────┘
```

#### 第 3–5 行 `config APPLE / bool "Apple"`

跟 Round 1 一樣，但因為**現在在 choice block 內**，秘書多做一件事：把 `APPLE` 加進 choice 的 members 列表。

```
筆記本：
┌──────────────────────────────┐
│ === CHOICE GROUP ===          │
│   prompt: "Pick a fruit"      │
│   members: [APPLE]            │ ← 補
│                                │
│   ┌──────────────────────┐   │
│   │ option: APPLE         │   │
│   │   type: bool          │   │
│   │   label: "Apple"      │   │
│   └──────────────────────┘   │
└──────────────────────────────┘
```

#### 第 6–8 行 `config BANANA / bool "Banana"`

同樣。

```
筆記本：
┌──────────────────────────────┐
│ === CHOICE GROUP ===          │
│   prompt: "Pick a fruit"      │
│   members: [APPLE, BANANA]    │ ← 兩個都進來了
│                                │
│   ┌──────────────────────┐   │
│   │ option: APPLE         │   │
│   │   type: bool          │   │
│   │   label: "Apple"      │   │
│   └──────────────────────┘   │
│   ┌──────────────────────┐   │
│   │ option: BANANA        │   │
│   │   type: bool          │   │
│   │   label: "Banana"     │   │
│   └──────────────────────┘   │
└──────────────────────────────┘
```

#### 第 9 行 `endchoice`

秘書：「group 結束。後面 config 不再屬於這個 group。」

**這就是 ct-ng `arch.in` 在做的事**——只不過 group 內有 26 個 ARCH_* members（alpha、arc、arm、avr、...）而不是兩個 fruit。

#### 一個關鍵 rule

choice group 沒明寫 default 的話，**取 members 列表第一個**。

注意 members 列表是按**讀檔順序**塞進去的。第一個讀到的 `config` 就排第一個。

→ ct-ng 的 `arch.in` 因為按字母排，所以**第一個讀到的是 `ARCH_ALPHA`**。Error #22 fallback 到 alpha 就是這條 rule。

### Round 3：加 `if X ... endif`——條件區塊

換個檔：

```kconfig
config WANT_FRUIT
    bool "Do you want fruit?"

if WANT_FRUIT
config APPLE
    bool "Apple"

config BANANA
    bool "Banana"
endif
```

外層先宣告一個 `WANT_FRUIT` 開關，**裡面的 APPLE / BANANA 用 `if WANT_FRUIT ... endif` 包起來**。

#### Engine 讀 `if WANT_FRUIT`

秘書：「**進條件區塊**。從現在開始一直到 `endif`，我記每個 option 的時候要多寫一個註記：『**依賴 WANT_FRUIT=y**』。」

#### Engine 讀 `config APPLE`、`bool "Apple"`

跟 Round 1 一樣記筆記，**但多加註記**：

```
筆記本：
┌─────────────────────────────────┐
│ option: WANT_FRUIT               │
│   type: bool                     │
│   label: "Do you want fruit?"    │
├─────────────────────────────────┤
│ option: APPLE                    │
│   type: bool                     │
│   label: "Apple"                 │
│   depends on: WANT_FRUIT=y       │ ← 額外註記
├─────────────────────────────────┤
│ option: BANANA                   │
│   type: bool                     │
│   label: "Banana"                │
│   depends on: WANT_FRUIT=y       │ ← 同上
└─────────────────────────────────┘
```

#### Engine 讀 `endif`

「條件區塊結束。後面的 option 不再有這個註記。」

**意思**：APPLE 跟 BANANA 是否「真的存在 / 可用」，要看 WANT_FRUIT 最終是不是 y。WANT_FRUIT 是 n 的話，APPLE/BANANA 被強制 n、不管 user 怎麼寫。

→ **這就是 ct-ng `debug.in` 的 GDB master switch 機制**。`if DEBUG_GDB ... endif` 包起來 GDB_CROSS / GDB_GDBSERVER 等——都掛「depends on DEBUG_GDB=y」的註記。DEBUG_GDB=n 時這些 option 全部強制 n，Error #23 就是這條。

### Round 4：加 `source "other.in"`——跨檔引用

```kconfig
config WANT_FRUIT
    bool "Do you want fruit?"

if WANT_FRUIT
source "fruits.in"            ← 把另一個檔的內容拉進來
endif
```

`fruits.in` 內容：

```kconfig
config APPLE
    bool "Apple"

config BANANA
    bool "Banana"
```

#### Engine 讀到 `source "fruits.in"`

秘書：「先停下當前檔，去把 `fruits.in` 打開、整個從頭讀一遍。讀完再回來。」

→ 整個過程，秘書**還在條件區塊內**（沒走出 `if WANT_FRUIT`），所以讀 `fruits.in` 時記下的每個 option **都加上「depends on WANT_FRUIT=y」註記**。

讀完 `fruits.in` 回來，再讀下一行 `endif`，關掉條件區塊。

**這就是 ct-ng `debug.in` 怎麼把 GDB 細部選項拉進來**。`if DEBUG_GDB` 內用兩個 `source`：

```
source "config/versions/gdb.in"   → 拉進 GDB_V_16 等
source "config/debug/gdb.in"      → 拉進 GDB_CROSS 等（這個又 source 另外兩個）
```

**全部都繼承「depends on DEBUG_GDB=y」**。

### 階段總結

```
.in 檔 (一堆)        engine 邊讀邊記         筆記本
       ─────────────────────────────────► (內部結構)
                                              │
                                              │ 內容：所有可能的
                                              │       option 名單
                                              │       + 每個的 type
                                              │       + 每個的依賴
                                              │       + choice group
                                              │       + ...
```

到這步**還沒**碰 user 的 defconfig，也**還沒**決定誰要 y 誰要 n。只是把世界上「**可能存在的所有 option**」整理出來。

### Round 5：user defconfig 進來，秘書對著筆記本比對

user 給秘書一張小紙條（defconfig）：

```
CT_APPLE=y
CT_DURIAN=y       ← 拼錯：筆記本上沒這個
```

秘書一行一行處理：

#### 第 1 行 `CT_APPLE=y`

砍掉 `CT_` 前綴 → 找筆記本上有沒有 `APPLE`。

「有！這格的內容是 type=bool。把它的 value 欄填上 y。」

```
筆記本：
┌─────────────────────────────────┐
│ option: APPLE                    │
│   type: bool                     │
│   label: "Apple"                 │
│   depends on: WANT_FRUIT=y       │
│   value: y                       │ ← 剛填上
└─────────────────────────────────┘
```

#### 第 2 行 `CT_DURIAN=y`

找 `DURIAN`。

「筆記本上**沒這個名字**。」

按 kernel kconfig 設計（向後相容考量），秘書**不報錯、不警告**，反而**偷偷在筆記本上補一格新的**：

```
筆記本：
┌─────────────────────────────────┐
│ option: DURIAN                   │ ← 偷偷新加的
│   type: bool (預設)              │
│   label: (無)                    │
│   depends on: (無)               │
│   value: y                       │
│   ↑ 這格是孤兒——沒任何 .in 檔 │
│     宣告過它，沒人 select 它、    │
│     沒人 depends 它，所以對       │
│     最終結果零影響                │
└─────────────────────────────────┘
```

→ **這就是 Error #22 / Error #23 silent 失敗的關鍵**。user 拼錯字（`ARCH_arm` 應該是 `ARCH_ARM`），秘書找不到 → 補孤兒格 → 零警告、零作用。

### Round 6：秘書「結算」——把每個 option 的最終值算出來

秘書翻一遍筆記本，對每個 option 算出**最終要 y 還是 n**。規則：

1. **看 user 設了什麼**：value 欄有寫的就用 user 寫的
2. **看依賴**：option 有 `depends on X=y` 註記，X 最終是 n 的話，**強制本 option = n**（不管 user 寫什麼）
3. **看 choice group**：如果 group 內**沒任何 member 是 y**（用戶都沒選 / 拼錯字 / 等），**取 members 列表第一個強制 y**
4. **看 select 鏈**：option A 寫了 `select B`，A 是 y → B 強制 y

跑完所有規則，每個 option 都有一個確定的最終值。

#### Error #22 結算過程

```
user 寫：CT_ARCH_arm=y（小寫，孤兒）
       CT_ARCH_ARM=y 沒寫（因為 user 以為小寫 OK）

筆記本上 ARCH_ARM 的 value = (空)
筆記本上 ARCH_ALPHA 的 value = (空)
筆記本上 ARCH_ARC、ARCH_AVR、... value 都 = (空)

秘書算 choice GEN_CHOICE_ARCH：
  → group 內所有 26 個 member 都沒 y
  → 規則 3：取 members 列表第一個 → ARCH_ALPHA = y

.config 寫出：CT_ARCH_ALPHA=y
              CT_ARCH="alpha"
              ↑ 完全跟 user 期望的 ARM 無關
```

#### Error #23 結算過程

```
user 寫：CT_GDB_V_16=y
       CT_GDB_GDBSERVER=y
       CT_GDB_CROSS=y
       但漏寫 CT_DEBUG_GDB=y

筆記本上 DEBUG_GDB value = (空) → 算出最終 = n（沒人設、無 default）
筆記本上 GDB_V_16 的依賴：depends on DEBUG_GDB=y
                          → 規則 2：DEBUG_GDB 是 n → GDB_V_16 強制 n
                          → user 寫的 y 被覆蓋
同理 GDB_GDBSERVER、GDB_CROSS 全部強制 n

.config 寫出：CT_DEBUG_GDB is not set
              # CT_GDB_* 全部 is not set
              ↑ build 不會編 GDB
```

### Round 7：寫 `.config`

把筆記本上每個 option 的最終值，按 `CT_NAME=value` 格式寫成一個檔案。**這就是 `.config`**。

`ct-ng build` 接著讀這個 `.config`，跑 build script。

### 用語對照表

從現在開始你只要記右邊那欄：

| 技術書用的字 | 你心裡可以這樣想 |
|---|---|
| symbol | 一個 option 的名字 |
| symbol table | 秘書的筆記本（一格一格的 option 清單） |
| AST | 不用記。意思就是「秘書讀完 .in 檔後腦袋裡的結構」 |
| parser | 「讀檔器」。秘書「讀檔」這動作 |
| dependency | 註記在某 option 旁邊的「我要 y 必須先 X=y」條件 |
| resolve / 結算 | Round 6 那個「逐規則跑、算每個 option 最終值」過程 |
| forward implication | select 的中文。「我 = y → 強制 B = y」 |
| conditional source | `if X ... endif` 包起來的東西。「裡面所有 option 都掛 depends on X=y 註記」 |

---

## Part 2：抽象出 kconfig pattern 的精神

剝開 kernel kconfig 的具體細節，**核心精神是四件事**：

1. **WHAT 跟 HOW 切開**：宣告（`.in` 檔，宣告有哪些選項）跟處理（engine）兩條 codebase 獨立演化
2. **依賴推導取代手動串連**：你寫 `A select B`，不用自己 if/else——engine 跑 closure 自動把 B 也設成 y
3. **條件 scope**：`if X ... endif` 把一整塊東西的「存在性」綁在 X 上
4. **forward compatibility friendly**：unknown 不報錯（讓 schema 跨版本演進）

這個精神在軟體界 **被改頭換面用到很多地方**。

---

## Part 3：直接同血統（DSL + engine 二分）

| 系統 | 對應 kconfig 哪部分 | 例子 |
|---|---|---|
| **Linux distro package managers**（apt / dnf / pacman） | `Depends:` / `Conflicts:` / `Recommends:` 就是 kconfig 的 select / depends on / 互斥 group。背後 SAT solver 跑 closure | `apt install gcc` 自動拉一堆依賴 |
| **Nix / Guix** | derivation 是純宣告，evaluator 是 engine。可重現、條件 build 都很 kconfig 風 | `default.nix` ≈ defconfig |
| **Bazel / Buck / Pants** | `BUILD` 檔宣告 target + deps（`deps = [...]`），solver 算 build graph | 大型 monorepo build system |
| **Cargo (Rust) / npm / pip** | `Cargo.toml` / `package.json` 宣告依賴，resolver 算版本 closure。Cargo 的 feature flag (`features = ["foo"]`) 跟 cfg conditional 幾乎就是 kconfig | `cargo build --features bar` |
| **Terraform** | HCL 是 declarative DSL，plan/apply 是 engine。resource 之間靠 reference 自動建依賴圖 | `terraform plan` |
| **Kubernetes CRD + Controller** | YAML manifest 宣告 desired state，controller (engine) reconcile 到 actual state | declarative infra |
| **Ansible / Puppet / Chef** | 宣告 desired config，agent (engine) apply | config mgmt |

---

## Part 4：同精神，不同 form

| 系統 | 對應的 idea |
|---|---|
| **TypeScript / Rust 型別系統** | type declaration = symbol；trait/interface bound = depends on；type inference = engine 跑 closure（Hindley-Milner 演算法本質上是 constraint solver） |
| **React / Vue / Svelte reactive** | 你 declare 「component 用了哪些 state」，框架 track dependency graph 自動 re-render。跟 kconfig 的 select chain 同邏輯 |
| **Excel/Sheets formula engine** | 每個 cell 是 symbol，formula 是 depends on，engine 算 topological order 然後 recompute |
| **CSS cascade + selector specificity** | 一堆規則宣告 + engine 解決衝突 |
| **Datalog / Prolog** | 純宣告 fact + rule，engine 跑 closure 推結論。**理論上 kconfig 的 resolution 階段就是個簡化版 Datalog** |
| **GraphQL schema + resolver** | SDL 宣告 schema，runtime resolver 處理 query。`@include(if:)` / `@skip` directive 就是 kconfig 的 `if` block |
| **OpenPolicyAgent / Rego** | declarative policy，engine evaluate | 安全策略 |

---

## Part 5：學術領域——SPL / FOSD

最直接把 kconfig 思想升級成「**software design pattern**」的學術領域，叫做 **Software Product Lines (SPL)** 跟 **Feature-Oriented Software Development (FOSD)**。代表人物：Don Batory（UT Austin）、Krzysztof Czarnecki。

### 核心 idea

```
Feature Model（= 升級版 kconfig）
  └─ Feature1
       ├─ requires Feature2
       └─ conflicts with Feature3

Feature Composition Engine
  └─ 給你「該選哪些 feature」，產出對應的軟體成品
```

Linux kernel 在這領域常被當**最大規模 product line case study**（10000+ features = 10000+ kconfig symbols，產出無數個變體）。學者用 SAT solver 分析 kconfig dependency 的數學性質、找 dead features、檢查 consistency 等。

### 工具

- **FeatureIDE**（Eclipse plugin，視覺化編 feature model）
- **GUIDSL**（Batory 的 first-gen）
- **TVL** / **clafer**（更新的 feature modeling language）

### 論文起點

- 《Feature-Oriented Software Product Lines: Concepts and Implementation》（Apel/Batory/Kästner/Saake, 2013）——這本書整本就是 kconfig 精神的學術化版
- 《Out of the Tar Pit》（Moseley/Marks, 2006）——MIT-classic essay 倡議 declarative + relational

---

## Part 6：GoF 經典 design pattern 對應

kconfig 對應的不是單一 GoF pattern，是好幾個 pattern 組合的**架構級風格**：

| pattern | 對應 kconfig 哪部分 |
|---|---|
| **Interpreter** | `.in` DSL 有它自己的 interpreter |
| **Composite** | `if` / `choice` block 內含其他 declaration，遞迴結構 |
| **Visitor** | engine 遍歷整棵宣告樹做 resolution |
| **Strategy** | kconfig 不同前端（menuconfig TUI / nconfig / gconfig / xconfig）都吃同一個 backend，UI 是 plug-in |
| **Specification** | `depends on X && !Y` 的布林表達式組合 |

但這些 GoF pattern 都太低層級，**真正的「設計精神」是更高架構層的：「extract a declarative model + a resolver」這個 split**。

---

## Part 7：對 cross-toolchain repo 的具體啟示

- 你 cross-toolchain repo 已經繼承這個 pattern——`configs/*.defconfig` 是 user 宣告，ct-ng 是 engine
- 如果你要寫一個 wrapper（例如「給 user 選 target，自動產 defconfig + 跑 ct-ng」），可以**自己再加一層 declarative 模型**——例如 `targets.yaml` 宣告「我支援哪幾個 target tuple + 每個 target 需要哪些 patch / GCC 版本」，然後一個小 engine 把它編譯成 ct-ng defconfig。這就是 kconfig 精神套兩層

### 反過來檢查我們現有設計

| 我們現在做的 | kconfig pattern 對應 |
|---|---|
| `configs/x86_64-centos6-glibc212-gcc15.defconfig` 等 | declarative model（user 宣告 target 需求） |
| `ct-ng` CLI 跑 defconfig + build | engine |
| `patches/ct-ng-1.25-gcc15-backport/` | 對 engine 行為的 customization（不是 declarative） |
| `Dockerfile.phase1/2/3/4` | 把整套包成 reproducible build artifact |

**沒做但可以做**：

- **target 之間共用 declaration**：phase 1 跟 phase 4 都用 GCC 15 + 同一套 patch，現在是兩個 defconfig 各複製一份。如果寫個 meta-config 描述「target tuple + glibc 版本 + GCC 版本」，腳本展開成各自 defconfig，就少一個維護負擔
- **defconfig 之間的 dependency**：例如「想 build phase 2 必須先 build phase 1」現在沒明確表達，靠 Dockerfile 階層隱含。可改成 explicit dependency

---

## 延伸閱讀

- [`docker-experiments.md`](./docker-experiments.md) §2.2.5 + §2.3 + §2.4：實際踩到 kconfig 雷的紀錄（Error #22 case-sensitivity、Error #23 master switch）
- [`crosstool-ng-explained.md`](./crosstool-ng-explained.md)：ct-ng 18-step build pipeline 解剖（用 kconfig defconfig 驅動的下游 build engine）
- Linux kernel kconfig source：<https://github.com/torvalds/linux/tree/master/scripts/kconfig>
- kconfig DSL 規範：<https://www.kernel.org/doc/Documentation/kbuild/kconfig-language.txt>
