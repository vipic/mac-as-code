#!/bin/sh
# 唯一入口；任务从菜单进入，实现位于 scripts/。
set -u
ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
usage() {
    cat <<'EOF'
用法：sh mac.sh

从菜单配置电脑、备份、恢复或检查环境。
↑↓ 选择任务，Enter 执行；b 返回，q 退出，按键即时响应。

维护选项：
  --check   无网络的统一校验（需已安装 shellcheck）
  --help    显示帮助
EOF
}
if [ "$#" -eq 0 ]; then
    exec sh "$ROOT_DIR/scripts/workflow.sh"
fi
[ "$#" -eq 1 ] || { usage >&2; exit 1; }
case "$1" in
    --help) usage ;;
    --check) exec sh "$ROOT_DIR/scripts/check.sh" ;;
    *) echo "不支持该参数，请从菜单选择任务。" >&2; usage >&2; exit 1 ;;
esac
