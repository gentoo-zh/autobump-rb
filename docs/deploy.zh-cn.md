# 部署到 gentoo-zh CI(运维)

autobump-rb 作为引擎运行于 gentoo-zh/overlay 的 `.github/workflows/autobump.yml`:该 workflow 每次 clone 本仓库(公开,无需 token)、安装 `dev-lang/ruby`,对 nvchecker issue 队列运行 overlay 侧的 `scripts/autobump-sweep.sh`(通过 `AUTOBUMP_ENGINE` 指向 `bin/autobump`)。overlay 的日常用法见 overlay 仓库的 `scripts/autobump.md`。

## 配置顺序

### 合并本身安全,无需预先配置
autobump.yml 仅有 `workflow_dispatch`(手动)触发,cron 处于注释状态,无 push / pull_request / schedule。合并进 master **不会自动运行**,以下配置可在合并后进行,不影响合并。

### 合并后、首次 dispatch 前需配置
1. **创建 GitHub App** 并安装至 gentoo-zh/overlay(仅授权此仓库),Repository permissions:
   - **Contents: Read and write**(push topic 分支)
   - **Pull requests: Read and write**(创建 PR)
   - **Issues: Read and write**(在 nvchecker issue 上评论)
   - (Metadata: Read 会自动包含)

   任一权限缺失,首次实际运行会在 `gh pr create` / `gh issue comment` / `git push` 阶段返回 403,而非在 mint token 阶段报错。
2. **两个 repo secret**:
   - `APP_CLIENT_ID`:App 设置页的 Client ID
   - `APP_PRIVATE_KEY`:App 页 "Generate a private key" 下载的 .pem **全文**
3. (可选)repo Settings → Actions → 勾选 "Allow GitHub Actions to create and approve pull requests"。注:本流程使用 App token 创建 PR,不经过默认 GITHUB_TOKEN,此开关实际不影响 App token,启用无害但非必需。

### 首次 dispatch 后、启用 cron 前
1. 先手动运行 **Actions → autobump-selftest**(不创建 PR、不 bump,使用默认 github.token,无需 App),验证容器 setup 与引擎判定在真实 CI 中通过。
2. (可选)手动运行 **Actions → autobump-trial**(`targets` 填 nvchecker issue 号),在容器内对候选包做真实 build-test(bump + emerge + install + pkgcheck),不创建 PR、不需 opt-in、不需 App;用于确认某个尚未开启的包能机械 build 通过。
3. 再手动 dispatch **autobump**(`limit` 先填 1 测试单个),确认其正常创建 PR 并通过 emerge-on-pr。
4. 观察数轮稳定后,取消 autobump.yml 顶部的 cron 注释,启用每日自动运行。

## 引擎更新
引擎代码位于本仓库(公开),workflow 每次 clone 默认分支。修改引擎后 push 本仓库,下次 CI 即自动使用新版本,无需改动 overlay。如需固定版本 / 便于审计,可在 autobump.yml 的 clone 步骤添加 `ref: <tag 或 sha>`。

## 状态缓存
处理结果记录于 `$XDG_STATE_HOME/autobump/done.list`(CI 中 workflow 已将 XDG_STATE_HOME 固定为 `/root/.local/state`,与 actions/cache 的 path 对齐;否则容器内 HOME 为 /github/home,状态不落盘)。如需强制重新处理:
- **CI**:仓库 Actions → Caches,删除 `autobump-state-*` 缓存条目(下次 sweep 从空状态开始),或等待上游发布新版本自动重试。
- **本地**:删除 done.list 中对应的行。

## emerge-on-pr 是最后一道检查
引擎自身的 emerge 仅运行单 profile,属于预筛。PR 上的 `emerge-on-pr` 会运行 openrc 与 systemd 两个 profile——引擎侧通过、PR 侧失败,说明该检查生效。所有 PR 均需人工确认后合并。

## 容器环境注意事项
- make.conf 中的 `$(nproc)` 需在 workflow 中先展开再写入(portage 不执行命令替换,否则报 bad-substitution)。
- 纯净 stage3 中 `app-portage/pkgdev` + `pkgcheck`、`dev-vcs/github-cli` 位于 `dev-util/` 类别(pkgcore 类别迁移)。
- 需显式写入 gentoo `repos.conf`(pkgcore 不识别 portage 内置默认,否则 `pkgdev manifest` 报 "gentoo undefined")。
- 非自由软件包需 `ACCEPT_LICENSE="*"`,否则 emerge mask 会导致反复 defer。
- 需安装 `net-misc/curl`(stage3 仅有 wget),否则引擎复验 dead-URL 时会失败。
- 重依赖(webkit-gtk、qtwebengine 等)的 binpkg 是按特定 USE 编的;需在 `/etc/portage/package.use/ci-binhost` 中对齐 USE(`net-libs/webkit-gtk keyring`、`dev-qt/qtwebengine bindist`,**与 `emerge-on-pr.yml` 保持一致**)。否则 USE 不匹配 → binpkg 被拒 → 从源码编译超时。碰到某个重依赖仍显示 `[ebuild]` 时,在此追加对应 USE;可用 autobump-rb 的 `binpkg-check.yml`(手动 dispatch)排查。

## 引擎开发
- `bash test/decisions.sh`:golden 决策测试——对 `test/fixtures` 运行分类器,与 `test/decisions.tsv` 中冻结的期望判定比对,判定改变即 fail。
- `ruby test/pr_body.rb`:PR body 的 golden 测试,断言各情形下生成的正文结构。
- `sudo bash test/e2e.sh`:hermetic 端到端,实际 emerge 一个 fixture 套件并断言 commit 干净。
- `tools/ci-mock/`:本地使用 docker 启动 `gentoo/stage3` 容器,复现 CI 环境运行真实包。

架构与判定细节见 `DESIGN.md`。
