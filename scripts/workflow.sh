#!/bin/sh
# 面向任务的交互，不在打开菜单时安装工具或改变系统。
set -u
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
. "$SCRIPTS_DIR/common.sh"
if [ "$#" -ne 0 ] || [ ! -t 0 ] || [ ! -t 1 ]; then
    echo "请在交互终端运行 sh mac.sh，从菜单选择任务。" >&2
    exit 1
fi
WORK_DIR="$(mktemp -d -t mac-as-code-workflow.XXXXXX)" || exit 1
trap 'ui_restore_tty; rm -rf "$WORK_DIR"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
FLOW_PLAN="$WORK_DIR/selected.plan"
FLOW_DETAILS="$WORK_DIR/details.tsv"
RETRY_PLAN="${MAC_AS_CODE_STATE_DIR:-$HOME/.local/state/mac-as-code}/retry.plan"

# 将 UI 的返回码统一映射到工作流；q 无需回车，退出整个程序。
menu() {
    ui_select "$@"
    input_status=$?
    case "$input_status" in
        1|2) exit 0 ;;
        3) answer=b ;;
    esac
}
confirm() {
    confirm_action "$@"
    input_status=$?
    case "$input_status" in
        1|2) exit 0 ;;
        *) return "$input_status" ;;
    esac
}
notice() {
    ui_document "$1" "$2"
    input_status=$?
    [ "$input_status" -ne 2 ] || exit 0
}
wait_back() {
    ui_enter || return 1
    ui_size
    printf '\033[%s;1H\033[90mb 返回主菜单 · q 退出\033[0m' "$((UI_ROWS - 1))"
    while true; do
        input_key="$(ui_read_key)"
        case "$input_key" in
            back) ui_leave; return 0 ;;
            quit|eof) ui_leave; exit 0 ;;
        esac
    done
}
path_input() {
    ui_path "$1" "$2"
    input_status=$?
    case "$input_status" in
        1|2) exit 0 ;;
        3) return 3 ;;
    esac
}

adjust_selection() {
    while true; do
        menu "调整范围" "选择要调整的类别" back "全部" "软件 / 环境" "系统设置" "Dock"
        case "$answer" in
            b) return 0 ;;
            1) selection_types='defaults|dock|brew|cask|mas|recipe|github-release' ;;
            2) selection_types='brew|cask|mas|recipe|github-release' ;;
            3) selection_types=defaults ;;
            4) selection_types=dock ;;
            *) echo "请选择范围编号。"; continue ;;
        esac
        export MAC_AS_CODE_UI_DETAILS="$FLOW_DETAILS"
        checkbox_select_step "调整本次操作" "$selection_types" "$FLOW_PLAN" 'Enter 保存选择，返回配置菜单'
        result=$?
        case "$result" in
            0) return 0 ;;
            2) exit 0 ;;
            3) continue ;;
            *) return "$result" ;;
        esac
    done
}

show_details() {
    notice "差异详情" "$(awk -F '\t' '$3 != "met" { print $4; print "  " $5; print "" }' "$FLOW_DETAILS")"
}

show_summary() {
    awk -F '\t' '
        $3 == "met" { met++; next }
        $3 == "manual" { manual++; next }
        $1 == "defaults" { settings++; next }
        $1 == "dock" { dock++; next }
        { apps++ }
        END {
            printf "软件缺少 %d · 系统差异 %d · Dock 差异 %d\n", apps, settings, dock
            printf "待确认 %d · 已满足 %d（已折叠）\n", manual, met
        }
    ' "$FLOW_DETAILS"
    selected_count="$(awk -F '|' '$1 == "ON" { n++ } END { print n+0 }' "$FLOW_PLAN")"
    echo "本次已选 $selected_count 项。只修改电脑，不写入配置清单。"
}

# 将旧选择映射到新检测结果，不把新出现的差异自动加入已确认计划。
merge_selection() {
    awk -F '|' 'FILENAME == ARGV[1] { if ($1 == "ON") selected[$2 SUBSEP $3] = 1; next }
        { $1 = (($2 SUBSEP $3) in selected) ? "ON" : "OFF"; print }
    ' OFS='|' "$FLOW_PLAN" "$WORK_DIR/fresh.plan" >"$WORK_DIR/merged.plan"
    cp "$WORK_DIR/merged.plan" "$FLOW_PLAN"
}

configure() {
    ui_execution "检测这台 Mac" "正在读取当前设置与软件状态…"
    sh "$SCRIPTS_DIR/plan.sh" "$FLOW_PLAN" "$FLOW_DETAILS" || return 1
    while true; do
        summary_text="$(show_summary)"
        selected_count="$(awk -F '|' '$1 == "ON" { n++ } END { print n+0 }' "$FLOW_PLAN")"
        menu "配置这台 Mac" "$summary_text" back \
            "应用已选项" "调整选择" "查看详情" "将本机软件加入配置清单" "重试上次失败项"
        case "$answer" in
            b) return 0 ;;
            2) adjust_selection || return $? ;;
            3) show_details ;;
            4)
                ui_execution "检测本机软件"
                sh "$SCRIPTS_DIR/audit.sh" append --refresh || {
                    result=$?
                    [ "$result" -ne 2 ] || exit 0
                    return "$result"
                }
                sh "$SCRIPTS_DIR/plan.sh" "$WORK_DIR/fresh.plan" "$WORK_DIR/fresh.tsv" || return 1
                merge_selection
                cp "$WORK_DIR/fresh.tsv" "$FLOW_DETAILS"
                ;;
            5)
                if [ ! -s "$RETRY_PLAN" ]; then
                    notice "重试失败项" "没有记录的失败项。"
                else
                    cp "$RETRY_PLAN" "$FLOW_PLAN"
                    sh "$SCRIPTS_DIR/plan.sh" "$WORK_DIR/fresh.plan" "$WORK_DIR/fresh.tsv" || return 1
                    merge_selection
                    cp "$WORK_DIR/fresh.tsv" "$FLOW_DETAILS"
                    notice "重试失败项" "已选中仍未完成的失败项；可查看详情后应用。"
                fi
                ;;
            1)
                [ "$selected_count" -gt 0 ] || { notice "应用已选项" "没有需要执行的已选项。"; continue; }
                apply_preview="$(awk -F '|' '$1 == "ON" { label = ($2 == "brew" || $2 == "cask" || $2 == "mas") ? $3 : $4; print "  - " label }' "$FLOW_PLAN")"
                confirm "确认应用以上项目？" "$apply_preview
设置可能重启 Finder / Dock；软件安装可能需要管理员授权或 App Store 登录。" || continue
                ui_execution "复核操作计划" "正在复核当前状态…"
                sh "$SCRIPTS_DIR/plan.sh" "$WORK_DIR/fresh.plan" "$WORK_DIR/fresh.tsv" || return 1
                if ! cmp -s "$FLOW_DETAILS" "$WORK_DIR/fresh.tsv"; then
                    merge_selection
                    cp "$WORK_DIR/fresh.tsv" "$FLOW_DETAILS"
                    notice "计划已更新" "状态已变化，已更新计划，请重新检查。"
                    continue
                fi
                ui_execution "应用配置"
                MAC_AS_CODE_INPUT_PLAN="$FLOW_PLAN" sh "$SCRIPTS_DIR/apply.sh"
                result=$?
                [ "$result" -ne 2 ] || exit 0
                if [ "$result" -eq 3 ]; then continue; fi
                wait_back
                return "$result"
                ;;
            *) echo "请选择任务编号，或 q 退出。" ;;
        esac
    done
}

backup() {
    while true; do
        menu "备份位置" "默认目录：$HOME/Desktop/backup/reset-kit" back \
            "使用默认目录" "输入其他目录"
        case "$answer" in
            b) return 0 ;;
            1) backup_root="$HOME/Desktop/backup/reset-kit" ;;
            2)
                path_input "输入备份根目录" "请输入完整路径，支持包含空格的目录。" || continue
                [ -n "$answer" ] || continue
                backup_root="$answer" ;;
        esac
        confirm "开始备份？" "将在 $backup_root 新建带时间的快照。
范围：SSH、Git、Zsh、Ghostty、CleanShot、Keyboard Maestro、Rime、TextFlash、Brave 插件配置。
会临时退出 Keyboard Maestro 和 Brave，结束后尝试恢复原先运行状态。" || continue
        ui_execution "备份这台 Mac"
        MAC_AS_CODE_BACKUP_CONFIRMED=1 bash "$SCRIPTS_DIR/backup.sh" "$backup_root"
        result=$?
        wait_back
        return "$result"
    done
}

choose_snapshot() {
    while true; do
        : >"$WORK_DIR/snapshots"
        set --
        for snapshot in "$HOME/Desktop/backup/reset-kit/"*; do
            [ -f "$snapshot/restore.sh" ] || continue
            printf '%s\n' "$snapshot" >>"$WORK_DIR/snapshots"
            set -- "$@" "$(basename "$snapshot")"
        done
        snapshot_count=$#
        set -- "$@" "输入其他快照路径"
        menu "选择快照" "默认备份目录中的快照；外置盘可输入完整路径。" back "$@"
        [ "$answer" != b ] || return 3
        if [ "$answer" -le "$snapshot_count" ]; then
            TARGET_PATH="$(awk -v n="$answer" 'NR == n { print; exit }' "$WORK_DIR/snapshots")"
        else
            path_input "输入快照路径" "请输入含 restore.sh 的完整快照目录。" || continue
            TARGET_PATH="$answer"
        fi
        if [ -d "$TARGET_PATH" ] && [ -f "$TARGET_PATH/restore.sh" ]; then
            TARGET_PATH="$(cd "$TARGET_PATH" && pwd)"
            return 0
        fi
        notice "未找到快照" "该目录无效或缺少 restore.sh，请重新选择。"
    done
}

restore_apps() {
    ui_execution "检测恢复所需软件"
    sh "$SCRIPTS_DIR/plan.sh" "$WORK_DIR/restore-full.plan" "$FLOW_DETAILS" || return 1
    : >"$WORK_DIR/needed"
    [ ! -d "$TARGET_PATH/home/.config/ghostty" ] && [ ! -d "$TARGET_PATH/application-support/com.mitchellh.ghostty" ] || printf '%s\n' ghostty font-maple-mono-normal-nf-cn >>"$WORK_DIR/needed"
    [ ! -f "$TARGET_PATH/preferences/pl.maketheweb.cleanshotx.plist" ] || echo cleanshot >>"$WORK_DIR/needed"
    [ ! -d "$TARGET_PATH/application-support/Keyboard Maestro" ] || echo keyboard-maestro >>"$WORK_DIR/needed"
    [ ! -d "$TARGET_PATH/library/Rime" ] || echo squirrel-app >>"$WORK_DIR/needed"
    [ ! -d "$TARGET_PATH/application-support/Brave-Browser" ] || echo brave-browser >>"$WORK_DIR/needed"
    [ ! -d "$TARGET_PATH/application-backups/TextFlash" ] || echo textflash >>"$WORK_DIR/needed"
    [ ! -f "$TARGET_PATH/home/.zshrc" ] || echo oh-my-zsh >>"$WORK_DIR/needed"
    awk 'FILENAME == ARGV[1] { needed[$0] = 1; next }
        { split($0,p,"|"); if (needed[p[3]]) { sub(/^[^|]+/,"ON"); print } }
    ' "$WORK_DIR/needed" "$WORK_DIR/restore-full.plan" >"$FLOW_PLAN"
    if [ ! -s "$FLOW_PLAN" ]; then
        echo "快照对应的软件已满足，或未发现需要安装的清单项。"
        return 0
    fi
    restore_preview="$(awk -F '|' '{ print "  - " $3 }' "$FLOW_PLAN")"
    confirm "安装这些软件后继续恢复？" "$restore_preview" || return $?
    ui_execution "安装恢复所需软件"
    MAC_AS_CODE_INPUT_PLAN="$FLOW_PLAN" sh "$SCRIPTS_DIR/apply.sh"
    result=$?
    [ "$result" -ne 2 ] || exit 0
    return "$result"
}

restore() {
    while true; do
        choose_snapshot || return 0
        snapshot_preview="$(
            printf '恢复来源：%s\n' "$TARGET_PATH"
            [ ! -f "$TARGET_PATH/metadata/manifest.txt" ] || sed -n '1,5p' "$TARGET_PATH/metadata/manifest.txt"
            [ ! -f "$TARGET_PATH/metadata/summary.tsv" ] || awk -F '\t' '$1 == "DONE" { print "  - " $2 }' "$TARGET_PATH/metadata/summary.tsv"
        )"
        if [ ! -s "$TARGET_PATH/SHA256SUMS" ]; then
            notice "无法恢复" "缺少完整性校验文件，请重新选择快照。"
            continue
        fi
        ui_execution "校验快照"
        if ! (cd "$TARGET_PATH" && shasum -a 256 -c SHA256SUMS >/dev/null); then
            notice "无法恢复" "校验失败，未执行恢复。"
            continue
        fi
        while true; do
            menu "恢复方式" "$TARGET_PATH" back "直接恢复" "先安装快照所需软件，再恢复"
            case "$answer" in
                b) break ;;
                1) ;;
                2)
                    restore_apps
                    result=$?
                    if [ "$result" -ne 0 ]; then
                        [ "$result" -eq 3 ] || notice "安装未完成" "安装未全部完成，未继续恢复。"
                        continue
                    fi
                    ;;
                *) echo "请选择恢复方式。"; continue ;;
            esac
            confirm "确认恢复上述个人数据？" "$snapshot_preview
将保留被覆盖的文件 / 偏好副本；TextFlash 使用 CLI 导入。恢复会退出相关应用。" || continue
            ui_execution "恢复个人数据"
            MAC_AS_CODE_RESTORE_CONFIRMED=1 bash "$TARGET_PATH/restore.sh"
            result=$?
            wait_back
            return "$result"
        done
    done
}

printf '\033[2J\033[H'
while true; do
    menu "今天想做什么？" "" root \
        "配置这台 Mac       查看差异、安装软件、应用设置" \
        "备份这台 Mac       保存个人配置和应用数据" \
        "从备份恢复         恢复个人数据" \
        "检查环境           查看工具与安装状态"
    TARGET_PATH=""
    case "$answer" in
        1) configure || notice "配置未完成" "请查看执行结果，处理失败后可重试。" ;;
        2) backup || notice "备份未完成" "请查看执行结果，确认未备份项目。" ;;
        3) restore || notice "恢复未完成" "请查看执行结果，确认未恢复项目。" ;;
        4)
            environment_report="$(sh "$SCRIPTS_DIR/doctor.sh" 2>&1)"
            notice "环境检查" "$environment_report" ;;
    esac
done
