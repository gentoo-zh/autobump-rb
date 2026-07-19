# autobump-rb

[English](README.md)

維護 Gentoo overlay 中**機械性**版本升級的確定性引擎:給定套件與新版本,若可機械處理則完成一次乾淨的
升級——複製 ebuild、重新抓取、重建 Manifest、build 測試、執行 QA gate、commit、建立 PR;否則停止並輸出
一份**證據包**,說明本次升級為何非機械安全。

每個套件可選的 `keep_old = N` 會在升級時保留最近 N 個版本(新增新版 ebuild、移除更舊的;`0` 表示全部
保留),供刻意保留多個版本的套件使用。

僅執行可證明安全的升級。需要判斷的情況(新依賴、大版本跳變、過時的 source pin、build 選項變化)均會
escalate,不依據推測進行修改。機械路徑中不含 LLM。

## 退出碼契約

下游(sweep 驅動、CI、judge)全部依這三個退出碼行事:

| 碼 | 意義 | 誰來處理 |
|---|---|---|
| **0** | 機械升級完成(或 `--check` 下*會*完成) | 沒人 —— 合併 PR 即可 |
| **2** | 臨時 defer:前置條件不滿足、抓取失敗、build 逾時、依賴解析問題 | 下一輪重試 |
| **3** | escalate:非機械安全,已寫出證據包 | judge 或人 |

## 用法

    ruby bin/autobump <cat/pkg> <newver> --check      # 只分類:mechanical (0) 或 escalate (3)
    ruby bin/autobump <issue#> --check                # 先解析一個 nvchecker bump issue
    ruby bin/autobump <cat/pkg> <newver> --pr         # 完整流程:build 測試、commit、建立 PR
    ruby bin/autobump <cat/pkg> <newver> --install    # 本地 build 測試:build+install+pkgcheck、本地 commit、不 push/PR

    rake                                              # syntax + golden 決策測試(CI 執行的項目)
    bash test/decisions.sh                            # 單獨執行 golden 決策測試(hermetic fixtures)
    sudo bash test/e2e.sh                             # hermetic 端到端:實際 emerge 一個 fixture 套件

`--install` 不帶 `--pr` 為本地 build 測試——跑完整 pipeline 到本地 commit,但不 push;overlay 的
`autobump-trial.yml` 用它對尚未開啟的候選套件做 build 測試。

不限於 gentoo-zh:`AUTOBUMP_REPO`(任意 overlay checkout)、`AUTOBUMP_UPSTREAM_REPO`(任意 GitHub
倉庫)均由 env 驅動;預設值在 dev box(fork clone + sudo)與 CI(root、canonical checkout)下均可直接使用。

## 測試

- **Golden 決策測試**(`test/decisions.sh`,hermetic,CI 執行)—— 對 `test/fixtures`(涵蓋每個分類分支)
  執行分類器,每項判定與凍結於 `test/decisions.tsv` 的期望值比對,判定改變即 fail。
- **端到端**(`test/e2e.sh`,CI 的 gentoo 容器)—— 實際對一個拋棄式 fixture 執行完整 pipeline,斷言
  commit 乾淨,最後 unmerge。

設計說明見 [`DESIGN.md`](DESIGN.md)。GPL-2。
