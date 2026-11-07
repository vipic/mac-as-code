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

show_summary() {
    awk -F '\t' '
        $3 == "met" { met++; next }
        $3 == "manual" { manual++; next }
        $1 == "defaults" { settings++; next }
        $1 == "dock" { dock++; next }
        { apps++ }
        END {
            printf "软件缺少 %d · 系统差异 %d · Dock 差异 %d\n", apps, settings, dock
            printf "待确认 %d · 已满足 %d\n", manual, met
        }
    ' "$FLOW_DETAILS"
}

# 将旧选择映射到新检测结果，不把新出现的差异自动加入已确认计划。
merge_selection() {
    awk -F '|' -v first="$FLOW_PLAN" 'FILENAME == first { if ($1 == "ON") selected[$2 SUBSEP $3] = 1; next }
        { $1 = (($2 SUBSEP $3) in selected) ? "ON" : "OFF"; print }
    ' OFS='|' "$FLOW_PLAN" "$WORK_DIR/fresh.plan" >"$WORK_DIR/merged.plan"
    cp "$WORK_DIR/merged.plan" "$FLOW_PLAN"
}

# 执行范围：配置（系统设置 + Dock）/ 软件（Homebrew + App Store + GitHub Releases）/ Recipes / 全部。
execution_scope_types() {
    case "$1" in
        1) printf 'defaults|dock' ;;
        2) printf 'brew|cask|mas|github-release' ;;
        3) printf 'recipe' ;;
        4) printf 'defaults|dock|brew|cask|mas|recipe|github-release' ;;
    esac
}

execution_scope_label() {
    case "$1" in
        1) printf '配置' ;;
        2) printf '软件' ;;
        3) printf 'Recipe' ;;
        4) printf '全部' ;;
    esac
}

execution_scope_hint() {
    case "$1" in
        1|4) printf '空格切换 · Enter 执行 · [需确认] 默认不选 · a/n 仅当前页' ;;
        2|3) printf '空格切换 · Enter 执行 · a/n 仅当前页' ;;
    esac
}

retry_available() {
    [ -s "$RETRY_PLAN" ] && grep -q '^ON|' "$RETRY_PLAN"
}

plan_count_on_types() {
    plan_file="$1"
    plan_types="$2"
    awk -F '|' -v types="$plan_types" '
        BEGIN { n = split(types, arr, "|"); for (i = 1; i <= n; i++) want[arr[i]] = 1 }
        $1 == "ON" && ($2 in want) { count++ }
        END { print count + 0 }
    ' "$plan_file"
}

plan_filter_on_types() {
    plan_file="$1"
    plan_types="$2"
    awk -F '|' -v types="$plan_types" '
        BEGIN { n = split(types, arr, "|"); for (i = 1; i <= n; i++) want[arr[i]] = 1 }
        $1 == "ON" && ($2 in want) { print }
    ' "$plan_file"
}

configure() {
    configure_mode="${1:-normal}"
    if [ "$configure_mode" = "retry" ] && ! retry_available; then
        notice "重试上次失败项" "没有记录的失败项。"
        return 0
    fi
    ui_execution "检测这台 Mac" "正在读取当前设置与软件状态…"
    if [ "$configure_mode" = "retry" ]; then
        cp "$RETRY_PLAN" "$FLOW_PLAN"
        sh "$SCRIPTS_DIR/plan.sh" "$WORK_DIR/fresh.plan" "$WORK_DIR/fresh.tsv" || return 1
        merge_selection
        cp "$WORK_DIR/fresh.tsv" "$FLOW_DETAILS"
        if [ "$(awk -F '|' '$1 == "ON" { n++ } END { print n+0 }' "$FLOW_PLAN")" -eq 0 ]; then
            notice "重试上次失败项" "失败项已全部满足。"
            rm -f "$RETRY_PLAN"
            return 0
        fi
        notice "重试上次失败项" "已选中仍未完成的失败项；可进入范围列表调整后执行。"
    else
        sh "$SCRIPTS_DIR/plan.sh" "$FLOW_PLAN" "$FLOW_DETAILS" || return 1
    fi
    while true; do
        summary_text="$(show_summary)"
        menu "配置这台 Mac" "$summary_text" back \
            "根据仓库配置此电脑" \
            "将该电脑软件同步到仓库"
        case "$answer" in
            b) return 0 ;;
            1)
                while true; do
                    menu "根据仓库配置此电脑" "选择范围。空格切换，Enter 执行。" back \
                        "配置" \
                        "软件" \
                        "Recipe" \
                        "全部"
                    case "$answer" in
                        b) break ;;
                        1|2|3|4) ;;
                        *) continue ;;
                    esac
                    apply_scope="$answer"
                    apply_types="$(execution_scope_types "$apply_scope")"
                    apply_label="$(execution_scope_label "$apply_scope")"
                    apply_hint="$(execution_scope_hint "$apply_scope")"
                    apply_total="$(plan_count_types "$FLOW_PLAN" "$apply_types")"
                    if [ "$apply_total" -eq 0 ]; then
                        notice "$apply_label" "该范围没有项目。"
                        continue
                    fi
                    scope_select_step "$apply_label" "$apply_types" "$FLOW_PLAN" "$FLOW_DETAILS" "$apply_hint"
                    result=$?
                    case "$result" in
                        0) ;;
                        2) exit 0 ;;
                        3) continue ;;
                        *) return 1 ;;
                    esac
                    apply_count="$(plan_count_on_types "$FLOW_PLAN" "$apply_types")"
                    if [ "$apply_count" -eq 0 ]; then
                        notice "$apply_label" "没有勾选任何项目。"
                        continue
                    fi
                    plan_filter_on_types "$FLOW_PLAN" "$apply_types" >"$WORK_DIR/scope.plan"
                    ui_execution "$apply_label"
                    MAC_AS_CODE_INPUT_PLAN="$WORK_DIR/scope.plan" sh "$SCRIPTS_DIR/apply.sh"
                    result=$?
                    [ "$result" -ne 2 ] || exit 0
                    if [ "$result" -eq 3 ]; then continue; fi
                    wait_back
                    return "$result"
                done
                ;;
            2)
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
            *) echo "无效选择。" ;;
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
范围：SSH、Git、Zsh、Ghostty、CleanShot、Keyboard Maestro、Rime、TextFlash。
会临时退出 Keyboard Maestro，结束后尝试恢复原先运行状态。" || continue
        ui_execution "备份个人数据"
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
                *) echo "无效选择。"; continue ;;
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
    retry_ready=0
    retry_available && retry_ready=1
    set -- \
        "配置这台 Mac       应用仓库配置、同步本机软件" \
        "" \
        "备份个人数据       保存配置与应用数据" \
        "恢复个人数据       从快照恢复个人数据" \
        "" \
        "检查环境           核对工具与安装状态"
    if [ "$retry_ready" -eq 1 ]; then
        set -- "$@" "重试上次失败项     重新检测未完成的失败项"
    fi
    menu "选择任务" "" root "$@"
    TARGET_PATH=""
    case "$answer" in
        1) configure || notice "配置未完成" "请查看执行结果，处理失败后可重试。" ;;
        2) backup || notice "备份未完成" "请查看执行结果，确认未备份项目。" ;;
        3) restore || notice "恢复未完成" "请查看执行结果，确认未恢复项目。" ;;
        4)
            environment_output="$WORK_DIR/environment-report"
            ui_capture_execution "环境检查" "正在检查工具与安装状态…" \
                "$environment_output" sh "$SCRIPTS_DIR/doctor.sh" || :
            environment_report="$(cat "$environment_output")"
            notice "环境检查" "$environment_report" ;;
        5)
            if [ "$retry_ready" -eq 1 ]; then
                configure retry || notice "重试未完成" "请查看执行结果，处理失败后可重试。"
            fi
            ;;
    esac
done
