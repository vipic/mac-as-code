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
## 安装 Homebrew 以及一些软件 ##
#############################

if ! command -v brew >/dev/null 2>&1; then
    echo "🍺 安装 Homebrew..."
    echo "🔐 安装 Homebrew 可能需要管理员密码，请留意终端或系统弹窗…"
    if ! /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"; then
        echo "❌ Homebrew 安装失败"
        record_result "FAIL" "Homebrew" "安装失败"
        finalize_results_if_owned
        exit 1
    fi

    # arm64 架构需要将 brew 加入环境变量
    if [ "$(uname -m)" = "arm64" ]; then
        echo "🔧 配置 Apple Silicon 环境..."
        eval "$(/opt/homebrew/bin/brew shellenv)"
    fi
    record_result "OK" "Homebrew" "安装成功"
else
    echo "✅ Homebrew 已安装"
    record_result "OK" "Homebrew" "已安装"
fi

if [ ! -f "$BREWFILE" ]; then
    echo "❌ 未找到 Brewfile：$BREWFILE"
    record_result "FAIL" "Brewfile" "文件不存在"
    finalize_results_if_owned
    exit 1
fi

##############################################
## 逐个安装 Brewfile 中的依赖（失败继续，最后汇总）
## tips: 备份当前电脑的依赖，使用 `brew bundle dump --describe --force --file="~/xxx/Brewfile"`
##############################################

install_formula() {
    name="$1"
    index="$2"
    total="$3"

    if brew list --formula "$name" >/dev/null 2>&1; then
        echo "✅ [$index/$total] $name 已安装，跳过"
        record_result "OK" "brew:$name" "已安装"
        return 0
    fi

    echo "⬇️  [$index/$total] 正在下载：$name"
    if ! brew fetch --formula --deps "$name"; then
        echo "❌ [$index/$total] 下载失败：$name"
        record_result "FAIL" "brew:$name" "下载失败"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        return 1
    fi

    echo "📦 [$index/$total] 正在安装：$name"
    if ! brew install --formula "$name"; then
        echo "❌ [$index/$total] 安装失败：$name"
        record_result "FAIL" "brew:$name" "安装失败"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        return 1
    fi

    echo "✅ [$index/$total] $name 安装完成"
    record_result "OK" "brew:$name" "安装成功"
    return 0
}

install_cask() {
    name="$1"
    index="$2"
    total="$3"

    if brew list --cask "$name" >/dev/null 2>&1; then
        echo "✅ [$index/$total] $name 已安装，跳过"
        record_result "OK" "cask:$name" "已安装"
        return 0
    fi

    echo "⬇️  [$index/$total] 正在下载：$name"
    # brew fetch 的 --deps 与 --cask 互斥，cask 只拉自身安装包
    if ! brew fetch --cask "$name"; then
        echo "❌ [$index/$total] 下载失败：$name"
        record_result "FAIL" "cask:$name" "下载失败"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        return 1
    fi

    echo "📦 [$index/$total] 正在安装：$name"
    echo "🔐 部分 cask 安装会弹出管理员验证，请在本机确认…"
    if ! brew install --cask "$name"; then
        echo "❌ [$index/$total] 安装失败：$name"
        record_result "FAIL" "cask:$name" "安装失败"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        return 1
    fi

    echo "✅ [$index/$total] $name 安装完成"
    record_result "OK" "cask:$name" "安装成功"
    return 0
}

# 先统计数量，再按 Brewfile 顺序安装（formula / cask）；mas 交给 mas.sh
# 进度编号按 Brewfile 总顺序统一递增，避免 cask/formula 分套计数导致 [3/19] 后突然变成 [1/14]
BREW_LIST="$(mktemp -t mac-as-code-brewlist.XXXXXX)"
parse_brewfile "$BREWFILE" >"$BREW_LIST"

FORMULA_TOTAL=0
CASK_TOTAL=0
while IFS='|' read -r type _name _id; do
    case "$type" in
        brew) FORMULA_TOTAL=$((FORMULA_TOTAL + 1)) ;;
        cask) CASK_TOTAL=$((CASK_TOTAL + 1)) ;;
    esac
done <"$BREW_LIST"

# 若有装机计划，只统计 / 安装选中的条目
BREW_TOTAL=0
while IFS='|' read -r type name _id; do
    case "$type" in
        brew|cask)
            if plan_item_enabled "$type" "$name"; then
                BREW_TOTAL=$((BREW_TOTAL + 1))
            fi
            ;;
    esac
done <"$BREW_LIST"

echo
if [ "$BREW_TOTAL" -eq 0 ]; then
    echo "ℹ️  未选中任何 Homebrew formula/cask，跳过软件安装循环"
else
    echo "📦 按计划逐个安装软件（共 ${BREW_TOTAL}，Brewfile 中 formula ${FORMULA_TOTAL} + cask ${CASK_TOTAL}）..."
    echo "   单个失败会记录并继续，不会整批中断。"
    echo "🔐 安装 GUI 应用（cask）时可能多次要求管理员密码，属正常情况。"
fi

BREW_INDEX=0
# 用 fd3 读列表，避免 brew/cask 安装时 stdin 被占用而弹不出管理员验证
while IFS='|' read -r type name _id <&3; do
    case "$type" in
        brew)
            if ! plan_item_enabled brew "$name"; then
                continue
            fi
            BREW_INDEX=$((BREW_INDEX + 1))
            install_formula "$name" "$BREW_INDEX" "$BREW_TOTAL" || true
            ;;
        cask)
            if ! plan_item_enabled cask "$name"; then
                continue
            fi
            BREW_INDEX=$((BREW_INDEX + 1))
            install_cask "$name" "$BREW_INDEX" "$BREW_TOTAL" || true
            ;;
    esac
done 3<"$BREW_LIST"

rm -f "$BREW_LIST"

# 有选中的 mas，或未使用计划文件时，交给 mas.sh
RUN_MAS=0
if [ -z "${MAC_AS_CODE_PLAN:-}" ] || [ ! -f "${MAC_AS_CODE_PLAN}" ]; then
    RUN_MAS=1
elif [ "${MAC_AS_CODE_SKIP_MAS:-}" != "1" ] && plan_has_on "$MAC_AS_CODE_PLAN" "mas"; then
    RUN_MAS=1
fi

if [ "$RUN_MAS" -eq 1 ]; then
    echo
    echo "📱 处理 App Store 应用..."
    if ! sh "$SCRIPTS_DIR/mas.sh"; then
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
else
    echo
    echo "⏭️  跳过 App Store 应用（未选中或已在开始时选择跳过）"
fi

finalize_results_if_owned

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
exit 0
