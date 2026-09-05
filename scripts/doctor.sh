#!/bin/sh
set -u

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"
BREWFILE="$ROOT_DIR/config/Brewfile"
FAILED=0
MODE="all"

usage() {
    echo "内部环境检查模块；请运行 sh mac.sh，选择检查环境。"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        --pre|--post|--all)
            MODE="${1#--}"
            shift
            ;;
        *)
            echo "❌ 未知参数：$1"
            usage
            exit 1
            ;;
    esac
done

pass() {
    echo "✅ $1"
}

warn() {
    echo "⚠️  $1"
}

fail() {
    echo "❌ $1"
    FAILED=1
}

section() {
    echo
    echo "==> $1"
}

check_prereqs() {
    section "macOS"
    if [ "$(uname -s)" = "Darwin" ]; then
        pass "当前系统是 macOS"
    else
        fail "当前脚本只支持 macOS"
    fi

    section "Xcode Command Line Tools"
    if xcode-select -p >/dev/null 2>&1; then
        pass "Xcode Command Line Tools 已安装：$(xcode-select -p)"
    else
        fail "未安装 Xcode Command Line Tools，请先运行：xcode-select --install"
    fi

    if command -v git >/dev/null 2>&1; then
        if git --version >/dev/null 2>&1; then
            pass "git 可用：$(git --version)"
        else
            fail "git 当前不可用，可能需要接受 Xcode 许可：sudo xcodebuild -license"
        fi
    else
        fail "git 不存在"
    fi

    section "Brewfile"
    if [ -f "$BREWFILE" ]; then
        pass "Brewfile 存在：$BREWFILE"
    else
        fail "未找到 Brewfile，无法按清单安装软件"
    fi
}

check_installed() {
    section "Homebrew"
    if command -v brew >/dev/null 2>&1; then
        pass "Homebrew 已安装：$(command -v brew)"
        if brew bundle list --all --file="$BREWFILE" >/dev/null 2>&1; then
            pass "Brewfile 可解析"
        else
            warn "Brewfile 解析检查未通过，可能是 Homebrew 缓存权限或网络问题"
        fi
    else
        fail "Homebrew 未安装"
    fi

    section "Mac App Store"
    if command -v mas >/dev/null 2>&1; then
        pass "mas 已安装"
        if mas_config="$(mas config 2>/dev/null)"; then
            pass "mas 可访问 App Store 配置信息"
            store_line="$(printf '%s\n' "$mas_config" | awk '/^store/ {print $NF; exit}')"
            region_line="$(printf '%s\n' "$mas_config" | awk '/^region/ {print $NF; exit}')"
            if [ -n "${store_line:-}" ] || [ -n "${region_line:-}" ]; then
                echo "   store: ${store_line:-unknown}, region: ${region_line:-unknown}"
            fi
        else
            warn "mas 无法读取 App Store 配置信息，Brewfile 中的 mas 应用可能无法安装"
        fi
    else
        warn "mas 未安装（若装机时跳过了 App Store 应用可忽略）"
    fi

    section "Oh My Zsh"
    if [ -d "${ZSH:-$HOME/.oh-my-zsh}" ]; then
        pass "Oh My Zsh 已安装"
    else
        warn "Oh My Zsh 未安装（若装机时未勾选可忽略）"
    fi
}

case "$MODE" in
    pre)
        echo "🩺 doctor（装机前：硬门槛）"
        check_prereqs
        ;;
    post)
        echo "🩺 doctor（装机后：验收）"
        check_installed
        ;;
    all)
        echo "🩺 doctor（全部检查）"
        check_prereqs
        check_installed
        ;;
esac

echo
if [ "$FAILED" -eq 0 ]; then
    pass "doctor 检查完成"
else
    fail "doctor 检查发现需要先处理的问题"
fi

exit "$FAILED"
