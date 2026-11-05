#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Build the complete free CLI without any GUI files, assets, or activation.
set -euo pipefail
cd "$(dirname "$0")/.."
task_arch="${ROOMY_BUILD_ARCH:-$(uname -m)}"
case "$task_arch" in arm64|x86_64) ;; *) echo "Unsupported architecture: $task_arch" >&2; exit 2 ;; esac
task_sources=()
while IFS= read -r -d '' task_source; do
  task_sources+=("$task_source")
done < <(find Sources/Scanner -name '*.swift' -print0)
[ "${#task_sources[@]}" -gt 0 ] || { echo 'Missing Roomy core sources' >&2; exit 1; }
task_sources+=(cli/*.swift)
mkdir -p build
export SWIFT_MODULECACHE_PATH="${SWIFT_MODULECACHE_PATH:-${PWD}/build/swift-module-cache}"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-${PWD}/build/clang-module-cache}"
task_inputs="$(mktemp build/roomy-inputs.XXXXXX)"
trap 'rm -f "$task_inputs"' EXIT
python3 - "$task_arch" "$task_inputs" "${task_sources[@]}" <<'PY'
import hashlib
import json
from pathlib import Path
import sys
inputs = {"schemaVersion": 1, "architecture": sys.argv[1],
          "sourceFiles": {"app/" + Path(p).as_posix(): hashlib.sha256(Path(p).read_bytes()).hexdigest() for p in sys.argv[3:]}}
Path(sys.argv[2]).write_text(json.dumps(inputs))
PY
swiftc -O -whole-module-optimization -target "$task_arch-apple-macos14.0" -framework CoreServices -framework CryptoKit \
  "${task_sources[@]}" -o build/roomy
codesign --force --sign - build/roomy
python3 - "$task_inputs" <<'PY'
import hashlib
import json
from pathlib import Path
import sys
files = sorted(Path("Sources/Scanner").rglob("*.swift")) + sorted(Path("cli").glob("*.swift"))
receipt = json.loads(Path(sys.argv[1]).read_text())
current = {"app/" + p.as_posix(): hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
if receipt["sourceFiles"] != current:
    raise SystemExit("source inputs changed during compilation; rebuild the CLI")
receipt["binarySHA256"] = hashlib.sha256(Path("build/roomy").read_bytes()).hexdigest()
Path("build/roomy-build.json").write_text(json.dumps(receipt, indent=2) + "\n")
PY
ln -sfn roomy build/roomy-scan-swift
echo '✓ build/roomy（免费独立 CLI；兼容 roomy-scan-swift）'
