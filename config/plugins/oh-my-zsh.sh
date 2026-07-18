#!/bin/sh
# oh-my-zsh | Oh My Zsh（非交互安装）
set -eu

################################
## 安装 Oh My Zsh（非交互模式）##
################################

OH_MY_ZSH_DIR="${ZSH:-$HOME/.oh-my-zsh}"
INSTALL_URL="https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh"

if [ -d "$OH_MY_ZSH_DIR" ]; then
    echo "✅ Oh My Zsh 已安装"
    exit 0
fi

if ! command -v zsh >/dev/null 2>&1; then
    echo "❌ zsh 未安装"
    exit 1
fi

if ! command -v git >/dev/null 2>&1; then
    echo "❌ git 未安装，请先安装 Xcode Command Line Tools"
    exit 1
fi

if ! git --version >/dev/null 2>&1; then
    echo "❌ git 当前不可用，请先处理 Xcode 许可，例如在终端执行：sudo xcodebuild -license"
    exit 1
fi

echo "🐚 安装 Oh My Zsh..."

# --unattended 会跳过 chsh 和安装后进入 zsh，适合初始化脚本。
# 默认让官方脚本备份并替换已有 .zshrc；如果要保留已有 .zshrc，可执行：
# KEEP_ZSHRC=yes sh config/plugins/oh-my-zsh.sh
export RUNZSH=no
export CHSH=no
export KEEP_ZSHRC="${KEEP_ZSHRC:-no}"

sh -c "$(curl -fsSL "$INSTALL_URL")" "" --unattended

echo "✅ Oh My Zsh 安装完成"
