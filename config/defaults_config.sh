#!/bin/sh
# Annotated items below exit 0 are parsed by run_annotated_shell_items, not dead code.
# shellcheck disable=SC2317
set -u

CONFIG_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$CONFIG_DIR/.." && pwd)"
# shellcheck source=../scripts/common.sh
. "$ROOT_DIR/scripts/common.sh"

######################################
## 系统设置（可按项勾选）
## 有的属性需要重启电脑之后生效
##
## 维护方式：在下方用「# id | 说明」+ 命令增减即可。
## 多选 UI / 执行会从本文件解析这些项（不必改 case / 目录表）。
######################################

if [ "${MAC_AS_CODE_LIST_CATALOG:-}" = "1" ]; then
    list_annotated_shell_items "$0"
    exit 0
fi

init_results

echo "🔧 按勾选项应用系统设置..."
run_annotated_shell_items defaults "$0"

if [ "${_annotated_applied:-0}" -gt 0 ]; then
    echo "🔄 重启 Finder 以应用设置..."
    killall Finder 2>/dev/null || true
else
    echo "ℹ️  未选中任何系统设置项"
fi

finalize_results_if_owned
exit 0

# menu-bar-visible | 始终显示菜单栏（关闭自动隐藏）
defaults write NSGlobalDomain _HIHideMenuBar -int 0

# fullscreen-hide-menu | 全屏时隐藏菜单栏
defaults write NSGlobalDomain AppleMenuBarVisibleInFullscreen -int 0

# measurement-cm | 计量单位：厘米
defaults write NSGlobalDomain AppleMeasurementUnits -string Centimeters

# temp-celsius | 温度单位：摄氏度
defaults write -g AppleTemperatureUnit -string Celsius

# disable-text-replacement | 关闭系统文本替换（避免输入时被自动替换）
# 参考：https://github.com/element-hq/element-web/issues/7155
defaults write -g WebAutomaticTextReplacementEnabled -int 0

# release-cmd-d | 禁用 ⌘D 查字典快捷键（释放该组合键）
# 参考：https://apple.stackexchange.com/questions/22785
defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add 70 '<dict><key>enabled</key><false/></dict>'

# simple-password | 清除账户密码策略（可能需要管理员认证）
pwpolicy -clearaccountpolicies

# key-repeat-fast | 加快按键重复速度（KeyRepeat=2）
defaults write -g KeyRepeat -int 2

# key-repeat-delay-short | 缩短按键重复前的延迟（InitialKeyRepeat=15）
defaults write -g InitialKeyRepeat -int 15

# finder-list-view | Finder 默认使用列表视图
defaults write com.apple.finder FXPreferredViewStyle -string "Nlsv"

# finder-show-extensions | Finder 显示所有文件扩展名
defaults write NSGlobalDomain AppleShowAllExtensions -bool true

# clock-24h | 强制 24 小时制（可能需注销/重启后生效）
defaults write NSGlobalDomain AppleICUForce24HourTime -bool true

# trackpad-swipe-navigate | 触控板双指左右滑：在页面间前进/后退
defaults write NSGlobalDomain AppleEnableSwipeNavigateWithScrolls -bool true
defaults write com.apple.AppleMultitouchTrackpad TrackpadHorizScroll -int 1
defaults write com.apple.driver.AppleBluetoothMultitouch.trackpad TrackpadHorizScroll -int 1
