#!/bin/sh
# 唯一日常入口；实现仍位于 scripts/。
set -u
ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
usage() {
    cat <<'EOF'
用法：sh init.sh [任务]

不带参数：选择配置、备份或恢复（需要交互终端）
  configure             实时查看差异，选择并应用到这台 Mac
  backup [目录]         预览并备份个人数据
  restore [快照目录]    预览并恢复；可先配置这台 Mac
  doctor                检查环境
  check                 无网络、无副作用的统一校验（需已安装 shellcheck）

自动执行（必须明确提供 --yes）
  configure --yes        应用可自动判断的差异；需手动确认的项目不执行
  backup --yes [目录]    使用固定备份范围创建快照
  restore --yes <目录>   恢复指定快照

旧的 --yes、--from、--skip-doctor 参数仍兼容全量装机。
EOF
}
case "${1:-}" in
    -h|--help|help) usage ;;
    check) shift; exec sh "$ROOT_DIR/scripts/check.sh" "$@" ;;
    doctor) shift; exec sh "$ROOT_DIR/scripts/doctor.sh" "$@" ;;
    --yes|-y|--from|--skip-doctor)
        if [ ! -t 0 ]; then
            explicit_yes=0
            for arg do case "$arg" in --yes|-y) explicit_yes=1 ;; esac; done
            [ "$explicit_yes" -eq 1 ] || { echo "非交互执行需要显式 --yes。" >&2; exit 1; }
        fi
        exec sh "$ROOT_DIR/scripts/workflow.sh" legacy "$@"
        ;;
    ''|configure|backup|restore) exec sh "$ROOT_DIR/scripts/workflow.sh" "$@" ;;
    *) echo "未知任务：$1" >&2; usage; exit 1 ;;
esac
