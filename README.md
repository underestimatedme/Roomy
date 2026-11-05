# Roomy · 免费原生命令行

这是 Roomy 的独立核心/CLI 源码包，采用 GPL-3.0-only。它包含完整命令行工作流和相关测试，
不包含图形应用。文件范围见 LICENSE；完整许可见 LICENSES/GPL-3.0-only.txt。

需要 macOS 14+ 和 Apple Command Line Tools，支持 Apple Silicon 与 Intel。

```sh
bash app/tools/build-cli.sh
./app/build/roomy --help
./app/build/roomy disk ~/Downloads --files --json
bash app/tools/install-cli.sh
```

构建不需要 GUI 文件、图标、购买或激活。使用说明见 docs/cli.md。
清理、卸载、恢复默认只预览；执行需要明确选择与确认，沿用原生保护。
移入同卷废纸篓不等于释放磁盘空间。

运行核心与 CLI 回归（仅使用生成样本处理文件）：

```sh
python3 app/tests/run-reliability.py --core-only
ROOMY_CLI_PATH=app/build/roomy python3 app/tests/cli-integration-test.py
```

完整图形产品：Roomy 腾地儿。核心与完整 CLI 的公开仓库为 [underestimatedme/Roomy](https://github.com/underestimatedme/Roomy)。GUI 源码另行私有维护，不包含在此仓库中。

支持空间扫描、大文件查找、应用关联预览、逐项清理与卸载、保护、历史、恢复、空间增长、清理档位调整，以及 `roomy schedule` 定时缓存清理。详细命令与边界见 [使用说明](docs/cli.md)。

本版本采用 **GNU GPL v3 only**（SPDX：`GPL-3.0-only`）；完整条款见 `LICENSES/GPL-3.0-only.txt`。
