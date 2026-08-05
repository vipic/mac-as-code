#!/bin/sh
# Annotated items below exit 0 are parsed by run_annotated_shell_items, not dead code.
# shellcheck disable=SC2317
set -u

CONFIG_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$CONFIG_DIR/.." && pwd)"
# shellcheck source=../scripts/common.sh
. "$ROOT_DIR/scripts/common.sh"

###################
## Dock 设置（可按项勾选）
##
## 维护方式：在下方用「# id | 说明」+ 命令增减即可。
## 多选 UI / 执行会从本文件解析这些项（不必改 case / 目录表）。
###################

if [ "${MAC_AS_CODE_LIST_CATALOG:-}" = "1" ]; then
    list_annotated_shell_items "$0"
    exit 0
fi

init_results

echo "🖥️  按勾选项应用 Dock 设置..."
run_annotated_shell_items dock "$0"

if [ "${_annotated_applied:-0}" -gt 0 ]; then
    echo "🔄 重启 Dock 以应用设置..."
    killall Dock 2>/dev/null || true
else
    echo "ℹ️  未选中任何 Dock 设置项"
fi

finalize_results_if_owned
exit 0

# launchpad-grid | LaunchPad 行列数 10×8，并重置布局
defaults write com.apple.dock springboard-rows -int 10
defaults write com.apple.dock springboard-columns -int 8
defaults write com.apple.dock ResetLaunchPad -int 1

# autohide | Dock 自动隐藏
defaults write com.apple.dock autohide -int 1

# orientation-left | Dock 位置：左侧
defaults write com.apple.dock orientation -string left

# icon-size | Dock 放大尺寸 largesize=128（配合「关闭放大」时通常看不出变化）
defaults write com.apple.dock largesize -int 128

# magnification-off | Dock 关闭放大
defaults write com.apple.dock magnification -int 0

# mineffect-genie | 最小化效果：Genie
defaults write com.apple.dock mineffect -string genie

# minimize-to-app-off | 不最小化到应用程序图标
defaults write com.apple.dock minimize-to-application -int 0

# launchanim-off | 关闭打开应用时的 Dock 弹跳动画
defaults write com.apple.dock launchanim -int 0

# autohide-instant | 显示/隐藏动画时长为 0（即时）
defaults write com.apple.dock autohide-time-modifier -int 0

# process-indicators | 显示已打开应用的指示灯
defaults write com.apple.dock show-process-indicators -int 1

# hide-recents | 不在 Dock 中显示最近打开的应用
defaults write com.apple.dock show-recents -int 0

# mouse-over-hilite | Stack 鼠标悬停高亮
defaults write com.apple.dock mouse-over-hilite-stack -int 1

# hot-corners | 触发角：右下锁屏、左上显示桌面，其余两角关闭
defaults write com.apple.dock wvous-br-corner -int 13
defaults write com.apple.dock wvous-tl-corner -int 4
defaults write com.apple.dock wvous-tr-corner -int 1
defaults write com.apple.dock wvous-bl-corner -int 1

# click-wallpaper-no-desktop | 点击壁纸不展现桌面
defaults write com.apple.WindowManager EnableStandardClickToShowDesktop -bool false

# clear-and-pin-apps | 清空 Dock 固定项，并固定 Apps + Sublime Text
defaults write com.apple.dock persistent-apps -array
for app_path in "/System/Applications/Apps.app" "/Applications/Sublime Text.app"; do
    if [ -d "$app_path" ]; then
        safe_path="$(printf '%s' "$app_path" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')"
        defaults write com.apple.dock persistent-apps -array-add \
            "<dict><key>tile-data</key><dict><key>file-data</key><dict><key>_CFURLString</key><string>${safe_path}</string><key>_CFURLStringType</key><integer>0</integer></dict></dict></dict>"
    fi
done
