#!/bin/sh
# 本地与 CI 共用；不安装工具、不访问网络、不操作用户配置。
set -eu
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
[ "$#" -eq 0 ] || { echo "用法：sh mac.sh --check" >&2; exit 1; }
command -v shellcheck >/dev/null 2>&1 || { echo "缺少 shellcheck，请先安装后再运行校验。" >&2; exit 1; }
for script in ./*.sh ./scripts/*.sh ./config/*.sh ./config/recipes/*.sh ./tests/*.sh ./tests/fixtures/*.sh; do
    bash -n "$script"
done
shellcheck -x -P SCRIPTDIR ./*.sh ./scripts/*.sh ./config/*.sh ./config/recipes/*.sh ./tests/*.sh ./tests/fixtures/*.sh
sh scripts/check_format.sh --self-test
sh tests/audit_test.sh
sh tests/workflow_test.sh
echo "全部校验通过。"
