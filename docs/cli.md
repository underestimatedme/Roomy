# 腾地儿（Roomy）命令行工具

`roomy` 是腾地儿的独立原生命令行工具，复用图形界面的扫描、占用分析、应用关联、保护与恢复能力。支持 macOS 14 及以上；构建时自动选择本机 Apple Silicon 或 Intel 架构。

完整 CLI 免费，核心和 CLI 采用 MPL-2.0，不需要购买图形应用或联网激活。

命令一览：`scan`、`disk`、`apps`、`preview`、`clean`、`uninstall`、`history`、`restore`、`protect`、`tier`、`permissions`、`growth`、`schedule`、`version`。不提供应用更新、启动项目和项目归档命令，图形应用里也没有这些功能。
GUI 与 CLI 均免费；核心保护、执行检查、恢复能力保留，详见 [许可边界](licensing.md)。

## 构建与使用

在项目根目录运行：

```sh
bash app/build.sh cli
./app/build/roomy --help
./app/build/roomy version
```

普通应用构建也会将工具放入 `Roomy.app/Contents/Helpers/roomy`，与图形主程序分开，兼容不区分大小写的磁盘。独立构建不需要打开图形界面，也不需要图标打包。

独立核心源码包使用 `bash app/tools/build-cli.sh` 构建，完全不读取 GUI 的配置或资源。
构建后可使用 `python3 app/tools/package-cli.py --output app/build/cli-release` 生成匹配的二进制、
源码和校验清单。当前架构单独打包，输出目录必须不存在。
二进制包解压后使用包内 `bash install.sh --prefix DIRECTORY` 安装，也可以直接运行 `./roomy`。

可选安装：

```sh
bash app/tools/install-cli.sh
```

默认复制到 `~/.local/bin/roomy`；不会使用 sudo 或修改 shell 配置。安装器会提示 PATH 是否包含这个目录。可用 `--prefix DIRECTORY` 改目录，已有普通文件需明确 `--replace` 才能更新。构建目录保留 `roomy-scan-swift` 兼容入口。

## 只读操作

```sh
roomy scan --root ~/Projects
roomy disk ~/Downloads --files --limit 20
roomy disk ~/Projects --query node_modules --min-bytes 104857600
roomy apps --query Sublime
roomy preview /Applications/Sublime\ Text.app
roomy clean
roomy history
roomy protect list
```

`scan` 分类展示空间，`disk` 用同一索引按实际占用排序并支持搜索、文件筛选和分页。硬链接沿用原生去重规则。无法读取的内容明确计入诊断，不把零字节当作完整扫描。目录名中的终端控制字符被转义。

`apps` 和 `preview` 使用实际安装清单。运行状态无法检查时，只读预览会标明原因，卸载拒绝执行。应用名称不唯一时需改用准确安装路径。`clean` 使用与界面首批清单相同的规则与工具探测；不自动进入需要额外隐私授权的受保护文件夹，终端的读取权限与图形应用权限可能不同。

IntelliJ 的关联预览还会核对应用自带的 `product-info.json`：应用标识、产品代码及版本一致时，识别对应的 `Library/Caches/JetBrains` 和 `Library/Logs/JetBrains` 版本子目录，均需手动选择。对应的设置与插件目录仅供查看；其他版本、共享厂商目录、无法确认归属或存在目录链接的内容不授权处理。这项规则与图形应用共用。

`clean` 的应用缓存按应用与浏览器配置列出具体子目录。Chrome、Edge、Brave 的标准配置仅包含 `Cache` / `Code Cache`；Firefox 标准缓存配置仅包含 `cache2` / `startupCache` / `thumbnails`。Slack、Discord、Notion、Obsidian 的常规 Electron 目录仅包含 `Cache` / `Code Cache` / `GPUCache`。均需手动选择，并在每项处理前重查运行状态和安装归属。登录数据库、Cookie、网站存储、聊天附件及整个应用配置目录不加入此探测器的处理范围。

微信（`com.tencent.xinWeChat`）、WhatsApp（`net.whatsapp.WhatsApp`）和新 Teams（`com.microsoft.teams2`）现加入沙盒缓存探测：仅接受各自 `Data/Library/Caches/<应用标识>` 内结构明确的 `Cache.db` / SQLite 日志 / `fsCachedData` 网络缓存整组，以及 `Caches/WebKit/NetworkCache`。含其他内容的网络缓存整组保留。新 Teams 还检查应用沙盒及 Teams 专用组 `UBF8T346G9.com.microsoft.teams` 中 `Library/Application Support/Microsoft/MSTeams/EBWebView` 的标准配置，只列出 `Cache` / `Code Cache` / `GPUCache`；微软 Office / shared 组、WhatsApp 共享消息目录、媒体与聊天数据均保留。Teams 在应用外安装的 WebView 辅助进程运行时，也会锁定缓存。

沙盒读取失败会明确提示权限不足或目录不能安全读取，未计入可处理空间；支持路径不存在不代表整款应用占用为零。可在系统设置 → 隐私与安全性检查应用数据访问或完全磁盘访问权限：GUI 对应腾地儿（Roomy），CLI 对应启动 `roomy` 的终端；授权后重新打开并扫描。GUI 与终端权限分别由 macOS 管理，Roomy 不修改系统权限。定制目录及未确认的缓存格式继续保留。本机三款真实沙盒均被系统权限拒绝；目前功能边界已由私有样本验证，真实沙盒占用与版本目录仍待授权后验收。

## 清理、卸载和恢复

命令默认预览。先读取清单中的 `id`，再逐项执行：

```sh
roomy clean --id PREVIEW_ID --apply
roomy uninstall /Applications/Example.app --id PREVIEW_ID --apply
roomy restore RECOVERY_ID --apply
```

`PREVIEW_ID` 和 `RECOVERY_ID` 是需要替换的示意值。`clean --apply` 的确认见下文“MOVE 与 DELETE 双确认”；卸载要求输入 `MOVE`，恢复要求输入 `RESTORE`；其他输入取消。脚本场景可明确加 `--yes`，它必须与 `--apply` 一起使用，仍必须逐项指定 `--id`。没有全选执行或绕过保护的开关。

CLI 的预览 ID 绑定叶子文件身份、父目录设备/inode；应用关联另外绑定应用身份。预览后文件或父目录被替换，旧 ID 会被拒绝，需重新查看。ID 不应跨机器复用，也不能用 GUI 的内部 ID 代替。

每次执行重新扫描、读取保护清单，并沿用原生身份、符号链接、运行进程和共享归属核查。GUI 和 CLI 共用操作锁，同一时刻只能有一个进程修改记录；使用更新后的 GUI 时才具备这项协作保护，请关闭旧版本并重新启动新版。

### 四档与不能删

`clean` 把候选分成四组，输出和 JSON 中同名：

| 档位 | 名称 | 默认勾选 | 执行 |
|---|---|---|---|
| A | 放心清 | 是（图形界面；包括找不回的项） | 可执行 |
| B | 可选清 | 否 | 可执行 |
| C | 确认后清 | 否 | 逐项确认后可执行 |
| 不能删 | 不能删 | — | 始终不执行，只显示原因 |

“不能删”由硬条件决定：保护清单、所属应用或工具正在运行、有未提交改动的 worktree、被容器挂载的 Docker 卷等。换档、习惯学习和 CLI 都不能把东西移进或移出这一组；选择其中的 `--id` 会在执行前整体拒绝。

### MOVE 与 DELETE 双确认

`clean --id ID --apply` 先列出所选项目，再按能否找回分两步确认：

1. 可找回项（移入废纸篓）：终端输入 `MOVE`。
2. 找不回项（官方清理命令：`npm cache clean`、`go clean`、`pip cache purge`、`uv cache clean`、`pnpm store prune`、`brew cleanup`、`docker builder prune`，以及按预览列出的对象逐个 `docker volume/image/container rm`，另有 `simctl`、`ollama rm`）：另行输入 `DELETE`。这些项目由工具直接删除，不进废纸篓，无法找回。

只含一类时只问对应的一步；C 档项在预览中单独列在“以下为确认后清的项目”下。任一步输入其他内容或终端不是交互式，都在执行任何文件操作之前整体取消。脚本场景用 `--apply --yes`，同样必须逐项 `--id`，两类确认词都被 `--yes` 跳过，所以请只对已经看过预览的 ID 使用。

官方命令只用解析到的绝对路径，不拼接 shell 字符串。Docker 按预览列出的卷、镜像、容器逐个删除，不使用 `system prune`；构建缓存例外，用 `docker builder prune -f`，预览写明清除全部可回收构建缓存。整体清理类命令执行前复核工具路径、工具报告的缓存路径与预览一致且不是符号链接，不一致的项跳过并说明原因；对应工具（npm/npx、go、pip、uv、pnpm、brew）正在运行时，扫描时进“不能删”、执行时拒绝，读不到进程列表时降为 C 且执行时同样拒绝。整体清理命令最长等 30 分钟，超时会报告“可能已部分删除”；`brew cleanup` 以 `HOMEBREW_NO_AUTOREMOVE=1` 运行，不会顺带删除预览之外的无依赖软件包。`pnpm store prune` 与 `brew cleanup` 的回收量事先无法精确得知，显示为估算，不计入“已验证”。

不存在永久清空废纸篓的命令。移入同卷废纸篓不释放空间，输出分别记录移入废纸篓大小、永久删除大小（工具报告）和磁盘空闲实测变化，后者可能受其他进程影响（OrbStack/Docker 的磁盘镜像可能不会立刻缩小）。不可撤回动作的命令、对象列表和结果写入操作历史，无法恢复但可追溯。

### 清理报告的六段

不带 `--id` 的 `roomy clean` 预览依次输出六段，JSON 的 `data` 带对应字段：

1. 结论：当前可用空间；A、B、C、不能删各自大小；可找回与找不回的拆分；只清 A 以及清 A+B 后的预计可用空间。嵌套路径只算一次，估算项不计入“已验证”。
2. 空间去向：数据卷已用空间按顶层区域分布（`du -x` 口径，不跨挂载点）。
3. 读不到的空间：已用空间减去可统计部分；权限不足时显示“无法测量”，不显示为零。
4. 分档清单：A、B、C 与不能删，附分级依据。
5. 健康提醒（只读）：交换空间、失效的 Docker context、异常的 LaunchAgent、APFS 本地快照；命令只是文字建议，Roomy 不运行。
6. 清理顺序：先处理可找回的，确认没问题后再在 Finder 清空废纸篓，找不回的放最后，并显示废纸篓中由 Roomy 移入的大小。

“空间去向”需要额外走一遍磁盘，可能要几分钟，因此只在完整预览时进行；`--no-overview` 跳过这一遍，指定 `--id` 时也不统计，结论与健康提醒照常给出：

```sh
roomy clean --no-overview
roomy clean --json --no-overview
```

### 换档：`roomy tier`

档位调整对“这一类”生效（按归属、内容类型与必要的作用域，而不是单个路径），与图形界面共用同一份本机存储：

```sh
roomy tier list
roomy tier set ITEM_ID B
roomy tier set ITEM_ID B --apply
roomy tier undo KEYID --apply
roomy tier reset --apply
```

`tier list` 列出手动调整、Roomy 按习惯自动调整的类别以及历史（含依据）。`tier set ID A|B|C` 的 ID 取自当前 `clean` 清单；没有可信类别键的项目不能换档，不能换进或换出“不能删”。`set`、`undo`、`reset` 默认只预览，加 `--apply` 后需要终端输入 `TIER` 确认（`--yes` 跳过）。`undo KEYID` 撤销一条调整：手动调整回到出厂档位，Roomy 按习惯做的调整则固定在原来的档位（之后不再自动改动）；`reset` 清除全部手动调整，保留自动调整。手动调整优先于自动调整。换档只改变显示档位和默认勾选，不扩大执行权限；因安全原因（例如无法检查运行状态）降到 C 的项目，任何调整都不能把它抬回去。详见 [本地偏好学习](local-preferences.md)。


成功移走的项目保存原位置和废纸篓身份；卸载每完成一项立即保存记录。恢复拒绝覆盖同名内容。旧记录缺少身份或原路径时仍需在 Finder 手动处理，恢复失效的 LaunchAgent 文件（清理候选之一）不会自动重新启用后台服务。

保护操作直接表达保存意图：

```sh
roomy protect add ~/Projects/important-project
roomy protect list
roomy protect remove PROTECTION_ID
```

这些命令修改与图形界面共享的保护清单。`remove` 只取消保护，不删除该路径。

## 定时自动清理：`roomy schedule`

命令行支持独立的定时清理任务：到期后重新识别已授权的缓存目录、检查保护和运行状态，再移入废纸篓。图形版的定时扫描和容量提醒仍只读。两者的规则、后台服务分别管理；保护清单、操作锁、操作历史和恢复记录共用。

先将新版 CLI 安装到固定位置（例如 `~/.local/bin/roomy`），然后：

```sh
roomy schedule scopes
# 将下面的路径替换为上一条命令实际列出的完整缓存路径
roomy schedule add "每日缓存清理" --every-days 1 --scope "/实际的缓存路径" --apply
roomy schedule install --apply
roomy schedule status
roomy schedule list
roomy schedule history
```

- `scopes` 只列出内核可验证的应用可重建缓存和 Xcode 编译中间对象目录。`--scope` 可重复，必须逐个指定准确路径；不接受任意目录、全盘规则、通配符或工具永久删除命令。受保护范围不能新增授权，后续加入保护也会阻止执行。
- `add` 不带 `--apply` 只预览，加上后保存授权。安装调度是独立步骤，不会因预览或保存任务而自动注册系统后台。`--once` 表示仅执行一轮，默认重复。
- 间隔为 `--every-days N`（1–3650），按 N × 24 小时计算。第一轮从保存时开始计时，后续从上一轮完成时计时；不是每天固定钟点。启用已停用或阻断的任务会重新开始计时。
- `install --apply` 将当前 CLI 的绝对路径注册到当前用户 `~/Library/LaunchAgents/com.atlaspaces.roomy.cli-cleanup.plist`，登录期间约每 15 分钟检查到期任务，不使用 sudo。安装后移动或替换 CLI 路径，需要重新执行安装命令；系统若禁用后台活动，需要用户在系统设置中允许。
- 关机、注销或休眠期间不执行，不强制唤醒；恢复后下一轮检查合并处理到期工作，不补跑全部错过的次数。退出终端不影响已安装调度。
- 每轮重新探测归属、磁盘、文件身份、父目录、目录内容及保护；应用或 Xcode 正在运行时跳过相应范围，无法核验运行状态或权限时停止。每项动作前还会再次检查，GUI/CLI 正在修改文件时延后重试。
- 自动清理只移入废纸篓，不自动清空。同卷移动通常不立即释放空间；成功移动写入共享恢复记录，可用 `roomy history`、`roomy restore ID --apply` 找回。`schedule history` 查看任务结果，普通 `history` 同时包含自动执行的操作日志。

管理任务，以下 `TASK_ID` / `RUN_ID` 均替换为列表中的实际值：

```sh
roomy schedule disable TASK_ID --apply
roomy schedule enable TASK_ID --apply
roomy schedule remove TASK_ID --apply
roomy schedule uninstall --apply
```

停用和删除任务会停止后续项目；删除任务保留执行历史和恢复记录。卸载只移除命令行后台调度，保留任务数据。需要立即检查到期任务时用 `roomy schedule run --apply`；不带 `--apply` 只列出任务，不提前执行未到期任务。

变更和手动执行需要输入 `SCHEDULE` 确认；脚本可明确使用 `--apply --yes`。系统调度使用同一入口及这两个参数，其授权来自此前保存的逐项缓存范围。

不可安全重试或执行中断会阻断规则，`list` 显示原因，`run` 返回状态 3。若有结果不确定的项目，先人工核对原目录、废纸篓及恢复记录，再执行 `roomy schedule acknowledge RUN_ID --apply`，最后 `enable TASK_ID --apply` 重新计时；不会自动重放不确定的删除。能识别的执行前临时错误按 30 分钟、2 小时、24 小时退避，第 4 次失败阻断。

任务保存在 `~/Library/Application Support/Roomy/CLISchedules/automation.json`，不会启用或迁移 GUI 的旧自动清理规则。该功能属于新源码构建，已有签名 0.1.8 发布包需重新构建与公证后才包含它。

## JSON 与退出状态

```sh
roomy disk ~/Projects --files --json
roomy preview /Applications/Example.app --json -
roomy scan --root ~/Projects --json ./new-report.json
```

标准输出 JSON 不混入进度或确认提示，提示写标准错误。需把命令的位置参数放在可选的 `--json FILE` 之前；单独 `--json` 或 `--json -` 输出到标准输出。JSON 顶层格式为：

```json
{"schemaVersion":1,"command":"disk","readOnly":true,"data":{"page":{}}}
```

`scan` 的 `data.report`、`disk` 的 `data.page`、`preview/uninstall` 的 `data.parts`、`clean` 的 `data.entries`、执行后的 `data.outcomes` 提供对应结果。恢复项目通过 `history` 中 `data.recoverable[].id` 选择。

文件导出在扫描/操作之前以独占方式创建目标，拒绝覆盖现有文件、符号链接或无法写入的目录。失败时可能留下新建的空报告。执行完成后的写盘失败会把已产生的 JSON 结果保留到标准输出，并返回 3；不要把它当作未执行。

| 退出状态 | 含义 |
|---|---|
| 0 | 命令完成，包括只读预览；不代表已经清理 |
| 1 | 读取/执行失败或用户取消；错误写标准错误 |
| 2 | 参数错误，不开始扫描或文件操作 |
| 3 | 项目部分失败、记录保存问题或执行后导出失败；检查逐项结果 |

共享数据位于 `~/Library/Application Support/Roomy/`：保护 `protected-cleanup.json`、恢复 `pending-trash.json`、操作 `operations.jsonl`。只读历史/保护查询不改这些文件。

## 验证范围

完整入口测试只使用生成目录验证帮助、参数失败、扫描 JSON、硬盘搜索、终端字符转义与文件导出。原生样本验证旧预览拒绝替换文件/父目录、进程互斥、保护拒绝、MOVE/DELETE 分步确认与“不能删”拒绝、移到私有测试废纸篓后重新加载记录并按字节恢复，以及中途进程检查失败时保留已完成卸载项目。

运行：

```sh
python3 app/tests/run-reliability.py
ROOMY_CLI_PATH=app/build/roomy python3 app/tests/cli-integration-test.py
```

跨系统和 Intel CI 已接入同一组 CLI 检查和对应架构构建；未执行的云端结果不算通过。测试期间不对真实用户文件进行清理或卸载；本机验收只运行只读扫描，见 `artifacts/tiered-cleanup-v2-validation-*.md`。

## 维护与长期变化

免费 CLI 与 GUI 共用本机记录，以下命令无需 GUI 许可证：

```sh
roomy permissions
roomy growth ~/Projects
roomy growth
```

`growth PATH` 完整扫描并保存本地基线；同一范围第二次完整扫描才比较，对比对象是最近一次完整采样（清理扫描也会异步更新同一份记录）。权限缺失或读取失败不会覆盖已有完整基线，历史记录保留。差值是已分配空间变化，不是保证可释放空间。
