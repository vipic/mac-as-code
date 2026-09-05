#!/bin/sh
# 共用辅助函数：结果记录、Brewfile 解析、分步多选 UI。
# 由 init.sh 与 scripts/ 下脚本以 `.` 加载，不要直接执行。
# 兼容 sh 与 bash（避免 bash 独有语法）。

# 新安装的 Homebrew 无需重新打开终端也能被后续任务发现。
if ! command -v brew >/dev/null 2>&1; then
    for brew_prefix in /opt/homebrew /usr/local; do
        if [ -x "$brew_prefix/bin/brew" ]; then
            PATH="$brew_prefix/bin:$brew_prefix/sbin:$PATH"
            export PATH
            break
        fi
    done
fi

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
    summary_file="${1:-${MAC_AS_CODE_RESULTS:-}}"
    [ -f "$summary_file" ] || { echo "没有执行结果。"; return 0; }
    echo
    awk -F '\t' '
        $2 ~ /^步骤:/ { if ($1 == "FAIL") print "未完成阶段  " $2 "：" $3; next }
        $1 == "OK" { if ($3 ~ /已安装/) met++; else ok++; next }
        $1 == "SKIP" { skip++; next }
        $1 == "FAIL" { fail++; print "失败  " $2 "：" $3 }
        END { printf "执行结束：完成 %d，已满足 %d，跳过 %d，失败 %d\n", ok, met, skip, fail }
    ' "$summary_file"
    ! grep -q "$(printf '^FAIL\t')" "$summary_file"
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
        if [ -t 0 ]; then
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

# 列出 config/recipes/*.sh：输出 id|说明
# 约定：文件名（去 .sh）为 id；文件内首个「# id | 说明」提供多选文案（id 应与文件名一致）。
list_recipe_items() {
    recipes_dir="$1"
    f=""
    id=""
    meta=""
    meta_id=""
    label=""

    [ -d "$recipes_dir" ] || return 0

    for f in "$recipes_dir"/*.sh; do
        [ -f "$f" ] || continue
        id="$(basename "$f" .sh)"
        meta="$(list_annotated_shell_items "$f" | awk 'NR == 1 { print; exit }')"
        if [ -n "$meta" ]; then
            meta_id="${meta%%|*}"
            label="${meta#*|}"
            if [ "$meta_id" != "$id" ]; then
                echo "⚠️  Recipe ${f}：项头 id「${meta_id}」与文件名「${id}」不一致，以文件名为准" >&2
            fi
            [ -n "$label" ] || label="$id"
        else
            label="$id"
        fi
        printf '%s|%s\n' "$id" "$label"
    done
}

# 解析 config/github_release_apps.conf。
# 格式：每行一个 GitHub 仓库（owner/repo），仓库名首字母大写后作为 App 名称。
# 输出：id|显示名称|仓库|App 名称|安装路径。
# 空行和以 # 开头的注释行会忽略。
parse_github_release_apps() {
    config_file="$1"
    line=""
    app_id=""
    label=""
    repository=""
    app_name=""
    app_path=""

    [ -f "$config_file" ] || return 0

    while IFS= read -r line || [ -n "$line" ]; do
        line="$(trim "$line")"
        case "$line" in
            ''|\#*) continue ;;
        esac

        repository="$line"
        app_name=""
        case "$line" in
            *\|*)
                repository="$(trim "${line%%|*}")"
                app_name="$(trim "${line#*|}")"
                ;;
        esac
        repository_name="${repository##*/}"
        if [ -z "$app_name" ]; then
            app_name="$(
                printf '%s\n' "$repository_name" |
                    awk '{
                        print toupper(substr($0, 1, 1)) substr($0, 2)
                    }'
            )"
        fi
        app_id="$(
            printf '%s\n' "$repository_name" |
                tr '[:upper:]' '[:lower:]' |
                tr '.' '-'
        )"
        label="$app_name"
        app_path="/Applications/${app_name}.app"
        printf '%s|%s|%s|%s|%s\n' \
            "$app_id" "$label" "$repository" "$app_name" "$app_path"
    done <"$config_file"
}

# 列出 GitHub Releases 应用：输出 id|说明
list_github_release_app_items() {
    config_file="$1"

    parse_github_release_apps "$config_file" |
        while IFS='|' read -r app_id label _repository _app_name _app_path; do
            [ -n "$app_id" ] || continue
            printf '%s|%s\n' "$app_id" "$label"
        done
}

# 计划文件格式：ON|type|name|extra 或 OFF|type|name|extra
# type: defaults|dock|recipe|github-release|brew|cask|mas
# defaults/dock/recipe/github-release 的 extra 为说明；mas 的 extra 为 App Store id
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
        if [ -n "$config_dir" ] && [ -d "$config_dir/recipes" ]; then
            list_recipe_items "$config_dir/recipes" | while IFS='|' read -r item_id item_label; do
                [ -n "$item_id" ] || continue
                printf 'ON|recipe|%s|%s\n' "$item_id" "$item_label"
            done
        fi
        if [ -n "$config_dir" ] && [ -f "$config_dir/github_release_apps.conf" ]; then
            list_github_release_app_items "$config_dir/github_release_apps.conf" |
                while IFS='|' read -r item_id item_label; do
                    [ -n "$item_id" ] || continue
                    printf 'ON|github-release|%s|%s\n' "$item_id" "$item_label"
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
    [ ! -t 1 ] || printf '\033[?25h' 2>/dev/null || true
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
        b|B)
            printf 'back'
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
        stty min 0 time 1 2>/dev/null
        c2="$(dd bs=1 count=1 2>/dev/null)"
        c3="$(dd bs=1 count=1 2>/dev/null)"
        stty min 1 time 0 2>/dev/null
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
    selection_hint="${4:-选择要处理的项目}"
    cursor=1
    total="$(plan_count_types "$plan" "$types")"
    [ "$total" -gt 0 ] || { echo "没有可调整的项目。"; return 0; }
    if [ ! -t 0 ] || [ ! -t 1 ]; then
        echo "选择项目需要交互终端。" >&2
        return 1
    fi
    selection_original="$(mktemp -t mac-as-code-selection.XXXXXX)" || return 1
    cp "$plan" "$selection_original"
    _UI_STTY_SAVE="$(stty -g)"
    trap 'ui_restore_tty; exit 130' INT
    trap 'ui_restore_tty; exit 143' TERM
    stty -echo -icanon min 1 time 0 2>/dev/null
    while true; do
        terminal_rows="$(stty size 2>/dev/null | awk '{ print $1 }')"
        terminal_columns="$(stty size 2>/dev/null | awk '{ print $2 }')"
        case "$terminal_rows" in ''|*[!0-9]*) terminal_rows=24 ;; esac
        case "$terminal_columns" in ''|*[!0-9]*) terminal_columns=80 ;; esac
        [ "$terminal_rows" -ge 12 ] || terminal_rows=12
        [ "$terminal_columns" -ge 30 ] || terminal_columns=30
        visible_rows=$(((terminal_rows - 11) / 2))
        [ "$visible_rows" -ge 1 ] || visible_rows=1
        first_row=$((((cursor - 1) / visible_rows) * visible_rows + 1))
        details_file="${MAC_AS_CODE_UI_DETAILS:-/dev/null}"
        [ -f "$details_file" ] || details_file=/dev/null
        frame="$(awk -v types="$types" -v cursor="$cursor" -v first="$first_row" -v rows="$visible_rows" -v width="$terminal_columns" -v title="$title" -v hint="$selection_hint" '
            BEGIN {
                split(types, arr, "|"); for (i in arr) want[arr[i]]=1
                print title
                print "↑↓ / j k 移动 · 空格 切换 · a 全选 · n 清空"
                print "Enter 确认选择"
                print "b 返回（放弃本次调整）"
                print "q 退出程序（不执行本次选择）"
                print hint "\n"
            }
            FILENAME == ARGV[1] {
                split($0,d,"\t"); descriptions[d[1] SUBSEP d[2]]=d[5]; statuses[d[1] SUBSEP d[2]]=d[3]; next
            }
            {
                split($0,p,"|"); if (!want[p[2]]) next
                idx++; if (p[1]=="ON") selected++
                if (idx < first || idx >= first+rows) next
                label = (p[2]=="brew" || p[2]=="cask" || p[2]=="mas") ? p[3] : p[4]
                detail=descriptions[p[2] SUBSEP p[3]]
                if (p[2]=="audit") detail=p[5]
                marker=(statuses[p[2] SUBSEP p[3]]=="manual") ? " [需确认]" : ""
                # 中文保守按双列预留，避免窄窗口自动换行挤掉页脚。
                limit=int((width-10)/2)
                if (length(label)>limit) label=substr(label,1,limit-1) "…"
                if (length(detail)>limit) detail=substr(detail,1,limit-1) "…"
                print (idx==cursor ? "> " : "  ") (p[1]=="ON" ? "[x] " : "[ ] ") label marker
                print "      " detail
            }
            END { printf "\n已选 %d / %d · 第 %d 项（详情可返回查看）\n", selected,idx,cursor }
        ' "$details_file" "$plan")"
        ui_redraw_begin
        printf '%s\n' "$frame"
        key="$(ui_read_key)"
        case "$key" in
            up) [ "$cursor" -le 1 ] || cursor=$((cursor - 1)) ;;
            down) [ "$cursor" -ge "$total" ] || cursor=$((cursor + 1)) ;;
            space) plan_toggle_nth_of_types "$plan" "$types" "$cursor" ;;
            all) plan_set_types_state "$plan" "$types" ON ;;
            none) plan_set_types_state "$plan" "$types" OFF ;;
            enter) selection_status=0; break ;;
            back) cp "$selection_original" "$plan"; selection_status=3; break ;;
            quit) cp "$selection_original" "$plan"; selection_status=2; break ;;
        esac
    done
    ui_restore_tty
    _UI_STTY_SAVE=""
    trap - INT TERM
    rm -f "$selection_original"
    echo
    return "$selection_status"
}
