#!/bin/sh
# 共用辅助函数：结果记录、Brewfile 解析、分步多选 UI。
# 由执行器 apply.sh 与 scripts/ 下脚本以 `.` 加载，不要直接执行。
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

# 初始化结果文件。若由执行器 apply.sh 导出 MAC_AS_CODE_RESULTS，则复用（不清空）；否则自建。
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

# ---------- 共用终端界面：顶部说明 / 操作区 / 灰色页脚 ----------
_UI_STTY_SAVE=""
_UI_SAVED_TRAPS=""

ui_size() {
    # shellcheck disable=SC2046 # stty 输出两项数字，按空白拆分。
    set -- $(stty size 2>/dev/null)
    UI_ROWS="${1:-24}"; UI_COLS="${2:-80}"
    [ "$UI_ROWS" -gt 0 ] 2>/dev/null || UI_ROWS=24
    [ "$UI_COLS" -gt 0 ] 2>/dev/null || UI_COLS=80
    UI_BODY_ROWS=$((UI_ROWS - 9))
    [ "$UI_BODY_ROWS" -ge 1 ] || UI_BODY_ROWS=1
}

ui_enter() {
    [ -t 0 ] && [ -t 1 ] || return 1
    _UI_STTY_SAVE="$(stty -g)" || return 1
    _UI_SAVED_TRAPS="$(trap)"
    trap 'ui_restore_tty; exit 130' INT
    trap 'ui_restore_tty; exit 143' TERM
    trap 'ui_restore_tty; exit 129' HUP
    stty -echo -icanon -ixon min 1 time 0 || return 1
    printf '\033[r'
}

ui_restore_tty() {
    [ ! -t 1 ] || printf '\033[r\033[0m\033[?25h'
    if [ -n "$_UI_STTY_SAVE" ]; then
        stty "$_UI_STTY_SAVE" 2>/dev/null || true
        _UI_STTY_SAVE=""
    fi
}

ui_leave() {
    ui_restore_tty
    trap - INT TERM HUP
    # 恢复本进程保存的 trap 声明，不执行用户输入。
    eval "$_UI_SAVED_TRAPS"
    printf '\033[%s;1H' "$UI_ROWS"
}

# 尾部标记保留换行，以区分 Enter 和 EOF。
ui_read_char() {
    UI_CHAR="$(dd bs=1 count=1 2>/dev/null; printf '.')"
    UI_CHAR="${UI_CHAR%.}"
}

ui_read_key() {
    ui_read_char
    case "$UI_CHAR" in
        '') printf eof ;;
        "$(printf '\r')"|'
') printf enter ;;
        ' ') printf space ;;
        q|Q|"$(printf '\021')") printf quit ;;
        b|B) printf back ;;
        j|J) printf down ;;
        k|K) printf up ;;
        a|A) printf all ;;
        n|N) printf none ;;
        y|Y) printf yes ;;
        "$(printf '\004')") printf eof ;;
        "$(printf '\033')")
            stty min 0 time 1 2>/dev/null
            ui_read_char
            UI_ESCAPE="$UI_CHAR"
            case "$UI_ESCAPE" in
                '['|'O')
                    ui_read_char
                    UI_ESCAPE="$UI_ESCAPE$UI_CHAR"
                    case "$UI_CHAR" in
                        [0-9]) ui_read_char; UI_ESCAPE="$UI_ESCAPE$UI_CHAR" ;;
                    esac ;;
            esac
            stty min 1 time 0 2>/dev/null
            case "$UI_ESCAPE" in
                '[A'|'OA') printf up ;;
                '[B'|'OB') printf down ;;
                '[5~') printf pageup ;;
                '[6~') printf pagedown ;;
                '') printf back ;;
                *) printf other ;;
            esac ;;
        *) printf other ;;
    esac
}

# ASCII 占一列；中文等字符保守按两列排版。
ui_wrap() {
    LC_ALL=C awk -v width="$1" '
        {
            used=0
            for(i=1;i<=length($0);i++) {
                c=substr($0,i,1)
                if(c ~ /[\300-\337]/) { c=substr($0,i,2); i++ }
                else if(c ~ /[\340-\357]/) { c=substr($0,i,3); i+=2 }
                else if(c ~ /[\360-\367]/) { c=substr($0,i,4); i+=3 }
                w=(c ~ /^[ -~]$/)?1:2
                if(used+w>width) { printf "\n"; used=0 }
                printf "%s",c; used+=w
            }
            printf "\n"
        }'
}
ui_clip() { ui_wrap "$1" | sed -n '1p'; }

# 先在内存中生成整帧，最后一次输出；覆盖新内容后才清除行尾残留。
# 光标移动期间不清屏、不重置滚动区域，避免计算和子进程输出之间露出空白。
ui_frame() {
    case "${4:-back}" in
        root) UI_NAV='q 退出' ;;
        edit) UI_NAV='Esc 返回 · Ctrl+Q 退出' ;;
        run) UI_NAV='Ctrl+C 中止当前任务' ;;
        *) UI_NAV='b 返回 · q 退出' ;;
    esac
    UI_FRAME_OUTPUT="$(
        printf '\033[?25l\033[1;1H\033[1;36mmac-as-code\033[0m\033[K'
        printf '\033[2;1H\033[90m%s\033[0m\033[K' "$(printf '%s\n' '让每一台 Mac，都回到你的习惯。' | ui_clip "$UI_COLS")"
        printf '\033[3;1H\033[90m%s\033[0m\033[K' "$(printf '%s\n' '以配置清单为准，确认后再执行。' | ui_clip "$UI_COLS")"
        printf '\033[4;1H\033[K\033[5;1H\033[1m%s\033[0m\033[K' "$(printf '%s\n' "$1" | ui_clip "$UI_COLS")"
        printf '%s\n' "$2" | awk -v count="$UI_BODY_ROWS" '
            NR <= count { printf "\033[%d;1H%s\033[K", NR+5, $0 }
            END {
                for (row=(NR<count ? NR : count)+1; row<=count; row++)
                    printf "\033[%d;1H\033[K", row+5
            }'
        printf '\033[%s;1H\033[K' "$UI_ROWS"
        printf '\033[%s;1H\033[K' "$((UI_ROWS - 3))"
        printf '\033[%s;1H\033[90m%s\033[0m\033[K' "$((UI_ROWS - 2))" "$(printf '%s\n' "$3" | ui_clip "$UI_COLS")"
        printf '\033[%s;1H\033[90m%s\033[0m\033[K' "$((UI_ROWS - 1))" "$UI_NAV"
        if [ -n "${5:-}" ]; then
            printf '\033[%s;1H\033[90m%s\033[0m\033[K' "$((UI_ROWS - 3))" "$(printf '%s\n' "$5" | ui_clip "$UI_COLS")"
        fi
    )"
    printf '%s' "$UI_FRAME_OUTPUT"
}

# 返回 0 选中（answer 为序号）、2 退出、3 返回、1 终端不可用。
ui_select() {
    UI_MENU_TITLE="$1"; UI_MENU_CONTEXT="$2"; UI_MENU_MODE="$3"
    shift 3
    UI_MENU_OPTIONS="$(printf '%s\n' "$@")"
    UI_MENU_COUNT=$#; UI_MENU_CURSOR=1
    [ "$UI_MENU_COUNT" -gt 0 ] || return 1
    ui_enter || return 1
    while true; do
        ui_size
        UI_CONTEXT="$(printf '%s\n' "$UI_MENU_CONTEXT" | ui_wrap "$UI_COLS")"
        UI_CONTEXT_ROWS="$(printf '%s\n' "$UI_CONTEXT" | awk 'NF {n++} END {print n+0}')"
        UI_CONTEXT_MAX=$((UI_BODY_ROWS / 2))
        [ "$UI_CONTEXT_ROWS" -le "$UI_CONTEXT_MAX" ] || UI_CONTEXT_ROWS=$UI_CONTEXT_MAX
        UI_MENU_VISIBLE=$((UI_BODY_ROWS - UI_CONTEXT_ROWS))
        [ "$UI_MENU_VISIBLE" -ge 1 ] || UI_MENU_VISIBLE=1
        UI_MENU_FIRST=$((((UI_MENU_CURSOR - 1) / UI_MENU_VISIBLE) * UI_MENU_VISIBLE + 1))
        UI_MENU_BODY="$(
            if [ "$UI_CONTEXT_ROWS" -gt 0 ]; then printf '%s\n' "$UI_CONTEXT" | sed -n "1,${UI_CONTEXT_ROWS}p"; fi
            printf '%s\n' "$UI_MENU_OPTIONS" | LC_ALL=C awk -v cur="$UI_MENU_CURSOR" -v first="$UI_MENU_FIRST" -v count="$UI_MENU_VISIBLE" -v width="$UI_COLS" '
                NR>=first && NR<first+count {
                    label=""; used=4
                    for(i=1;i<=length($0);i++) {
                        c=substr($0,i,1)
                        if(c ~ /[\300-\337]/) { c=substr($0,i,2); i++ }
                        else if(c ~ /[\340-\357]/) { c=substr($0,i,3); i+=2 }
                        else if(c ~ /[\360-\367]/) { c=substr($0,i,4); i+=3 }
                        w=(c ~ /^[ -~]$/)?1:2
                        if(used+w>width-1) break
                        label=label c; used+=w
                    }
                    if(NR==cur) printf "\033[36m  › %s\033[0m\n",label
                    else printf "    %s\n",label
                }'
        )"
        ui_frame "$UI_MENU_TITLE" "$UI_MENU_BODY" "↑↓ 选择 · Enter 执行" "$UI_MENU_MODE"
        UI_KEY="$(ui_read_key)"
        case "$UI_KEY" in
            up) [ "$UI_MENU_CURSOR" -le 1 ] || UI_MENU_CURSOR=$((UI_MENU_CURSOR - 1)) ;;
            down) [ "$UI_MENU_CURSOR" -ge "$UI_MENU_COUNT" ] || UI_MENU_CURSOR=$((UI_MENU_CURSOR + 1)) ;;
            enter) answer="$UI_MENU_CURSOR"; ui_leave; return 0 ;;
            back) if [ "$UI_MENU_MODE" != root ]; then ui_leave; return 3; fi ;;
            quit|eof) ui_leave; return 2 ;;
        esac
    done
}

ui_document() {
    UI_DOC_TITLE="$1"; UI_DOC_TEXT="$2"; UI_DOC_MODE="${3:-back}"
    UI_DOC_OFFSET=1
    ui_enter || return 1
    while true; do
        ui_size
        UI_DOC_WRAPPED="$(printf '%s\n' "$UI_DOC_TEXT" | ui_wrap "$UI_COLS")"
        UI_DOC_LINES="$(printf '%s\n' "$UI_DOC_WRAPPED" | wc -l | tr -d ' ')"
        UI_DOC_MAX=$((UI_DOC_LINES - UI_BODY_ROWS + 1))
        [ "$UI_DOC_MAX" -ge 1 ] || UI_DOC_MAX=1
        [ "$UI_DOC_OFFSET" -le "$UI_DOC_MAX" ] || UI_DOC_OFFSET="$UI_DOC_MAX"
        UI_DOC_BODY="$(printf '%s\n' "$UI_DOC_WRAPPED" | sed -n "${UI_DOC_OFFSET},$((UI_DOC_OFFSET + UI_BODY_ROWS - 1))p")"
        case "$UI_DOC_MODE" in
            confirm) UI_DOC_HINT='↑↓ 滚动 · Enter / y 确认' ;;
            login) UI_DOC_HINT='↑↓ 滚动 · Enter 检查登录' ;;
            *) UI_DOC_HINT="↑↓ 滚动 · $UI_DOC_OFFSET / $UI_DOC_LINES 行" ;;
        esac
        ui_frame "$UI_DOC_TITLE" "$UI_DOC_BODY" "$UI_DOC_HINT"
        UI_KEY="$(ui_read_key)"
        case "$UI_KEY" in
            up) [ "$UI_DOC_OFFSET" -le 1 ] || UI_DOC_OFFSET=$((UI_DOC_OFFSET - 1)) ;;
            down) [ "$UI_DOC_OFFSET" -ge "$UI_DOC_MAX" ] || UI_DOC_OFFSET=$((UI_DOC_OFFSET + 1)) ;;
            pageup) UI_DOC_OFFSET=$((UI_DOC_OFFSET - UI_BODY_ROWS)); [ "$UI_DOC_OFFSET" -ge 1 ] || UI_DOC_OFFSET=1 ;;
            pagedown) UI_DOC_OFFSET=$((UI_DOC_OFFSET + UI_BODY_ROWS)) ;;
            enter|yes)
                if [ "$UI_DOC_MODE" = confirm ] || { [ "$UI_DOC_MODE" = login ] && [ "$UI_KEY" = enter ]; }; then
                    ui_leave; return 0
                fi ;;
            back) ui_leave; return 3 ;;
            quit|eof) ui_leave; return 2 ;;
        esac
    done
}

confirm_action() { ui_document "$1" "${2:-请确认以上操作。}" confirm; }

# 路径为空时 b/q 即时导航；编辑时 Esc / Ctrl+Q 导航，字母按字面输入。
ui_path() {
    UI_PATH_TITLE="$1"; UI_PATH_NOTE="$2"; answer=""
    ui_enter || return 1
    while true; do
        ui_size
        UI_PATH_VISIBLE=$((UI_BODY_ROWS - 2))
        [ "$UI_PATH_VISIBLE" -ge 1 ] || UI_PATH_VISIBLE=1
        UI_PATH_BODY="$(
            printf '%s\n\n' "$(printf '%s\n' "$UI_PATH_NOTE" | ui_clip "$UI_COLS")"
            printf '> %s_\n' "$answer" | ui_wrap "$UI_COLS" | tail -n "$UI_PATH_VISIBLE"
        )"
        UI_PATH_MODE=edit
        [ -n "$answer" ] || UI_PATH_MODE=back
        ui_frame "$UI_PATH_TITLE" "$UI_PATH_BODY" '输入路径 · Enter 使用' "$UI_PATH_MODE"
        ui_read_char
        # 一次收齐 UTF-8 字符，避免逐字节重绘时暂时出现乱码。
        if [ -n "$UI_CHAR" ]; then
            UI_CHAR_CODE="$(LC_ALL=C printf '%d' "'$UI_CHAR")"
            UI_CHAR_EXTRA=0
            if [ "$UI_CHAR_CODE" -ge 240 ]; then UI_CHAR_EXTRA=3
            elif [ "$UI_CHAR_CODE" -ge 224 ]; then UI_CHAR_EXTRA=2
            elif [ "$UI_CHAR_CODE" -ge 192 ]; then UI_CHAR_EXTRA=1
            fi
            if [ "$UI_CHAR_EXTRA" -gt 0 ]; then
                UI_CHAR="$UI_CHAR$(dd bs=1 count="$UI_CHAR_EXTRA" 2>/dev/null)"
            fi
        fi
        case "$UI_CHAR" in
            ''|"$(printf '\004')"|"$(printf '\021')") ui_leave; return 2 ;;
            "$(printf '\r')"|'
') ui_leave; return 0 ;;
            "$(printf '\033')") ui_leave; return 3 ;;
            "$(printf '\177')"|"$(printf '\010')")
                answer="$(printf '%s\n' "$answer" | LC_ALL=C awk '{sub(/[^\200-\277][\200-\277]*$/, ""); print}')" ;;
            "$(printf '\025')") answer="" ;;
            q|Q) if [ -z "$answer" ]; then ui_leave; return 2; else answer="$answer$UI_CHAR"; fi ;;
            b|B) if [ -z "$answer" ]; then ui_leave; return 3; else answer="$answer$UI_CHAR"; fi ;;
            *) answer="$answer$UI_CHAR" ;;
        esac
    done
}

ui_execution() {
    ui_size
    printf '\033[r'
    ui_frame "$1" "${2:-正在执行，请查看下方结果。}" '' run
    # 将执行输出限制在中间区域，长日志不会把顶部说明和页脚推走。
    printf '\033[6;%sr\033[7;1H\033[?25h' "$((UI_ROWS - 4))"
}

checkbox_select_step() {
    title="$1"; types="$2"; plan="$3"
    selection_hint="${4:-空格勾选需要处理的项目}"
    cursor=1
    total="$(plan_count_types "$plan" "$types")"
    if [ "$total" -eq 0 ]; then
        ui_document "$title" "没有可调整的项目。"
        return $?
    fi
    [ -t 0 ] && [ -t 1 ] || return 1
    selection_original="$(mktemp -t mac-as-code-selection.XXXXXX)" || return 1
    cp "$plan" "$selection_original"
    ui_enter || { rm -f "$selection_original"; return 1; }
    while true; do
        ui_size
        visible_rows=$(((UI_BODY_ROWS - 1) / 2))
        [ "$visible_rows" -ge 1 ] || visible_rows=1
        first_row=$((((cursor - 1) / visible_rows) * visible_rows + 1))
        details_file="${MAC_AS_CODE_UI_DETAILS:-/dev/null}"
        [ -f "$details_file" ] || details_file=/dev/null
        frame="$(LC_ALL=C awk -v types="$types" -v cursor="$cursor" -v first="$first_row" -v rows="$visible_rows" -v width="$UI_COLS" '
            function clip(s,   i,c,w,used,out) {
                used=6; out=""
                for(i=1;i<=length(s);i++) {
                    c=substr(s,i,1)
                    if(c ~ /[\300-\337]/) { c=substr(s,i,2); i++ }
                    else if(c ~ /[\340-\357]/) { c=substr(s,i,3); i+=2 }
                    else if(c ~ /[\360-\367]/) { c=substr(s,i,4); i+=3 }
                    w=(c ~ /^[ -~]$/)?1:2
                    if(used+w>width-1) return out "…"
                    out=out c; used+=w
                }
                return out
            }
            BEGIN { split(types,arr,"|"); for(i in arr) want[arr[i]]=1 }
            FILENAME==ARGV[1] {
                split($0,d,"\t"); descriptions[d[1] SUBSEP d[2]]=d[5]; statuses[d[1] SUBSEP d[2]]=d[3]; next
            }
            {
                split($0,p,"|"); if(!want[p[2]]) next
                idx++; if(p[1]=="ON") selected++
                if(idx<first || idx>=first+rows) next
                label=(p[2]=="brew" || p[2]=="cask" || p[2]=="mas") ? p[3] : p[4]
                detail=descriptions[p[2] SUBSEP p[3]]
                if(p[2]=="audit") detail=p[5]
                if(statuses[p[2] SUBSEP p[3]]=="manual") label=label " [需确认]"
                printf "%s%s%s%s\n", (idx==cursor ? "\033[36m› " : "  "), (p[1]=="ON" ? "[x] " : "[ ] "), clip(label), "\033[0m"
                printf "\033[90m      %s\033[0m\n",clip(detail)
            }
            END { printf "已选 %d / %d · 第 %d 项\n",selected,idx,cursor }
        ' "$details_file" "$plan")"
        ui_frame "$title" "$frame" '↑↓ 移动 · 空格切换 · a 全选 · n 清空' back "Enter 保存 · $selection_hint"
        key="$(ui_read_key)"
        case "$key" in
            up) [ "$cursor" -le 1 ] || cursor=$((cursor - 1)) ;;
            down) [ "$cursor" -ge "$total" ] || cursor=$((cursor + 1)) ;;
            space) plan_toggle_nth_of_types "$plan" "$types" "$cursor" ;;
            all) plan_set_types_state "$plan" "$types" ON ;;
            none) plan_set_types_state "$plan" "$types" OFF ;;
            enter) selection_status=0; break ;;
            back) cp "$selection_original" "$plan"; selection_status=3; break ;;
            quit|eof) cp "$selection_original" "$plan"; selection_status=2; break ;;
        esac
    done
    ui_leave
    rm -f "$selection_original"
    return "$selection_status"
}
