#!/bin/sh
# 共用辅助函数：结果记录、Brewfile 解析、分步多选 UI。
# 由 init.sh 与 scripts/ 下脚本以 `.` 加载，不要直接执行。
# 兼容 sh 与 bash（避免 bash 独有语法）。

# 初始化结果文件。若由 init.sh 导出 MAC_AS_CODE_RESULTS，则复用（不清空）；否则自建。
init_results() {
    if [ -z "${MAC_AS_CODE_RESULTS:-}" ]; then
        MAC_AS_CODE_RESULTS="$(mktemp -t mac-as-code.XXXXXX)"
        MAC_AS_CODE_RESULTS_OWNED=1
        export MAC_AS_CODE_RESULTS
        : >"$MAC_AS_CODE_RESULTS"
    else
        MAC_AS_CODE_RESULTS_OWNED=0
    fi
}

# 追加一条结果。status: OK | FAIL | SKIP
record_result() {
    status="$1"
    item="$2"
    detail="${3:-}"

    if [ -z "${MAC_AS_CODE_RESULTS:-}" ]; then
        return 0
    fi
    printf '%s\t%s\t%s\n' "$status" "$item" "$detail" >>"$MAC_AS_CODE_RESULTS"
}

# 将结果文件持久化到项目内 logs/（或 MAC_AS_CODE_LOG_DIR）
persist_results_log() {
    file="${1:-}"
    prefix="${2:-run}"
    base_dir="${3:-}"

    if [ -z "$file" ] || [ ! -f "$file" ]; then
        return 0
    fi

    if [ -n "${MAC_AS_CODE_LOG_DIR:-}" ]; then
        log_dir="$MAC_AS_CODE_LOG_DIR"
    elif [ -n "$base_dir" ]; then
        log_dir="$base_dir/logs"
    else
        log_dir="./logs"
    fi

    mkdir -p "$log_dir"
    log_file="$log_dir/${prefix}-$(date +%Y%m%d-%H%M%S).tsv"
    /usr/bin/ditto "$file" "$log_file"
    echo "📄 结果已保存：${log_file}"
}

# 打印成功 / 失败 / 跳过汇总
print_results_summary() {
    file="${1:-${MAC_AS_CODE_RESULTS:-}}"
    ok_count=0
    fail_count=0
    skip_count=0
    tab="$(printf '\t')"
    ok_pat="$(printf '^OK\t')"
    fail_pat="$(printf '^FAIL\t')"
    skip_pat="$(printf '^SKIP\t')"

    if [ -z "$file" ] || [ ! -f "$file" ]; then
        echo
        echo "ℹ️  无结果可汇总"
        return 0
    fi

    echo
    echo "================ 执行结果汇总 ================"

    if grep -q "$ok_pat" "$file" 2>/dev/null; then
        echo
        echo "✅ 成功："
        while IFS="$tab" read -r status item detail; do
            [ "$status" = "OK" ] || continue
            ok_count=$((ok_count + 1))
            if [ -n "$detail" ]; then
                echo "  - ${item}（${detail}）"
            else
                echo "  - ${item}"
            fi
        done <"$file"
    fi

    if grep -q "$fail_pat" "$file" 2>/dev/null; then
        echo
        echo "❌ 失败："
        while IFS="$tab" read -r status item detail; do
            [ "$status" = "FAIL" ] || continue
            fail_count=$((fail_count + 1))
            if [ -n "$detail" ]; then
                echo "  - ${item}（${detail}）"
            else
                echo "  - ${item}"
            fi
        done <"$file"
    fi

    if grep -q "$skip_pat" "$file" 2>/dev/null; then
        echo
        echo "⏭️  跳过："
        while IFS="$tab" read -r status item detail; do
            [ "$status" = "SKIP" ] || continue
            skip_count=$((skip_count + 1))
            if [ -n "$detail" ]; then
                echo "  - ${item}（${detail}）"
            else
                echo "  - ${item}"
            fi
        done <"$file"
    fi

    echo
    echo "统计：成功 ${ok_count}，失败 ${fail_count}，跳过 ${skip_count}"
    echo "=============================================="

    if [ "$fail_count" -gt 0 ]; then
        return 1
    fi
    return 0
}

finalize_results_if_owned() {
    if [ "${MAC_AS_CODE_RESULTS_OWNED:-0}" = "1" ] && [ -n "${MAC_AS_CODE_RESULTS:-}" ]; then
        print_results_summary "$MAC_AS_CODE_RESULTS"
        rm -f "$MAC_AS_CODE_RESULTS"
        unset MAC_AS_CODE_RESULTS
        MAC_AS_CODE_RESULTS_OWNED=0
    fi
}

trim() {
    s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# 解析 Brewfile，按出现顺序输出：type|name|id
parse_brewfile() {
    brewfile="$1"

    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%%#*}"
        line="$(trim "$line")"
        [ -z "$line" ] && continue

        case "$line" in
            brew\ \"*)
                name="${line#brew \"}"
                name="${name%%\"*}"
                printf 'brew|%s|\n' "$name"
                ;;
            cask\ \"*)
                name="${line#cask \"}"
                name="${name%%\"*}"
                printf 'cask|%s|\n' "$name"
                ;;
            mas\ \"*)
                name="${line#mas \"}"
                name="${name%%\"*}"
                id="$(printf '%s\n' "$line" | sed -n 's/.*id:[[:space:]]*\([0-9][0-9]*\).*/\1/p')"
                if [ -n "$id" ]; then
                    printf 'mas|%s|%s\n' "$name" "$id"
                fi
                ;;
        esac
    done <"$brewfile"
}

# 尽力检测本机是否已登录 Apple ID（mas 7 已移除 account/signin）。
# 读的是系统 Apple 账户（MobileMeAccounts），多数情况下与 App Store「媒体与购买项目」一致，
# 但不能 100% 保证等于 App Store 登录态。
apple_id_account() {
    defaults read MobileMeAccounts Accounts 2>/dev/null \
        | awk -F'"' '/AccountID/ { print $2; exit }'
}

apple_id_signed_in() {
    apple_id="$(apple_id_account)"
    [ -n "$apple_id" ]
}

# defaults / dock 脚本中的可选项约定（注释 + 命令，便于增减）：
#   # <id> | <说明>
#   defaults write ...
#   # 普通注释与多行命令可写在同一项内，直到下一个「# id |」行
# 文件前半的 runner 代码不会被解析（从第一个项头开始）。

# 列出注解项：输出 id|说明
list_annotated_shell_items() {
    file="$1"
    [ -f "$file" ] || return 0
    awk '
        /^#[[:space:]]*[A-Za-z0-9_-]+[[:space:]]*\|/ {
            line = $0
            sub(/^#[[:space:]]*/, "", line)
            id = line
            sub(/[[:space:]]*\|.*/, "", id)
            label = line
            sub(/^[^|]*\|[[:space:]]*/, "", label)
            if (id != "" && label != "") print id "|" label
        }
    ' "$file"
}

# 将当前注解项按计划执行（供 run_annotated_shell_items 使用）
# 必须从终端跑（勿让 stdin 绑在解析用的临时文件上），否则 pwpolicy 等无法弹出管理员验证。
_flush_annotated_item() {
    if [ -z "${_ann_id:-}" ]; then
        return 0
    fi
    if plan_item_enabled "$_ann_type" "$_ann_id"; then
        echo "  → ${_ann_label}"
        if [ -r /dev/tty ]; then
            status=0
            sh "$_ann_body" </dev/tty || status=$?
        else
            status=0
            sh "$_ann_body" || status=$?
        fi
        if [ "$status" -eq 0 ]; then
            record_result "OK" "${_ann_type}:${_ann_id}" "$_ann_label"
            _ann_applied=$((_ann_applied + 1))
        else
            record_result "FAIL" "${_ann_type}:${_ann_id}" "$_ann_label"
        fi
    else
        record_result "SKIP" "${_ann_type}:${_ann_id}" "未选中"
    fi
    : >"$_ann_body"
    _ann_id=""
    _ann_label=""
}

# 按计划执行注解项。成功应用的数量写入 _annotated_applied。
run_annotated_shell_items() {
    _ann_type="$1"
    file="$2"
    stream=""
    line=""
    marker="__ITEM__"

    _annotated_applied=0
    _ann_applied=0
    _ann_id=""
    _ann_label=""
    [ -f "$file" ] || return 0

    stream="$(mktemp -t mac-as-code-items.XXXXXX)"
    _ann_body="$(mktemp -t mac-as-code-body.XXXXXX)"
    : >"$_ann_body"

    awk '
        /^#[[:space:]]*[A-Za-z0-9_-]+[[:space:]]*\|/ {
            line = $0
            sub(/^#[[:space:]]*/, "", line)
            id = line
            sub(/[[:space:]]*\|.*/, "", id)
            label = line
            sub(/^[^|]*\|[[:space:]]*/, "", label)
            if (id != "" && label != "") {
                printf "__ITEM__\t%s\t%s\n", id, label
                in_item = 1
            }
            next
        }
        in_item { print }
    ' "$file" >"$stream"

    # 用 fd3 读解析流，避免 while-read 重定向 stdin，导致子命令拿不到终端
    while IFS= read -r line <&3 || [ -n "${line:-}" ]; do
        case "$line" in
            "${marker}"*)
                _flush_annotated_item
                _ann_id="$(printf '%s\n' "$line" | awk -F'\t' '{ print $2 }')"
                _ann_label="$(printf '%s\n' "$line" | awk -F'\t' '{ print $3 }')"
                ;;
            *)
                printf '%s\n' "$line" >>"$_ann_body"
                ;;
        esac
    done 3<"$stream"

    _flush_annotated_item
    rm -f "$stream" "$_ann_body"
    _annotated_applied="$_ann_applied"
}

# 列出 config/plugins/*.sh：输出 id|说明
# 约定：文件名（去 .sh）为 id；文件内首个「# id | 说明」提供多选文案（id 应与文件名一致）。
list_plugin_items() {
    plugins_dir="$1"
    f=""
    id=""
    meta=""
    meta_id=""
    label=""

    [ -d "$plugins_dir" ] || return 0

    for f in "$plugins_dir"/*.sh; do
        [ -f "$f" ] || continue
        id="$(basename "$f" .sh)"
        meta="$(list_annotated_shell_items "$f" | awk 'NR == 1 { print; exit }')"
        if [ -n "$meta" ]; then
            meta_id="${meta%%|*}"
            label="${meta#*|}"
            if [ "$meta_id" != "$id" ]; then
                echo "⚠️  插件 ${f}：项头 id「${meta_id}」与文件名「${id}」不一致，以文件名为准" >&2
            fi
            [ -n "$label" ] || label="$id"
        else
            label="$id"
        fi
        printf '%s|%s\n' "$id" "$label"
    done
}

# 计划文件格式：ON|type|name|extra 或 OFF|type|name|extra
# type: defaults|dock|plugin|brew|cask|mas
# defaults/dock/plugin 的 extra 为说明；mas 的 extra 为 App Store id
# 参数：brewfile plan [config_dir]
create_default_plan() {
    brewfile="$1"
    plan="$2"
    config_dir="${3:-}"
    tmp="$(mktemp -t mac-as-code-brewfile.XXXXXX)"

    parse_brewfile "$brewfile" >"$tmp"
    {
        if [ -n "$config_dir" ] && [ -f "$config_dir/defaults_config.sh" ]; then
            list_annotated_shell_items "$config_dir/defaults_config.sh" | while IFS='|' read -r item_id item_label; do
                [ -n "$item_id" ] || continue
                printf 'ON|defaults|%s|%s\n' "$item_id" "$item_label"
            done
        fi
        if [ -n "$config_dir" ] && [ -f "$config_dir/defaults_dock.sh" ]; then
            list_annotated_shell_items "$config_dir/defaults_dock.sh" | while IFS='|' read -r item_id item_label; do
                [ -n "$item_id" ] || continue
                printf 'ON|dock|%s|%s\n' "$item_id" "$item_label"
            done
        fi
        if [ -n "$config_dir" ] && [ -d "$config_dir/plugins" ]; then
            list_plugin_items "$config_dir/plugins" | while IFS='|' read -r item_id item_label; do
                [ -n "$item_id" ] || continue
                printf 'ON|plugin|%s|%s\n' "$item_id" "$item_label"
            done
        fi
        while IFS='|' read -r type name id || [ -n "${type:-}" ]; do
            [ -n "${type:-}" ] || continue
            printf 'ON|%s|%s|%s\n' "$type" "$name" "$id"
        done <"$tmp"
    } >"$plan"
    rm -f "$tmp"
}

plan_has_on() {
    plan="$1"
    type="$2"
    name="${3:-}"

    if [ ! -f "$plan" ]; then
        return 1
    fi
    if [ -n "$name" ]; then
        awk -F'|' -v t="$type" -v n="$name" '
            $1 == "ON" && $2 == t && $3 == n { found = 1 }
            END { exit found ? 0 : 1 }
        ' "$plan"
    else
        awk -F'|' -v t="$type" '
            $1 == "ON" && $2 == t { found = 1 }
            END { exit found ? 0 : 1 }
        ' "$plan"
    fi
}

plan_count_on() {
    plan="$1"
    type="$2"
    count="$(grep -c "^ON|${type}|" "$plan" 2>/dev/null || true)"
    printf '%s' "${count:-0}"
}

plan_item_enabled() {
    type="$1"
    name="$2"

    if [ -z "${MAC_AS_CODE_PLAN:-}" ] || [ ! -f "${MAC_AS_CODE_PLAN}" ]; then
        return 0
    fi
    plan_has_on "$MAC_AS_CODE_PLAN" "$type" "$name"
}

# types 形如 "module" 或 "brew|cask" 或 "mas"
plan_count_types() {
    plan="$1"
    types="$2"
    awk -F'|' -v types="$types" '
        BEGIN {
            n = split(types, arr, "|")
            for (i = 1; i <= n; i++) if (arr[i] != "") want[arr[i]] = 1
        }
        want[$2] { c++ }
        END { print c + 0 }
    ' "$plan"
}

plan_set_types_state() {
    plan="$1"
    types="$2"
    state="$3"
    tmp="$(mktemp -t mac-as-code-plan.XXXXXX)"
    awk -F'|' -v types="$types" -v state="$state" '
        BEGIN {
            OFS = "|"
            n = split(types, arr, "|")
            for (i = 1; i <= n; i++) if (arr[i] != "") want[arr[i]] = 1
        }
        {
            if (want[$2]) $1 = state
            print
        }
    ' "$plan" >"$tmp"
    /usr/bin/ditto "$tmp" "$plan"
    rm -f "$tmp"
}

plan_toggle_nth_of_types() {
    plan="$1"
    types="$2"
    nth="$3"
    tmp="$(mktemp -t mac-as-code-plan.XXXXXX)"
    awk -F'|' -v types="$types" -v nth="$nth" '
        BEGIN {
            OFS = "|"
            n = split(types, arr, "|")
            for (i = 1; i <= n; i++) if (arr[i] != "") want[arr[i]] = 1
            c = 0
        }
        {
            if (want[$2]) {
                c++
                if (c == nth) {
                    if ($1 == "ON") $1 = "OFF"
                    else $1 = "ON"
                }
            }
            print
        }
    ' "$plan" >"$tmp"
    /usr/bin/ditto "$tmp" "$plan"
    rm -f "$tmp"
}

# ---------- 终端多选 UI：↑↓ 移动，空格切换，Enter 确认 ----------

_UI_STTY_SAVE=""

ui_restore_tty() {
    # 恢复光标显示，再还原终端属性
    printf '\033[?25h' 2>/dev/null || true
    if [ -n "${_UI_STTY_SAVE:-}" ]; then
        stty "${_UI_STTY_SAVE}" 2>/dev/null || true
    fi
}

# 回到左上角并清掉下方旧内容（比整屏 2J 闪烁小很多），重绘时隐藏光标
ui_redraw_begin() {
    printf '\033[?25l\033[H\033[J'
}

# 输出：up / down / space / enter / all / none / quit / other
ui_read_key() {
    c="$(dd bs=1 count=1 2>/dev/null)"
    case "$c" in
        " ")
            printf 'space'
            return 0
            ;;
        a|A)
            printf 'all'
            return 0
            ;;
        n|N)
            printf 'none'
            return 0
            ;;
        q|Q)
            printf 'quit'
            return 0
            ;;
        j|J)
            printf 'down'
            return 0
            ;;
        k|K)
            printf 'up'
            return 0
            ;;
        "")
            # 部分环境 Enter 读到空
            printf 'enter'
            return 0
            ;;
    esac

    # Enter：换行或回车
    nl="$(printf '\n')"
    cr="$(printf '\r')"
    if [ "$c" = "$nl" ] || [ "$c" = "$cr" ]; then
        printf 'enter'
        return 0
    fi

    # 方向键：ESC [ A/B ，或 ESC O A/B
    esc="$(printf '\033')"
    if [ "$c" = "$esc" ]; then
        c2="$(dd bs=1 count=1 2>/dev/null)"
        c3="$(dd bs=1 count=1 2>/dev/null)"
        case "${c2}${c3}" in
            "[A"|"OA") printf 'up'; return 0 ;;
            "[B"|"OB") printf 'down'; return 0 ;;
        esac
    fi

    printf 'other'
}

# 分步多选：只展示 types 匹配的计划项
# 用法：checkbox_select_step "标题" "brew|cask" "$plan"
checkbox_select_step() {
    title="$1"
    types="$2"
    plan="$3"
    cursor=1
    total=0
    key=""
    mark=""
    pointer=""
    idx=0
    state=""
    type=""
    name=""
    id=""
    label=""

    total="$(plan_count_types "$plan" "$types")"
    if [ "$total" -eq 0 ]; then
        echo "ℹ️  ${title}：无可选项，跳过"
        return 0
    fi

    _UI_STTY_SAVE="$(stty -g)"
    # 只钩 INT/TERM，避免覆盖 init.sh 的 EXIT 清理 trap
    trap 'ui_restore_tty; exit 130' INT
    trap 'ui_restore_tty; exit 143' TERM
    stty -echo -icanon min 1 time 0 2>/dev/null

    while true; do
        # 一帧内容用一次 awk 生成，避免循环里反复清屏/fork 造成闪烁
        frame="$(
            awk -F'|' -v types="$types" -v cursor="$cursor" -v title="$title" -v total="$total" '
                BEGIN {
                    OFS = ""
                    n = split(types, arr, "|")
                    for (i = 1; i <= n; i++) if (arr[i] != "") want[arr[i]] = 1
                    selected = 0
                    idx = 0
                    print "======== " title " ========"
                    print "↑↓ 移动   空格 选中/取消   a 全选   n 全不选   Enter 确认   q 退出"
                    print "（默认已全选，可取消不需要的项）"
                    print ""
                }
                want[$2] {
                    idx++
                    if ($1 == "ON") {
                        mark = "[x]"
                        selected++
                    } else {
                        mark = "[ ]"
                    }
                    pointer = (idx == cursor) ? ">" : " "
                    type = $2
                    name = $3
                    extra = $4
                    if (type == "defaults" || type == "dock") {
                        label = (extra != "") ? extra : name
                    } else if (type == "plugin") {
                        label = (extra != "") ? extra : name
                    } else if (type == "brew") {
                        label = "[brew] " name
                    } else if (type == "cask") {
                        label = "[cask] " name
                    } else {
                        label = name
                    }
                    print pointer " " mark " " label
                }
                END {
                    print ""
                    print "已选 " selected " / " total
                }
            ' "$plan"
        )"

        ui_redraw_begin
        printf '%s\n' "$frame"

        key="$(ui_read_key)"
        case "$key" in
            up)
                if [ "$cursor" -gt 1 ]; then
                    cursor=$((cursor - 1))
                fi
                ;;
            down)
                if [ "$cursor" -lt "$total" ]; then
                    cursor=$((cursor + 1))
                fi
                ;;
            space)
                plan_toggle_nth_of_types "$plan" "$types" "$cursor"
                ;;
            all)
                plan_set_types_state "$plan" "$types" "ON"
                ;;
            none)
                plan_set_types_state "$plan" "$types" "OFF"
                ;;
            enter)
                break
                ;;
            quit)
                ui_restore_tty
                trap - INT TERM
                echo
                echo "👋 已退出"
                return 2
                ;;
        esac
    done

    ui_restore_tty
    trap - INT TERM
    echo
    echo "✅ 已确认：${title}"
}

# 分步编辑计划：模块 → Homebrew → App Store
# 返回 2 表示用户按 q 退出
edit_plan_interactive() {
    plan="$1"
    yes_mode="${2:-0}"

    if [ "$yes_mode" = "1" ] || [ ! -t 0 ]; then
        echo "ℹ️  非交互模式：使用默认全选计划"
        return 0
    fi

    echo
    echo "接下来分步选择要执行的内容（默认全选）。按 q 可随时退出。"
    checkbox_select_step "步骤 1/5：系统设置（逐项确认）" "defaults" "$plan" || return $?
    checkbox_select_step "步骤 2/5：Dock（逐项确认）" "dock" "$plan" || return $?
    checkbox_select_step "步骤 3/5：Homebrew 软件（formula / cask）" "brew|cask" "$plan" || return $?
    if [ "$(plan_count_types "$plan" "mas")" -gt 0 ]; then
        checkbox_select_step "步骤 4/5：App Store 应用（mas）" "mas" "$plan" || return $?
    else
        echo "ℹ️  步骤 4/5：Brewfile 中无 App Store 应用，跳过"
    fi
    checkbox_select_step "步骤 5/5：插件（Oh My Zsh 等）" "plugin" "$plan" || return $?

    echo
    echo "选项已确认，开始装机（中途不再询问模块选项）。"
}
