#!/bin/bash
set -eu

if [ "$#" -gt 1 ]; then
    echo "用法：bash scripts/backup.sh [备份目录]"
    echo "默认备份目录：$HOME/Desktop/backup/reset-kit"
    exit 1
fi

BACKUP_ROOT="${1:-$HOME/Desktop/backup/reset-kit}"
STAMP="$(date +%Y%m%d-%H%M%S)"
HOST_NAME="$(scutil --get ComputerName 2>/dev/null || hostname)"
SAFE_HOST_NAME="$(printf '%s' "$HOST_NAME" | tr -c '[:alnum:]_.-' '-')"
SNAPSHOT_DIR="$BACKUP_ROOT/$STAMP-$SAFE_HOST_NAME"
SUMMARY=""

record_summary() {
    status="$1"
    item="$2"
    detail="$3"
    SUMMARY+="$(printf '%s\t%s\t%s' "$status" "$item" "$detail")"$'\n'
}

copy_path() {
    label="$1"
    src="$2"
    rel_dest="$3"

    if [ ! -e "$src" ]; then
        echo "⚠️  跳过，不存在：$src"
        record_summary "SKIP" "$label" "不存在：$src"
        return 0
    fi

    dest="$SNAPSHOT_DIR/$rel_dest"
    mkdir -p "$(dirname "$dest")"
    if [ -d "$src" ]; then
        /usr/bin/rsync -a --exclude '.DS_Store' "$src/" "$dest/"
    else
        /usr/bin/ditto "$src" "$dest"
    fi
    echo "✅ 已备份：$src"
    record_summary "DONE" "$label" "$rel_dest"
}

copy_ssh() {
    src="$HOME/.ssh"
    rel_dest="home/.ssh"
    dest="$SNAPSHOT_DIR/$rel_dest"

    if [ ! -e "$src" ]; then
        echo "⚠️  跳过，不存在：$src"
        record_summary "SKIP" "SSH 配置" "不存在：$src"
        return 0
    fi

    mkdir -p "$(dirname "$dest")"
    /usr/bin/rsync -a --exclude '.DS_Store' --exclude '/agent/' "$src/" "$dest/"
    echo "✅ 已备份：${src}（已排除运行时 agent socket）"
    record_summary "DONE" "SSH 配置" "$rel_dest"
}

copy_rime() {
    src="$HOME/Library/Rime"
    rel_dest="library/Rime"
    dest="$SNAPSHOT_DIR/$rel_dest"

    if [ ! -d "$src" ]; then
        echo "⚠️  跳过，不存在：$src"
        record_summary "SKIP" "Rime 配置" "不存在：$src"
        return 0
    fi

    mkdir -p "$dest"
    /usr/bin/rsync -a \
        --exclude '.DS_Store' \
        --exclude '/build/' \
        --exclude '/plum/' \
        --exclude 'LOCK' \
        --exclude 'LOG' \
        --exclude 'LOG.old' \
        --exclude '*.log' \
        "$src/" "$dest/"
    echo "✅ 已备份：${src}（已排除 build、plum 和运行时日志/锁文件）"
    record_summary "DONE" "Rime 配置" "$rel_dest"
}

export_defaults() {
    label="$1"
    domain="$2"
    rel_dest="$3"

    if ! defaults read "$domain" &>/dev/null; then
        echo "⚠️  跳过，未找到偏好域：$domain"
        record_summary "SKIP" "$label" "未找到偏好域：$domain"
        return 0
    fi

    mkdir -p "$(dirname "$SNAPSHOT_DIR/$rel_dest")"
    defaults export "$domain" "$SNAPSHOT_DIR/$rel_dest"
    echo "✅ 已导出偏好：$domain"
    record_summary "DONE" "$label" "$rel_dest"
}

quit_keyboard_maestro() {
    if [ "${RESET_KIT_SKIP_QUIT_APPS:-}" = "1" ]; then
        echo "ℹ️  跳过退出 Keyboard Maestro（测试模式）"
        return 0
    fi

    if /usr/bin/pgrep -f "Keyboard Maestro Engine" &>/dev/null; then
        /usr/bin/osascript -e 'tell application "Keyboard Maestro Engine" to quit' &>/dev/null || true
    fi

    if /usr/bin/pgrep -f "Keyboard Maestro" &>/dev/null; then
        /usr/bin/osascript -e 'tell application "Keyboard Maestro" to quit' &>/dev/null || true
    fi

    sleep 2
}

backup_textflash() {
    textflash_app_path="${TEXTFLASH_APP_PATH:-/Applications/TextFlash.app}"
    textflash_backup_script="$textflash_app_path/Contents/Resources/Tools/textflash-backup.sh"
    rel_dest_root="application-backups/TextFlash"
    dest_root="$SNAPSHOT_DIR/$rel_dest_root"

    if [ ! -x "$textflash_backup_script" ]; then
        echo "⚠️  跳过，未找到 TextFlash 备份脚本：$textflash_backup_script"
        record_summary "SKIP" "TextFlash 数据" "未找到应用内备份脚本"
        return 0
    fi

    mkdir -p "$dest_root"
    if backup_dir="$("$textflash_backup_script" "$dest_root")"; then
        rel_backup_dir="${backup_dir#"$SNAPSHOT_DIR"/}"
        echo "✅ 已备份 TextFlash：$backup_dir"
        record_summary "DONE" "TextFlash 数据" "$rel_backup_dir"
    else
        echo "⚠️  TextFlash 备份失败"
        record_summary "SKIP" "TextFlash 数据" "备份脚本执行失败"
    fi
}

quit_brave() {
    if [ "${RESET_KIT_SKIP_QUIT_APPS:-}" = "1" ]; then
        echo "ℹ️  跳过退出 Brave Browser（测试模式）"
        return 0
    fi

    if /usr/bin/pgrep -f "Brave Browser" &>/dev/null; then
        /usr/bin/osascript -e 'tell application "Brave Browser" to quit' &>/dev/null || true
        sleep 2
    fi
}

# 备份前会退出 Keyboard Maestro（含 Engine）。macOS Tahoe 起第三方菜单栏
# NSStatusItem 改由 ControlCenter（StatusKit）统一托管；KM Engine 退出并卸下
# Status Menu 后，ControlCenter 布局偶发错乱（图标错位/空白）。杀进程让系统
# 自动拉起即可恢复。
restart_control_center() {
    if /usr/bin/killall ControlCenter 2>/dev/null; then
        echo "🔄 已重启 ControlCenter（修复菜单栏显示）"
    fi
}

# Brave Sync 可同步书签/扩展列表，但多数插件的本地配置（chrome.storage.local / IndexedDB）不同步。
backup_brave_extension_configs() {
    brave_profile="${BRAVE_PROFILE_DIR:-$HOME/Library/Application Support/BraveSoftware/Brave-Browser/Default}"
    local_settings="$brave_profile/Local Extension Settings"
    indexed_db="$brave_profile/IndexedDB"
    rel_root="application-support/Brave-Browser/Default"

    if [ ! -d "$brave_profile" ]; then
        echo "⚠️  跳过，未找到 Brave 配置目录：$brave_profile"
        record_summary "SKIP" "Brave 插件本地配置" "未找到 Brave 配置目录"
        return 0
    fi

    echo "🦁 退出 Brave 后备份插件本地配置..."
    quit_brave

    if [ -d "$local_settings" ]; then
        dest="$SNAPSHOT_DIR/$rel_root/Local Extension Settings"
        mkdir -p "$(dirname "$dest")"
        /usr/bin/rsync -a --exclude '.DS_Store' "$local_settings/" "$dest/"
        echo "✅ 已备份：Local Extension Settings"
        record_summary "DONE" "Brave Local Extension Settings" "$rel_root/Local Extension Settings"
    else
        echo "⚠️  跳过，不存在：$local_settings"
        record_summary "SKIP" "Brave Local Extension Settings" "不存在"
    fi

    if [ -d "$indexed_db" ]; then
        dest_idb="$SNAPSHOT_DIR/$rel_root/IndexedDB"
        mkdir -p "$dest_idb"
        idb_count=0
        for entry in "$indexed_db"/chrome-extension_*; do
            [ -e "$entry" ] || continue
            /usr/bin/rsync -a --exclude '.DS_Store' "$entry" "$dest_idb/"
            idb_count=$((idb_count + 1))
        done

        if [ "$idb_count" -gt 0 ]; then
            echo "✅ 已备份：IndexedDB 中 ${idb_count} 个 chrome-extension_* 条目"
            record_summary "DONE" "Brave 插件 IndexedDB" "$rel_root/IndexedDB（${idb_count} 项）"
        else
            echo "⚠️  跳过，IndexedDB 中无 chrome-extension_* 条目"
            record_summary "SKIP" "Brave 插件 IndexedDB" "无 chrome-extension_* 条目"
        fi
    else
        echo "⚠️  跳过，不存在：$indexed_db"
        record_summary "SKIP" "Brave 插件 IndexedDB" "不存在"
    fi
}

write_restore_script() {
    restore_script="$SNAPSHOT_DIR/restore.sh"

    cat > "$restore_script" <<'RESTORE_SCRIPT'
#!/bin/bash
set -eu

if [ "$#" -gt 0 ]; then
    echo "用法：bash restore.sh"
    echo "请在快照目录中执行，脚本会自动使用自身所在目录作为恢复来源。"
    exit 1
fi

SNAPSHOT_DIR="$(cd "$(dirname "$0")" && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"
SUMMARY=""

record_summary() {
    status="$1"
    item="$2"
    detail="$3"
    SUMMARY+="$(printf '%s\t%s\t%s' "$status" "$item" "$detail")"$'\n'
}

restore_path() {
    label="$1"
    rel_src="$2"
    dest="$3"

    src="$SNAPSHOT_DIR/$rel_src"
    if [ ! -e "$src" ]; then
        echo "⚠️  跳过，快照中不存在：$rel_src"
        record_summary "SKIP" "$label" "快照中不存在：$rel_src"
        return 0
    fi

    mkdir -p "$(dirname "$dest")"

    if [ -e "$dest" ]; then
        backup_dest="$dest.before-restore-$STAMP"
        mv "$dest" "$backup_dest"
        echo "🧷 已保留现有配置：$backup_dest"
    fi

    /usr/bin/ditto "$src" "$dest"
    echo "✅ 已恢复：$dest"
    record_summary "DONE" "$label" "$dest"
}

backup_defaults() {
    domain="$1"
    backup_path="$HOME/Library/Preferences/$domain.plist.before-restore-$STAMP"

    if defaults read "$domain" &>/dev/null; then
        defaults export "$domain" "$backup_path"
        echo "🧷 已保留现有偏好：$backup_path"
    fi
}

import_defaults() {
    label="$1"
    rel_src="$2"
    domain="$3"

    src="$SNAPSHOT_DIR/$rel_src"
    if [ ! -f "$src" ]; then
        echo "⚠️  跳过，快照中不存在：$rel_src"
        record_summary "SKIP" "$label" "快照中不存在：$rel_src"
        return 0
    fi

    backup_defaults "$domain"
    defaults import "$domain" "$src"
    echo "✅ 已导入偏好：$domain"
    record_summary "DONE" "$label" "$domain"
}

quit_app() {
    app_name="$1"

    if [ "${RESET_KIT_SKIP_QUIT_APPS:-}" = "1" ]; then
        echo "ℹ️  跳过退出 ${app_name}（测试模式）"
        return 0
    fi

    if /usr/bin/pgrep -f "$app_name" &>/dev/null; then
        /usr/bin/osascript -e "tell application \"$app_name\" to quit" &>/dev/null || true
    fi
}

restore_textflash() {
    textflash_app_path="${TEXTFLASH_APP_PATH:-/Applications/TextFlash.app}"
    textflash_restore_script="$textflash_app_path/Contents/Resources/Tools/textflash-restore.sh"
    backup_root="$SNAPSHOT_DIR/application-backups/TextFlash"

    if [ ! -d "$backup_root" ]; then
        echo "⚠️  跳过，快照中不存在 TextFlash 备份"
        record_summary "SKIP" "TextFlash 数据" "快照中不存在 TextFlash 备份"
        return 0
    fi

    if [ ! -x "$textflash_restore_script" ]; then
        echo "⚠️  跳过，未找到 TextFlash 恢复脚本：$textflash_restore_script"
        record_summary "SKIP" "TextFlash 数据" "未找到应用内恢复脚本"
        return 0
    fi

    textflash_backup_dir="$(find "$backup_root" -mindepth 1 -maxdepth 1 -type d | sort | tail -n 1)"
    if [ -z "$textflash_backup_dir" ] || [ ! -f "$textflash_backup_dir/textflash.db" ]; then
        echo "⚠️  跳过，TextFlash 备份目录不完整：$backup_root"
        record_summary "SKIP" "TextFlash 数据" "备份目录不完整"
        return 0
    fi

    if "$textflash_restore_script" "$textflash_backup_dir"; then
        echo "✅ 已恢复 TextFlash：$textflash_backup_dir"
        record_summary "DONE" "TextFlash 数据" "TextFlash 应用数据"
    else
        echo "⚠️  TextFlash 恢复失败"
        record_summary "SKIP" "TextFlash 数据" "恢复脚本执行失败"
    fi
}

restore_brave_extension_configs() {
    brave_profile="${BRAVE_PROFILE_DIR:-$HOME/Library/Application Support/BraveSoftware/Brave-Browser/Default}"
    rel_root="application-support/Brave-Browser/Default"
    src_local="$SNAPSHOT_DIR/$rel_root/Local Extension Settings"
    src_idb="$SNAPSHOT_DIR/$rel_root/IndexedDB"

    if [ ! -d "$src_local" ] && [ ! -d "$src_idb" ]; then
        echo "⚠️  跳过，快照中不存在 Brave 插件本地配置"
        record_summary "SKIP" "Brave 插件本地配置" "快照中不存在"
        return 0
    fi

    quit_app "Brave Browser"
    sleep 1
    mkdir -p "$brave_profile"

    if [ -d "$src_local" ]; then
        restore_path "Brave Local Extension Settings" \
            "$rel_root/Local Extension Settings" \
            "$brave_profile/Local Extension Settings"
    fi

    if [ -d "$src_idb" ]; then
        mkdir -p "$brave_profile/IndexedDB"
        idb_count=0
        for entry in "$src_idb"/chrome-extension_*; do
            [ -e "$entry" ] || continue
            base="$(basename "$entry")"
            dest="$brave_profile/IndexedDB/$base"
            if [ -e "$dest" ]; then
                mv "$dest" "$dest.before-restore-$STAMP"
            fi
            /usr/bin/ditto "$entry" "$dest"
            idb_count=$((idb_count + 1))
        done

        if [ "$idb_count" -gt 0 ]; then
            echo "✅ 已恢复：IndexedDB 中 ${idb_count} 个 chrome-extension_* 条目"
            record_summary "DONE" "Brave 插件 IndexedDB" "${brave_profile}/IndexedDB（${idb_count} 项）"
        else
            echo "⚠️  跳过，快照 IndexedDB 中无 chrome-extension_* 条目"
            record_summary "SKIP" "Brave 插件 IndexedDB" "快照中无条目"
        fi
    fi
}

# 校验快照完整性
if [ -f "$SNAPSHOT_DIR/SHA256SUMS" ]; then
    echo "🔐 校验快照完整性..."
    if ! (cd "$SNAPSHOT_DIR" && shasum -a 256 -c SHA256SUMS > /dev/null 2>&1); then
        echo "❌ 快照完整性校验失败！文件可能已损坏或被篡改。"
        exit 1
    fi
    echo "✅ 快照完整性校验通过"
fi

echo "♻️  从快照恢复：$SNAPSHOT_DIR"

restore_path "SSH 配置" "home/.ssh" "$HOME/.ssh"
if [ -d "$HOME/.ssh" ]; then
    chmod 700 "$HOME/.ssh"
    find "$HOME/.ssh" -type f -name 'id_*' ! -name '*.pub' -exec chmod 600 {} \;
    find "$HOME/.ssh" -type f -name '*.pub' -exec chmod 644 {} \;
fi

restore_path "Git 配置" "home/.gitconfig" "$HOME/.gitconfig"
restore_path "Zsh 配置" "home/.zshrc" "$HOME/.zshrc"

quit_app "Ghostty"
restore_path "Ghostty macOS 配置" "application-support/com.mitchellh.ghostty" "$HOME/Library/Application Support/com.mitchellh.ghostty"

quit_app "iTerm2"
quit_app "iTerm"
import_defaults "iTerm2 偏好" "preferences/com.googlecode.iterm2.plist" "com.googlecode.iterm2"

quit_app "CleanShot X"
import_defaults "CleanShot 偏好" "preferences/pl.maketheweb.cleanshotx.plist" "pl.maketheweb.cleanshotx"

quit_app "Keyboard Maestro Engine"
quit_app "Keyboard Maestro"
restore_path "Keyboard Maestro 数据" "application-support/Keyboard Maestro" "$HOME/Library/Application Support/Keyboard Maestro"
import_defaults "Keyboard Maestro 偏好" "preferences/com.stairways.keyboardmaestro.plist" "com.stairways.keyboardmaestro"
import_defaults "Keyboard Maestro Editor 偏好" "preferences/com.stairways.keyboardmaestro.editor.plist" "com.stairways.keyboardmaestro.editor"
import_defaults "Keyboard Maestro Engine 偏好" "preferences/com.stairways.keyboardmaestro.engine.plist" "com.stairways.keyboardmaestro.engine"

restore_path "Rime 配置" "library/Rime" "$HOME/Library/Rime"
import_defaults "Squirrel 偏好" "preferences/im.rime.inputmethod.Squirrel.plist" "im.rime.inputmethod.Squirrel"

restore_textflash
restore_brave_extension_configs

echo
echo "==> 恢复汇总"
printf '%s' "$SUMMARY" | while IFS=$'\t' read -r status item detail || [ -n "${status:-}" ]; do
    [ -n "$status" ] || continue
    case "$status" in
        DONE) echo "✅ ${item:-未知项目}：已恢复到 ${detail:-未知位置}" ;;
        SKIP) echo "⚠️  ${item:-未知项目}：已跳过，${detail:-无详情}" ;;
        *) echo "$status ${item:-未知项目}：${detail:-无详情}" ;;
    esac
done

echo "✅ 恢复完成。建议重新打开 Ghostty、iTerm2、Brave、CleanShot 和 Keyboard Maestro 检查设置。"
echo "   Brave：先登录 Sync 拉回扩展列表，再确认各插件本地配置是否已恢复。"
RESTORE_SCRIPT

    chmod +x "$restore_script"
}

mkdir -p "$SNAPSHOT_DIR/metadata"

{
    echo "created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "host_name=$HOST_NAME"
    sw_vers 2>/dev/null || true
    uname -a
} > "$SNAPSHOT_DIR/metadata/manifest.txt"

write_restore_script

echo "📦 创建离线迁移快照：$SNAPSHOT_DIR"

copy_ssh
copy_path "Git 配置" "$HOME/.gitconfig" "home/.gitconfig"
copy_path "Zsh 配置" "$HOME/.zshrc" "home/.zshrc"
copy_path "Ghostty macOS 配置" "$HOME/Library/Application Support/com.mitchellh.ghostty" "application-support/com.mitchellh.ghostty"

export_defaults "iTerm2 偏好" "com.googlecode.iterm2" "preferences/com.googlecode.iterm2.plist"
export_defaults "CleanShot 偏好" "pl.maketheweb.cleanshotx" "preferences/pl.maketheweb.cleanshotx.plist"

echo "⌨️  退出 Keyboard Maestro 后备份配置..."
quit_keyboard_maestro
copy_path "Keyboard Maestro 数据" "$HOME/Library/Application Support/Keyboard Maestro" "application-support/Keyboard Maestro"
export_defaults "Keyboard Maestro 偏好" "com.stairways.keyboardmaestro" "preferences/com.stairways.keyboardmaestro.plist"
export_defaults "Keyboard Maestro Editor 偏好" "com.stairways.keyboardmaestro.editor" "preferences/com.stairways.keyboardmaestro.editor.plist"
export_defaults "Keyboard Maestro Engine 偏好" "com.stairways.keyboardmaestro.engine" "preferences/com.stairways.keyboardmaestro.engine.plist"

copy_rime
export_defaults "Squirrel 偏好" "im.rime.inputmethod.Squirrel" "preferences/im.rime.inputmethod.Squirrel.plist"

backup_textflash
backup_brave_extension_configs

echo "🔐 生成快照校验文件..."
(cd "$SNAPSHOT_DIR" && find . -type f \
    ! -name 'SHA256SUMS' \
    ! -name 'restore.sh' \
    ! -path './metadata/*' \
    -exec shasum -a 256 {} \;) > "$SNAPSHOT_DIR/SHA256SUMS"

printf '%s' "$SUMMARY" > "$SNAPSHOT_DIR/metadata/summary.tsv"

echo
echo "==> 备份汇总"
printf '%s' "$SUMMARY" | while IFS=$'\t' read -r status item detail || [ -n "${status:-}" ]; do
    [ -n "$status" ] || continue
    case "$status" in
        DONE) echo "✅ ${item:-未知项目}：已备份到 ${detail:-未知位置}" ;;
        SKIP) echo "⚠️  ${item:-未知项目}：已跳过，${detail:-无详情}" ;;
        *) echo "$status ${item:-未知项目}：${detail:-无详情}" ;;
    esac
done

echo "✅ 备份完成：$SNAPSHOT_DIR"
restart_control_center
