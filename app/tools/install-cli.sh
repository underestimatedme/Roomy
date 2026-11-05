#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
# Explicitly invoked installer. Never changes shell startup files or uses sudo.
set -euo pipefail
task_prefix="${HOME}/.local/bin"
task_replace=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --help|-h)
      echo 'Usage: bash app/tools/install-cli.sh [--prefix DIRECTORY] [--replace]'
      echo '默认安装到 ~/.local/bin；不会修改 shell 设置。已有文件需明确 --replace。'
      exit 0 ;;
    --prefix)
      [ "$#" -ge 2 ] || { echo '--prefix 缺少目录' >&2; exit 2; }
      task_prefix="$2"; shift 2 ;;
    --replace) task_replace=true; shift ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
done
task_repo="$(cd "$(dirname "$0")/../.." && pwd)"
task_source="${task_repo}/app/build/roomy"
# The binary distribution puts this installer beside the independent CLI.
task_installer_dir="$(cd "$(dirname "$0")" && pwd)"
if [ -x "${task_installer_dir}/roomy" ]; then
  task_source="${task_installer_dir}/roomy"
fi
[ -x "$task_source" ] || { echo '请先运行 bash app/build.sh cli 构建工具。' >&2; exit 1; }
[ -n "$task_prefix" ] && [[ "$task_prefix" != -* ]] || { echo '安装目录不合法' >&2; exit 2; }
mkdir -p "$task_prefix"
task_prefix="$(cd "$task_prefix" && pwd -P)"
task_target="${task_prefix}/roomy"
if [ -e "$task_target" ] || [ -L "$task_target" ]; then
  [ "$task_replace" = true ] || { echo '目标已存在，未覆盖；更新时明确使用 --replace。' >&2; exit 1; }
  [ ! -L "$task_target" ] && [ -f "$task_target" ] || { echo '目标不是普通文件，未覆盖。' >&2; exit 1; }
fi
/usr/bin/install -m 755 "$task_source" "$task_target"
echo "已安装：$task_target"
case ":${PATH}:" in *":${task_prefix}:"*) ;; *) echo "请将 $task_prefix 加入 PATH，或直接使用上述完整路径。" ;; esac
