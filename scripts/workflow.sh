#!/bin/sh
# 面向任务的交互，不在打开菜单时安装工具或改变系统。
set -u
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
. "$SCRIPTS_DIR/common.sh"
TASK="${1:-menu}"
[ "$#" -eq 0 ] || shift
if [ "$TASK" = legacy ]; then
    # 兼容旧参数；交互模式仍有全量计划的最后确认。
    if [ -t 0 ]; then
        printf '旧参数将进入全量装机（含重置布局等设置）。继续？[y/N] '
        read -r answer || exit 1
        case "$answer" in y|Y) ;; *) exit 0 ;; esac
    fi
    exec sh "$SCRIPTS_DIR/apply.sh" --yes "$@"
fi
YES_MODE=0
TARGET_PATH=""
for argument do
    case "$argument" in
        --yes|-y) YES_MODE=1 ;;
        -*) echo "未知参数：$argument" >&2; exit 1 ;;
        *)
            [ -z "$TARGET_PATH" ] || { echo "只能指定一个目录。" >&2; exit 1; }
            TARGET_PATH="$argument"
            ;;
    esac
done
case "$TASK" in
    configure|menu) [ -z "$TARGET_PATH" ] || { echo "此任务不接受目录参数。" >&2; exit 1; } ;;
esac
if [ ! -t 0 ] || [ ! -t 1 ]; then
    [ "$YES_MODE" -eq 1 ] && [ "$TASK" != menu ] || {
        echo "请在交互终端运行 sh init.sh；自动执行请指定任务和 --yes。" >&2
        exit 1
    }
fi
MAC_AS_CODE_INTERACTIVE=0
[ "$YES_MODE" -ne 0 ] || MAC_AS_CODE_INTERACTIVE=1
export MAC_AS_CODE_INTERACTIVE
WORK_DIR="$(mktemp -d -t mac-as-code-workflow.XXXXXX)" || exit 1
trap 'ui_restore_tty; rm -rf "$WORK_DIR"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
FLOW_PLAN="$WORK_DIR/selected.plan"
FLOW_DETAILS="$WORK_DIR/details.tsv"
RETRY_PLAN="${MAC_AS_CODE_STATE_DIR:-$HOME/.local/state/mac-as-code}/retry.plan"

ask() {
    echo "b 返回"
    echo "q 退出程序"
    printf '%s > ' "$1"
    read -r answer || return 1
    case "$answer" in
        b|B) answer=0 ;;
        q|Q) exit 0 ;;
    esac
}

show_details() {
    awk -F '\t' '
        $3 != "met" { print "\n" $4; print "  " $5 }
    ' "$FLOW_DETAILS"
}

show_summary() {
    echo
    echo "配置这台 Mac · 实时检测"
    awk -F '\t' '
        $3 == "met" { met++; next }
        $3 == "manual" { manual++; next }
        $1 == "defaults" { settings++; next }
        $1 == "dock" { dock++; next }
        { apps++ }
        END {
            printf "  软件 / 环境  缺少 %d 项\n  系统设置     不同 %d 项\n  Dock         不同 %d 项\n", apps, settings, dock
            printf "  需明确选择   %d 项\n  已满足       %d 项（已折叠）\n", manual, met
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
    echo "正在检测设置和软件…"
    sh "$SCRIPTS_DIR/plan.sh" "$FLOW_PLAN" "$FLOW_DETAILS" || return 1
    while true; do
        show_summary
        if [ "$YES_MODE" -eq 1 ]; then
            answer=1
        else
            echo "1 应用已选项"
            echo "2 调整选择"
            echo "3 查看详情"
            echo "4 将本机软件加入配置清单"
            echo "5 重试上次失败项"
            echo "0 返回"
            ask "选择" || return 1
        fi
        case "$answer" in
            0|'') return 0 ;;
            2)
                echo "调整范围："
                echo "1 全部（默认）"
                echo "2 软件 / 环境"
                echo "3 系统设置"
                echo "4 Dock"
                echo "0 返回"
                ask "范围" || return 1
                case "$answer" in
                    ''|1) selection_types='defaults|dock|brew|cask|mas|recipe|github-release' ;;
                    2) selection_types='brew|cask|mas|recipe|github-release' ;;
                    3) selection_types=defaults ;;
                    4) selection_types=dock ;;
                    *) continue ;;
                esac
                export MAC_AS_CODE_UI_DETAILS="$FLOW_DETAILS"
                checkbox_select_step "调整本次操作" "$selection_types" "$FLOW_PLAN" '确认选择后返回配置菜单，不会立即执行' || {
                    result=$?
                    [ "$result" -ne 2 ] || exit 0
                    [ "$result" -eq 3 ] || return 0
                }
                ;;
            3) show_details ;;
            4)
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
                    echo "没有记录的失败项。"
                else
                    cp "$RETRY_PLAN" "$FLOW_PLAN"
                    sh "$SCRIPTS_DIR/plan.sh" "$WORK_DIR/fresh.plan" "$WORK_DIR/fresh.tsv" || return 1
                    merge_selection
                    cp "$WORK_DIR/fresh.tsv" "$FLOW_DETAILS"
                    echo "已选中仍未完成的失败项；可查看详情后应用。"
                fi
                ;;
            1)
                [ "$selected_count" -gt 0 ] || { echo "没有需要执行的已选项。"; [ "$YES_MODE" -eq 0 ] || return 0; continue; }
                echo
                echo "将执行："
                awk -F '|' '$1 == "ON" { label = ($2 == "brew" || $2 == "cask" || $2 == "mas") ? $3 : $4; print "  - " label }' "$FLOW_PLAN"
                echo "设置可能重启 Finder / Dock；安装软件可能需要管理员授权或 App Store 登录。"
                if [ "$YES_MODE" -eq 0 ]; then
                    ask "确认应用以上项目？[y/N]" || return 1
                    case "$answer" in y|Y) ;; *) continue ;; esac
                fi
                echo "正在复核当前状态…"
                sh "$SCRIPTS_DIR/plan.sh" "$WORK_DIR/fresh.plan" "$WORK_DIR/fresh.tsv" || return 1
                if ! cmp -s "$FLOW_DETAILS" "$WORK_DIR/fresh.tsv"; then
                    merge_selection
                    cp "$WORK_DIR/fresh.tsv" "$FLOW_DETAILS"
                    echo "状态已变化，已更新计划，请重新检查。"
                    [ "$YES_MODE" -eq 0 ] || return 1
                    continue
                fi
                MAC_AS_CODE_INPUT_PLAN="$FLOW_PLAN" sh "$SCRIPTS_DIR/apply.sh" --yes
                result=$?
                [ "$result" -ne 2 ] || exit 0
                if [ "$result" -eq 3 ]; then continue; fi
                return "$result"
                ;;
            *) echo "请选择菜单中的编号。" ;;
        esac
    done
}

backup() {
    backup_root="${TARGET_PATH:-$HOME/Desktop/backup/reset-kit}"
    echo "备份位置：${backup_root}（自动新建带时间的快照目录）"
    echo "范围：SSH、Git、Zsh、Ghostty、CleanShot、Keyboard Maestro、Rime、TextFlash、Brave 插件本地配置。"
    echo "备份时会临时退出 Keyboard Maestro 和 Brave，结束后恢复原先运行状态。"
    if [ "$YES_MODE" -eq 0 ]; then
        ask "开始备份？[y/N]" || return 1
        case "$answer" in y|Y) ;; *) return 0 ;; esac
    fi
    MAC_AS_CODE_BACKUP_CONFIRMED=1 bash "$SCRIPTS_DIR/backup.sh" "$backup_root"
}

choose_snapshot() {
    [ -z "$TARGET_PATH" ] || return 0
    [ "$YES_MODE" -eq 0 ] || { echo "自动恢复必须指定快照目录。" >&2; return 1; }
    echo "可用快照（默认备份目录）："
    : >"$WORK_DIR/snapshots"
    for snapshot in "$HOME/Desktop/backup/reset-kit/"*; do
        [ -f "$snapshot/restore.sh" ] || continue
        printf '%s\n' "$snapshot" >>"$WORK_DIR/snapshots"
    done
    awk '{ print NR "  " $0 }' "$WORK_DIR/snapshots"
    ask "输入编号或快照目录（0 返回）" || return 1
    case "$answer" in
        ''|0) return 2 ;;
        *[!0-9]*) TARGET_PATH="$answer" ;;
        *) TARGET_PATH="$(sed -n "${answer}p" "$WORK_DIR/snapshots")" ;;
    esac
    [ -n "$TARGET_PATH" ] || { echo "未找到该快照。" >&2; return 1; }
}

restore_apps() {
    echo "正在生成恢复所需的软件计划…"
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
    echo "将先安装："
    awk -F '|' '{ print "  - " $3 }' "$FLOW_PLAN"
    ask "安装这些软件后继续恢复？[y/N]" || return 1
    case "$answer" in y|Y) ;; *) return 2 ;; esac
    MAC_AS_CODE_INPUT_PLAN="$FLOW_PLAN" sh "$SCRIPTS_DIR/apply.sh" --yes
    result=$?
    [ "$result" -ne 2 ] || exit 0
    [ "$result" -ne 3 ] || return 2
    return "$result"
}

restore() {
    choose_snapshot || { result=$?; [ "$result" -eq 2 ] && return 0; return "$result"; }
    if [ ! -d "$TARGET_PATH" ] || [ ! -f "$TARGET_PATH/restore.sh" ]; then
        echo "不是有效的快照目录：$TARGET_PATH" >&2
        return 1
    fi
    TARGET_PATH="$(cd "$TARGET_PATH" && pwd)"
    echo "恢复来源：$TARGET_PATH"
    if [ -f "$TARGET_PATH/metadata/manifest.txt" ]; then
        sed -n '1,5p' "$TARGET_PATH/metadata/manifest.txt"
    fi
    if [ -f "$TARGET_PATH/metadata/summary.tsv" ]; then
        awk -F '\t' '$1 == "DONE" { print "  - " $2 }' "$TARGET_PATH/metadata/summary.tsv"
    fi
    [ -s "$TARGET_PATH/SHA256SUMS" ] || { echo "缺少完整性校验文件，停止恢复。" >&2; return 1; }
    echo "正在校验快照完整性…"
    (cd "$TARGET_PATH" && shasum -a 256 -c SHA256SUMS >/dev/null) || return 1
    echo "现有文件会先保留为 .before-restore-*；恢复可能退出相关应用。"
    if [ "$YES_MODE" -eq 0 ]; then
        echo "1 直接恢复"
        echo "2 先安装快照所需软件，再恢复"
        echo "0 返回"
        ask "选择" || return 1
        case "$answer" in
            1) ;;
            2)
                restore_apps || {
                    result=$?
                    [ "$result" -ne 2 ] || return 0
                    return "$result"
                }
                ;;
            *) return 0 ;;
        esac
        ask "确认恢复上述个人数据？[y/N]" || return 1
        case "$answer" in y|Y) ;; *) return 0 ;; esac
    fi
    MAC_AS_CODE_RESTORE_CONFIRMED=1 bash "$TARGET_PATH/restore.sh"
}

if [ "$TASK" != menu ]; then
    "$TASK"
    exit $?
fi
while true; do
    echo
    echo "mac-as-code"
    echo "1 配置这台 Mac    查看差异、安装软件、应用设置"
    echo "2 备份这台 Mac    保存个人配置和应用数据"
    echo "3 从备份恢复      选择快照，恢复个人数据"
    echo "0 退出"
    ask "选择" || exit 0
    TARGET_PATH=""
    case "$answer" in
        1) configure || echo "配置未全部完成，请查看上方提示。" ;;
        2) backup || echo "备份未完成，请查看上方提示。" ;;
        3) restore || echo "恢复未完成，请查看上方提示。" ;;
        0|'') exit 0 ;;
        *) echo "请选择菜单中的编号。" ;;
    esac
done
