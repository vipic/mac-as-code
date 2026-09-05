#!/bin/sh
set -u

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"
# shellcheck source=common.sh
. "$SCRIPTS_DIR/common.sh"

BREWFILE="$ROOT_DIR/config/Brewfile"
FAIL_COUNT=0

init_results

#############################
## 安装 App Store 应用（mas）##
#############################

if [ "${MAC_AS_CODE_SKIP_MAS:-}" = "1" ]; then
    echo "⏭️  计划中未选中 App Store 应用"
    finalize_results_if_owned
    exit 0
fi

if [ ! -f "$BREWFILE" ]; then
    echo "❌ 未找到 Brewfile：$BREWFILE"
    record_result "FAIL" "Brewfile" "文件不存在"
    finalize_results_if_owned
    exit 1
fi

MAS_LIST="$(mktemp -t mac-as-code-maslist.XXXXXX)"
parse_brewfile "$BREWFILE" >"$MAS_LIST"

MAS_TOTAL=0
while IFS='|' read -r type name id; do
    [ "$type" = "mas" ] || continue
    if plan_item_enabled mas "$name"; then
        MAS_TOTAL=$((MAS_TOTAL + 1))
    fi
done <"$MAS_LIST"

if [ "$MAS_TOTAL" -eq 0 ]; then
    echo "ℹ️  没有需要安装的 App Store 应用，跳过"
    record_result "SKIP" "mas" "无选中条目"
    rm -f "$MAS_LIST"
    finalize_results_if_owned
    exit 0
fi

if ! command -v brew >/dev/null 2>&1; then
    echo "❌ brew 未安装，请从 sh mac.sh 的配置菜单安装软件"
    record_result "FAIL" "mas" "brew 未安装"
    rm -f "$MAS_LIST"
    finalize_results_if_owned
    exit 1
fi

# mas CLI 本身来自 Brewfile；若单独跑 mas.sh 时尚未安装，先装上
if ! command -v mas >/dev/null 2>&1; then
    echo "📦 未检测到 mas，正在安装..."
    if ! brew install --formula mas; then
        echo "❌ mas 安装失败"
        record_result "FAIL" "mas" "CLI 安装失败"
        rm -f "$MAS_LIST"
        finalize_results_if_owned
        exit 1
    fi
fi

# 全部已安装则无需登录门禁
NEED_INSTALL=0
while IFS='|' read -r type name id; do
    [ "$type" = "mas" ] || continue
    plan_item_enabled mas "$name" || continue
    if ! mas list 2>/dev/null | awk '{print $1}' | grep -qx "$id"; then
        NEED_INSTALL=1
        break
    fi
done <"$MAS_LIST"

if [ "$NEED_INSTALL" -eq 0 ]; then
    echo "✅ 选中的 App Store 应用均已安装"
    while IFS='|' read -r type name id; do
        [ "$type" = "mas" ] || continue
        plan_item_enabled mas "$name" || continue
        record_result "OK" "mas:$name" "已安装"
    done <"$MAS_LIST"
    rm -f "$MAS_LIST"
    finalize_results_if_owned
    exit 0
fi

##############################################
## 登录门禁：init 开头已确认则可跳过；单独运行 mas.sh 时仍询问
##############################################

# 装机计划里已多选过；此处只补登录，不再问「全部跳过/继续」
if [ "${MAC_AS_CODE_MAS_READY:-}" = "1" ] || apple_id_signed_in; then
    if apple_id_signed_in; then
        echo "✅ Apple ID：$(apple_id_account)，按多选清单安装"
    else
        echo "✅ 按多选清单安装 App Store 应用"
    fi
else
    echo "⚠️  未检测到 Apple ID，打开 App Store，登录后按 Enter"
    open -a "App Store" 2>/dev/null || true
    while true; do
        printf "登录完成后按 Enter > "
        if ! read -r _; then
            break
        fi
        if apple_id_signed_in; then
            echo "✅ 已检测到 Apple ID：$(apple_id_account)"
            break
        fi
        echo "仍未检测到登录，请登录后再按 Enter（或 Ctrl+C 中止）"
        open -a "App Store" 2>/dev/null || true
    done
fi

install_mas_app() {
    name="$1"
    id="$2"
    index="$3"
    total="$4"

    if mas list 2>/dev/null | awk '{print $1}' | grep -qx "$id"; then
        echo "✅ [$index/$total] $name 已安装，跳过"
        record_result "OK" "mas:$name" "已安装"
        return 0
    fi

    echo "📱 [$index/$total] 正在安装：${name}（id: ${id}）"
    if mas install "$id" 2>/dev/null || mas get "$id"; then
        echo "✅ [$index/$total] $name 安装完成"
        record_result "OK" "mas:$name" "安装成功"
        return 0
    fi

    echo "❌ [$index/$total] 安装失败：$name"
    record_result "FAIL" "mas:$name" "安装失败（请确认已登录且账号可获取该应用）"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    return 1
}

echo
echo "📦 逐个安装 App Store 应用..."
echo "   单个失败会记录并继续，不会整批中断。"

MAS_INDEX=0
while IFS='|' read -r type name id <&3; do
    [ "$type" = "mas" ] || continue
    plan_item_enabled mas "$name" || continue
    MAS_INDEX=$((MAS_INDEX + 1))
    install_mas_app "$name" "$id" "$MAS_INDEX" "$MAS_TOTAL" || true
done 3<"$MAS_LIST"

rm -f "$MAS_LIST"
finalize_results_if_owned

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
exit 0
