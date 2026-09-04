#!/bin/sh
# 比较当前 Mac 与仓库配置，并按用户选择补全 Brewfile。
set -u

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"
# shellcheck source=common.sh
. "$SCRIPTS_DIR/common.sh"

DEFAULTS_CONFIG="${MAC_AS_CODE_DEFAULTS_CONFIG:-$ROOT_DIR/config/defaults_config.sh}"
DOCK_CONFIG="${MAC_AS_CODE_DOCK_CONFIG:-$ROOT_DIR/config/defaults_dock.sh}"
BREWFILE="${MAC_AS_CODE_BREWFILE:-$ROOT_DIR/config/Brewfile}"
GITHUB_APPS_CONFIG="${MAC_AS_CODE_GITHUB_APPS_CONFIG:-$ROOT_DIR/config/github_release_apps.conf}"
APPLICATIONS_DIR="${MAC_AS_CODE_APPLICATIONS_DIR:-/Applications}"
STATE_DIR="${MAC_AS_CODE_STATE_DIR:-$HOME/.local/state/mac-as-code}"
BASELINE_FILE="$STATE_DIR/defaults-baseline.tsv"
CACHE_DIR="${MAC_AS_CODE_CACHE_DIR:-$HOME/.cache/mac-as-code/audit}"
CACHE_STAMP="$CACHE_DIR/date"
CACHE_DEFAULTS="$CACHE_DIR/defaults.out"
CACHE_APPS="$CACHE_DIR/apps.out"
CACHE_CHANGES="$CACHE_DIR/changes.out"
CACHE_ALL="$CACHE_DIR/all.out"
CACHE_ACTIONS="$CACHE_DIR/actions.tsv"
CACHE_VERSION=5
CATALOG=""
QUIET=0
REFRESH=0
CACHE_WAS_REFRESHED=0
TABLE_AGGREGATE_FILE=""
ACTIONS_FILE=""

usage() {
    cat <<'EOF'
用法：sh scripts/audit.sh [命令] [--refresh]

查询（不修改电脑或仓库）
  sh scripts/audit.sh             查看配置、应用和初始化后变化
  sh scripts/audit.sh defaults    比较 macOS / Dock 设置与仓库期望值
  sh scripts/audit.sh apps        比较本机软件与 Brewfile / GitHub 清单
  sh scripts/audit.sh changes     查看初始化后又被修改的受管理设置

处理
  sh scripts/audit.sh append      多选本机已有、Brewfile 没有的软件并追加
  sh scripts/audit.sh review      审计后进入 init.sh，选择要应用的配置和软件

维护（通常由脚本自动执行）
  sh scripts/audit.sh snapshot    将当前受管理设置保存为变化基线

查询帮助
  sh scripts/audit.sh help        显示这份命令清单

通用选项
  -r, --refresh                   忽略当天缓存，实时查询并更新缓存

数据位置
  当天缓存  ~/.cache/mac-as-code/audit/
  变化基线  ~/.local/state/mac-as-code/defaults-baseline.tsv

说明：当天第一次查询实时生成缓存，之后立即读取；append 默认全部不选，
只追加你勾选且 Brewfile 尚未登记的软件。
EOF
}

cleanup() {
    [ -n "$CATALOG" ] && rm -f "$CATALOG"
}

build_catalog() {
    CATALOG="$(mktemp -t mac-as-code-audit.XXXXXX)" || return 1
    : >"$CATALOG"
    build_catalog_for_file defaults "$DEFAULTS_CONFIG" >>"$CATALOG" || return 1
    build_catalog_for_file dock "$DOCK_CONFIG" >>"$CATALOG" || return 1
}

# 输出 TSV：
# SETTING group id label domain key type expected
# UNSUPPORTED group id label reason
build_catalog_for_file() {
    group="$1"
    file="$2"
    if [ ! -f "$file" ]; then
        echo "❌ 配置文件不存在：$file" >&2
        return 1
    fi

    awk -v group="$group" '
        function clear_item(    i) {
            for (i = 1; i <= setting_count; i++) {
                delete domains[i]
                delete keys[i]
                delete types[i]
                delete values[i]
            }
            setting_count = 0
            unsupported = 0
            reason = ""
        }
        function flush_item(    i) {
            if (item_id == "") return
            if (unsupported || setting_count == 0) {
                if (reason == "") reason = "不属于可安全推导的 defaults write 标量命令"
                printf "UNSUPPORTED\t%s\t%s\t%s\t%s\n", group, item_id, label, reason
            } else {
                for (i = 1; i <= setting_count; i++) {
                    printf "SETTING\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", \
                        group, item_id, label, domains[i], keys[i], types[i], values[i]
                }
            }
            clear_item()
        }
        function trim(value) {
            sub(/^[[:space:]]+/, "", value)
            sub(/[[:space:]]+$/, "", value)
            return value
        }
        BEGIN { clear_item() }
        /^#[[:space:]]*[A-Za-z0-9_-]+[[:space:]]*\|/ {
            flush_item()
            header = $0
            sub(/^#[[:space:]]*/, "", header)
            item_id = header
            sub(/[[:space:]]*\|.*/, "", item_id)
            label = header
            sub(/^[^|]*\|[[:space:]]*/, "", label)
            in_item = 1
            next
        }
        !in_item { next }
        {
            line = trim($0)
            if (line == "" || line ~ /^#/) next
            if (line ~ /^defaults[[:space:]]+write[[:space:]]+/) {
                count = split(line, fields, /[[:space:]]+/)
                if (count >= 6 && fields[5] ~ /^-(bool|int|float|string)$/) {
                    value = line
                    sub(/^defaults[[:space:]]+write[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+-(bool|int|float|string)[[:space:]]+/, "", value)
                    value = trim(value)
                    if ((value ~ /^".*"$/) || (value ~ /^\047.*\047$/)) {
                        value = substr(value, 2, length(value) - 2)
                    }
                    if (value == "" || value ~ /[$`;&|<>]/) {
                        unsupported = 1
                        reason = "defaults 值包含动态表达式或 shell 控制符"
                        next
                    }
                    setting_count++
                    domains[setting_count] = fields[3]
                    keys[setting_count] = fields[4]
                    types[setting_count] = substr(fields[5], 2)
                    values[setting_count] = value
                    next
                }
            }
            unsupported = 1
            reason = "包含复合 defaults、循环或其他命令，无法安全只读推导"
        }
        END { flush_item() }
    ' "$file"
}

normalize_expected() {
    value_type="$1"
    value="$2"
    case "$value_type:$value" in
        bool:true|bool:YES|bool:yes) printf '1' ;;
        bool:false|bool:NO|bool:no) printf '0' ;;
        *) printf '%s' "$value" ;;
    esac
}

read_current_default() {
    domain="$1"
    key="$2"
    defaults read "$domain" "$key" 2>/dev/null
}

print_value() {
    value="$1"
    if [ "$value" = "__MAC_AS_CODE_MISSING__" ]; then
        printf '<不存在>'
    else
        printf '%s' "$value"
    fi
}

print_shell_quoted() {
    printf "'"
    printf '%s' "$1" | sed "s/'/'\\\\''/g"
    printf "'"
}

table_cell() {
    printf '%s' "$1" | tr '\t\n' '  '
}

table_row() {
    table_file="$1"
    shift
    separator=""
    {
        for cell in "$@"; do
            printf '%s' "$separator"
            table_cell "$cell"
            separator="$(printf '\t')"
        done
        printf '\n'
    } >>"$table_file"
}

table_start() {
    table_file="$1"
    shift
    table_row "$table_file" "$@"
    separator_count="$#"
    set --
    while [ "$separator_count" -gt 0 ]; do
        set -- "$@" "────────"
        separator_count=$((separator_count - 1))
    done
    table_row "$table_file" "$@"
}

table_render_to_file() {
    table_file="$1"
    output_file="$2"
    if command -v column >/dev/null 2>&1; then
        column -t -s "$(printf '\t')" "$table_file" >"$output_file"
    else
        cat "$table_file" >"$output_file"
    fi
}

table_render() {
    table_file="$1"
    aggregate="${2:-no}"
    rendered_file="$(mktemp -t mac-as-code-rendered-table.XXXXXX)" || return 1
    if table_render_to_file "$table_file" "$rendered_file"; then
        if [ "$aggregate" = "yes" ] && [ -n "$TABLE_AGGREGATE_FILE" ]; then
            if [ -s "$TABLE_AGGREGATE_FILE" ]; then
                horizontal_rule '-' >>"$TABLE_AGGREGATE_FILE"
            fi
            cat "$rendered_file" >>"$TABLE_AGGREGATE_FILE"
        fi
        cat "$rendered_file"
    else
        rm -f "$rendered_file"
        return 1
    fi
    rm -f "$table_file" "$rendered_file"
}

audit_note() {
    note="$1"
    printf '%s\n' "$note"
    if [ -n "$TABLE_AGGREGATE_FILE" ]; then
        printf '%s\n' "$note" >>"$TABLE_AGGREGATE_FILE"
    fi
}

audit_date() {
    if [ -n "${MAC_AS_CODE_AUDIT_DATE:-}" ]; then
        printf '%s' "$MAC_AS_CODE_AUDIT_DATE"
    else
        date '+%Y-%m-%d'
    fi
}

cache_is_fresh() {
    [ -f "$CACHE_STAMP" ] &&
        [ -f "$CACHE_DEFAULTS" ] &&
        [ -f "$CACHE_APPS" ] &&
        [ -f "$CACHE_CHANGES" ] &&
        [ -f "$CACHE_ALL" ] &&
        [ -f "$CACHE_ACTIONS" ] &&
        [ "$(awk -F'\t' 'NR == 1 { print $1 }' "$CACHE_STAMP")" = "$(audit_date)" ] &&
        [ "$(awk -F'\t' 'NR == 1 { print $3 }' "$CACHE_STAMP")" = "$CACHE_VERSION" ]
}

invalidate_cache() {
    rm -f "$CACHE_STAMP" "$CACHE_DEFAULTS" "$CACHE_APPS" "$CACHE_CHANGES" "$CACHE_ALL" "$CACHE_ACTIONS"
    if [ "$QUIET" -eq 0 ]; then
        echo "✅ 已使审计缓存失效"
    fi
}

refresh_cache() {
    mkdir -p "$CACHE_DIR" || return 1
    defaults_temp="$(mktemp "$CACHE_DIR/.defaults.XXXXXX")" || return 1
    apps_temp="$(mktemp "$CACHE_DIR/.apps.XXXXXX")" || {
        rm -f "$defaults_temp"
        return 1
    }
    changes_temp="$(mktemp "$CACHE_DIR/.changes.XXXXXX")" || {
        rm -f "$defaults_temp" "$apps_temp"
        return 1
    }
    all_temp="$(mktemp "$CACHE_DIR/.all.XXXXXX")" || {
        rm -f "$defaults_temp" "$apps_temp" "$changes_temp"
        return 1
    }
    actions_temp="$(mktemp "$CACHE_DIR/.actions.XXXXXX")" || {
        rm -f "$defaults_temp" "$apps_temp" "$changes_temp" "$all_temp"
        return 1
    }
    aggregate_temp="$(mktemp "$CACHE_DIR/.aggregate.XXXXXX")" || {
        rm -f "$defaults_temp" "$apps_temp" "$changes_temp" "$all_temp" "$actions_temp"
        return 1
    }
    stamp_temp="$(mktemp "$CACHE_DIR/.date.XXXXXX")" || {
        rm -f "$defaults_temp" "$apps_temp" "$changes_temp" "$all_temp" "$actions_temp" "$aggregate_temp"
        return 1
    }

    echo "🔄 正在实时查询配置和软件状态，并更新今日缓存..."
    TABLE_AGGREGATE_FILE="$aggregate_temp"
    ACTIONS_FILE="$actions_temp"
    : >"$ACTIONS_FILE"
    if ! audit_defaults >"$defaults_temp" ||
        ! audit_apps >"$apps_temp" ||
        ! audit_changes >"$changes_temp" ||
        ! cp "$aggregate_temp" "$all_temp"; then
        TABLE_AGGREGATE_FILE=""
        ACTIONS_FILE=""
        rm -f "$defaults_temp" "$apps_temp" "$changes_temp" "$all_temp" "$actions_temp" "$aggregate_temp" "$stamp_temp"
        echo "❌ 实时审计失败，未替换现有缓存" >&2
        return 1
    fi
    TABLE_AGGREGATE_FILE=""
    ACTIONS_FILE=""
    rm -f "$aggregate_temp"

    generated_at="$(date '+%Y-%m-%d %H:%M:%S %z')"
    printf '%s\t%s\t%s\n' "$(audit_date)" "$generated_at" "$CACHE_VERSION" >"$stamp_temp"
    chmod 600 "$defaults_temp" "$apps_temp" "$changes_temp" "$all_temp" "$actions_temp" "$stamp_temp"
    # 时间戳最后写入；中途失败时下次查询会重新生成整组缓存，不读取混合结果。
    rm -f "$CACHE_STAMP"
    mv -f "$defaults_temp" "$CACHE_DEFAULTS"
    mv -f "$apps_temp" "$CACHE_APPS"
    mv -f "$changes_temp" "$CACHE_CHANGES"
    mv -f "$all_temp" "$CACHE_ALL"
    mv -f "$actions_temp" "$CACHE_ACTIONS"
    mv -f "$stamp_temp" "$CACHE_STAMP"
}

ensure_cache() {
    if [ "$REFRESH" -eq 1 ] || ! cache_is_fresh; then
        if [ -z "$CATALOG" ]; then
            build_catalog || return 1
        fi
        refresh_cache || return 1
        CACHE_WAS_REFRESHED=1
    else
        CACHE_WAS_REFRESHED=0
    fi
}

terminal_width() {
    width="${COLUMNS:-}"
    case "$width" in
        ''|*[!0-9]*) width="" ;;
    esac
    if [ -z "$width" ] && command -v tput >/dev/null 2>&1; then
        width="$(tput cols 2>/dev/null || true)"
    fi
    case "$width" in
        ''|*[!0-9]*) width=100 ;;
    esac
    if [ "$width" -lt 72 ]; then
        width=72
    fi
    printf '%s' "$width"
}

horizontal_rule() {
    rule_character="$1"
    rule_width="$(terminal_width)"
    awk -v char="$rule_character" -v width="$rule_width" '
        BEGIN {
            for (i = 0; i < width; i++) printf "%s", char
            printf "\n"
        }
    '
}

view_label() {
    case "$1" in
        all) printf '全部' ;;
        defaults) printf '系统配置与 Dock' ;;
        apps) printf '应用与命令行工具' ;;
        changes) printf '初始化后的配置变化' ;;
    esac
}

display_command() {
    printf 'sh scripts/audit.sh'
    if [ "$COMMAND" != "all" ]; then
        printf ' %s' "$COMMAND"
    fi
    if [ "$REFRESH" -eq 1 ]; then
        printf ' --refresh'
    fi
}

print_run_header() {
    view="$1"
    generated_at="$(awk -F'\t' 'NR == 1 { print $2 }' "$CACHE_STAMP")"
    if [ "$CACHE_WAS_REFRESHED" -eq 1 ]; then
        source_label="实时查询，已更新今日缓存"
    else
        source_label="今日缓存"
    fi
    echo
    horizontal_rule '='
    echo "mac-as-code 审计开始"
    echo "命令：$(display_command)"
    echo "视图：$(view_label "$view")"
    echo "数据来源：${source_label}"
    echo "审计时间：${generated_at}"
    horizontal_rule '-'
}

print_run_footer() {
    view="$1"
    horizontal_rule '-'
    echo "mac-as-code 审计结束 · $(view_label "$view")"
    horizontal_rule '='
    echo
}

print_cached_result() {
    view="$1"
    print_run_header "$view"
    case "$view" in
        all)
            cat "$CACHE_ALL"
            ;;
        defaults) cat "$CACHE_DEFAULTS" ;;
        apps) cat "$CACHE_APPS" ;;
        changes) cat "$CACHE_CHANGES" ;;
    esac
    print_run_footer "$view"
}

audit_defaults() {
    mismatch_count=0
    matched_count=0
    unsupported_count=0
    current=""
    defaults_table="$(mktemp -t mac-as-code-defaults-table.XXXXXX)" || return 1

    echo "==> 系统配置与 Dock"
    echo
    table_start "$defaults_table" "分类" "项目" "当前值" "仓库期望" "修复命令"
    while IFS="$(printf '\t')" read -r kind group _item_id label domain key value_type expected || [ -n "${kind:-}" ]; do
        case "${kind:-}" in
            SETTING)
                case "$group" in
                    defaults) group_label="系统配置" ;;
                    dock) group_label="Dock" ;;
                esac
                expected="$(normalize_expected "$value_type" "$expected")"
                if current="$(read_current_default "$domain" "$key")"; then
                    :
                else
                    current="__MAC_AS_CODE_MISSING__"
                fi
                if [ "$current" = "$expected" ]; then
                    matched_count=$((matched_count + 1))
                    continue
                fi
                mismatch_count=$((mismatch_count + 1))
                command_text="defaults write ${domain} ${key} -${value_type} $(print_shell_quoted "$expected")"
                table_row "$defaults_table" \
                    "$group_label" \
                    "⚠ 与仓库不同 · $label" \
                    "$(print_value "$current")" \
                    "$(print_value "$expected")" \
                    "$command_text"
                ;;
            UNSUPPORTED)
                unsupported_count=$((unsupported_count + 1))
                case "$group" in
                    defaults) group_label="系统配置" ;;
                    dock) group_label="Dock" ;;
                esac
                table_row "$defaults_table" \
                    "$group_label" \
                    "? 无法自动比较 · $label" \
                    "—" \
                    "—" \
                    "$domain"
                ;;
        esac
    done <"$CATALOG"

    if [ "$mismatch_count" -eq 0 ]; then
        table_row "$defaults_table" "系统配置 / Dock" "✓ 与仓库一致" "—" "—" "无需操作"
    fi
    table_render "$defaults_table" yes
    audit_note "统计：与仓库一致 ${matched_count}，⚠ 与仓库不同 ${mismatch_count}，无法自动比较 ${unsupported_count}"
}

desired_contains() {
    desired_file="$1"
    desired_type="$2"
    desired_name="$3"
    awk -F'|' -v t="$desired_type" -v n="$desired_name" '
        $1 == t && $2 == n { found = 1 }
        END { exit found ? 0 : 1 }
    ' "$desired_file"
}

record_action() {
    [ -n "$ACTIONS_FILE" ] || return 0
    action_type="$1"
    package_type="$2"
    name="$3"
    metadata="${4:-}"
    printf '%s\t%s\t%s\t%s\n' \
        "$(table_cell "$action_type")" \
        "$(table_cell "$package_type")" \
        "$(table_cell "$name")" \
        "$(table_cell "$metadata")" >>"$ACTIONS_FILE"
}

cask_application_exists() {
    cask_name="$1"
    artifact_names="$(
        brew info --cask "$cask_name" 2>/dev/null |
            awk '
                /^==> Artifacts$/ { in_artifacts = 1; next }
                /^==>/ { in_artifacts = 0 }
                in_artifacts && /\.app \(App\)$/ {
                    line = $0
                    sub(/ \(App\)$/, "", line)
                    print line
                }
            '
    )"
    while IFS= read -r artifact_name || [ -n "${artifact_name:-}" ]; do
        [ -n "${artifact_name:-}" ] || continue
        [ -d "$APPLICATIONS_DIR/$artifact_name" ] && return 0
    done <<EOF
$artifact_names
EOF
    return 1
}

build_cask_artifact_catalog() {
    output_file="$1"
    if [ -n "${MAC_AS_CODE_CASK_ARTIFACTS_FILE:-}" ]; then
        if [ ! -f "$MAC_AS_CODE_CASK_ARTIFACTS_FILE" ]; then
            echo "❌ 测试用 cask artifact 清单不存在：$MAC_AS_CODE_CASK_ARTIFACTS_FILE" >&2
            return 1
        fi
        cat "$MAC_AS_CODE_CASK_ARTIFACTS_FILE" >"$output_file"
        return 0
    fi
    if ! command -v curl >/dev/null 2>&1; then
        echo "❌ 缺少 curl，无法读取 Homebrew cask 清单" >&2
        return 1
    fi
    catalog_json="$(mktemp -t mac-as-code-cask-catalog.XXXXXX)" || return 1
    if ! curl -fsSL https://formulae.brew.sh/api/cask.json -o "$catalog_json"; then
        rm -f "$catalog_json"
        echo "❌ 无法读取 Homebrew cask 清单，未完成手工安装应用匹配" >&2
        return 1
    fi
    if ! brew ruby -rjson -e '
        JSON.parse(File.read(ARGV.fetch(0))).each do |cask|
          token = cask.fetch("token", "").to_s.tr("\t\r\n", "   ")
          cask.fetch("artifacts", []).each do |artifact|
            next unless artifact.is_a?(Hash) && artifact.key?("app")
            Array(artifact["app"]).each do |app|
              name = app.to_s.split("/").last.to_s.tr("\t\r\n", "   ")
              puts "#{token}\t#{name}" unless token.empty? || name.empty?
            end
          end
        end
    ' "$catalog_json" >"$output_file"; then
        rm -f "$catalog_json"
        echo "❌ 无法解析 Homebrew cask 清单" >&2
        return 1
    fi
    rm -f "$catalog_json"
}

audit_manual_cask_apps() {
    desired_file="$1"
    installed_casks_file="$2"
    apps_table_file="$3"
    artifact_catalog="$(mktemp -t mac-as-code-cask-artifacts.XXXXXX)" || return 1
    local_apps="$(mktemp -t mac-as-code-local-apps.XXXXXX)" || {
        rm -f "$artifact_catalog"
        return 1
    }
    github_apps="$(mktemp -t mac-as-code-github-apps.XXXXXX)" || {
        rm -f "$artifact_catalog" "$local_apps"
        return 1
    }
    seen_casks="$(mktemp -t mac-as-code-seen-casks.XXXXXX)" || {
        rm -f "$artifact_catalog" "$local_apps" "$github_apps"
        return 1
    }
    if ! build_cask_artifact_catalog "$artifact_catalog"; then
        rm -f "$artifact_catalog" "$local_apps" "$github_apps" "$seen_casks"
        return 1
    fi
    find "$APPLICATIONS_DIR" -maxdepth 1 -type d -name '*.app' -print 2>/dev/null | sort >"$local_apps"
    parse_github_release_apps "$GITHUB_APPS_CONFIG" |
        awk -F'|' '{ print tolower($4 ".app") }' >"$github_apps"
    : >"$seen_casks"
    MANUAL_CASK_COUNT=0
    AMBIGUOUS_CASK_COUNT=0

    while IFS= read -r app_path || [ -n "${app_path:-}" ]; do
        [ -n "${app_path:-}" ] || continue
        app_filename="${app_path##*/}"
        app_lower="$(printf '%s' "$app_filename" | tr '[:upper:]' '[:lower:]')"
        [ -f "$app_path/Contents/_MASReceipt/receipt" ] && continue
        grep -Fqx "$app_lower" "$github_apps" && continue

        candidates="$(awk -F'\t' -v wanted="$app_lower" 'tolower($2) == wanted { print $1 }' "$artifact_catalog" | sort -u)"
        [ -n "$candidates" ] || continue
        represented=0
        while IFS= read -r candidate || [ -n "${candidate:-}" ]; do
            [ -n "${candidate:-}" ] || continue
            if desired_contains "$desired_file" cask "$candidate" || grep -Fqx "$candidate" "$installed_casks_file"; then
                represented=1
                break
            fi
        done <<EOF
$candidates
EOF
        [ "$represented" -eq 0 ] || continue

        candidate_count="$(printf '%s\n' "$candidates" | awk 'NF { count++ } END { print count + 0 }')"
        selected_cask=""
        if [ "$candidate_count" -eq 1 ]; then
            selected_cask="$candidates"
        else
            normalized_name="$(printf '%s' "${app_filename%.app}" | tr '[:upper:] _' '[:lower:]--' | tr -cd 'a-z0-9@+_.-')"
            selected_cask="$(printf '%s\n' "$candidates" | awk -v wanted="$normalized_name" '$0 == wanted { print; exit }')"
        fi
        if [ -z "$selected_cask" ]; then
            AMBIGUOUS_CASK_COUNT=$((AMBIGUOUS_CASK_COUNT + 1))
            candidate_text="$(printf '%s' "$candidates" | tr '\n' ', ' | sed 's/, $//')"
            table_row "$apps_table_file" "? 无法自动对应" "cask" "$app_filename" "已安装" "未登记；匹配到多个 cask：$candidate_text"
            continue
        fi
        grep -Fqx "$selected_cask" "$seen_casks" && continue
        printf '%s\n' "$selected_cask" >>"$seen_casks"
        MANUAL_CASK_COUNT=$((MANUAL_CASK_COUNT + 1))
        table_row "$apps_table_file" "⚠ 与仓库不同" "cask" "$selected_cask" \
            "已安装 ${app_filename}（非 Homebrew）" "未登记；可追加"
        record_action add-manual-cask cask "$selected_cask" "$app_filename"
    done <"$local_apps"

    rm -f "$artifact_catalog" "$local_apps" "$github_apps" "$seen_casks"
}

mas_application_exists() {
    app_id="$1"
    command -v mdfind >/dev/null 2>&1 || return 1
    mdfind "kMDItemAppStoreAdamID == '${app_id}'" 2>/dev/null |
        awk '/\.app(\/|$)/ { found = 1 } END { exit found ? 0 : 1 }'
}

audit_apps() {
    if [ ! -f "$BREWFILE" ] || [ ! -f "$GITHUB_APPS_CONFIG" ]; then
        echo "❌ 应用清单不存在" >&2
        return 1
    fi
    desired="$(mktemp -t mac-as-code-apps.XXXXXX)" || return 1
    installed_mas="$(mktemp -t mac-as-code-mas.XXXXXX)" || {
        rm -f "$desired"
        return 1
    }
    installed_casks="$(mktemp -t mac-as-code-installed-casks.XXXXXX)" || {
        rm -f "$desired" "$installed_mas"
        return 1
    }
    parse_brewfile "$BREWFILE" >"$desired"
    : >"$installed_mas"
    : >"$installed_casks"
    missing=0
    present=0
    extra=0
    unavailable=0
    unmanaged_present=0
    apps_table="$(mktemp -t mac-as-code-apps-table.XXXXXX)" || {
        rm -f "$desired" "$installed_mas" "$installed_casks"
        return 1
    }

    echo
    echo "==> 应用与命令行工具清单"
    echo
    table_start "$apps_table" "状态" "来源" "项目" "本机" "仓库清单"
    if command -v mas >/dev/null 2>&1; then
        mas list >"$installed_mas" 2>/dev/null || :
    fi
    if command -v brew >/dev/null 2>&1; then
        brew list --cask >"$installed_casks" 2>/dev/null || :
    fi

    while IFS='|' read -r package_type name app_id || [ -n "${package_type:-}" ]; do
        [ -n "${package_type:-}" ] || continue
        installed=0
        case "$package_type" in
            brew)
                if command -v brew >/dev/null 2>&1 && brew list --formula "$name" >/dev/null 2>&1; then
                    installed=1
                elif ! command -v brew >/dev/null 2>&1; then
                    unavailable=1
                fi
                ;;
            cask)
                if command -v brew >/dev/null 2>&1 && brew list --cask "$name" >/dev/null 2>&1; then
                    installed=1
                elif command -v brew >/dev/null 2>&1 && cask_application_exists "$name"; then
                    installed=1
                    unmanaged_present=$((unmanaged_present + 1))
                    table_row "$apps_table" "⚠ 安装方式不同" "cask" "$name" "应用存在（非 Homebrew）" "已登记"
                elif ! command -v brew >/dev/null 2>&1; then
                    unavailable=1
                fi
                ;;
            mas)
                if awk -v wanted="$app_id" '$1 == wanted { found = 1 } END { exit found ? 0 : 1 }' "$installed_mas"; then
                    installed=1
                elif [ ! -s "$installed_mas" ] && mas_application_exists "$app_id"; then
                    installed=1
                elif ! command -v mas >/dev/null 2>&1; then
                    unavailable=1
                fi
                ;;
        esac
        if [ "$installed" -eq 1 ]; then
            present=$((present + 1))
        else
            missing=$((missing + 1))
            table_row "$apps_table" "⚠ 与仓库不同" "$package_type" "$name" "未检测到" "已登记"
        fi
    done <"$desired"

    if command -v brew >/dev/null 2>&1; then
        formula_extra="$(mktemp -t mac-as-code-formula-extra.XXXXXX)"
        cask_extra="$(mktemp -t mac-as-code-cask-extra.XXXXXX)"
        brew leaves 2>/dev/null | while IFS= read -r name; do
            [ -n "$name" ] || continue
            if ! desired_contains "$desired" brew "$name"; then
                printf 'brew|%s\n' "$name"
            fi
        done >"$formula_extra"
        while IFS= read -r name; do
            [ -n "$name" ] || continue
            if ! desired_contains "$desired" cask "$name"; then
                printf 'cask|%s\n' "$name"
            fi
        done <"$installed_casks" >"$cask_extra"
        for extra_file in "$formula_extra" "$cask_extra"; do
            while IFS='|' read -r package_type name || [ -n "${package_type:-}" ]; do
                [ -n "${package_type:-}" ] || continue
                extra=$((extra + 1))
                table_row "$apps_table" "⚠ 与仓库不同" "$package_type" "$name" "已安装" "未登记；可追加"
                record_action add-brewfile "$package_type" "$name"
            done <"$extra_file"
            rm -f "$extra_file"
        done
    else
        table_row "$apps_table" "? 无法比较" "brew / cask" "Homebrew" "未安装" "无法核对额外项"
    fi

    if [ -s "$installed_mas" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            app_id="$(printf '%s\n' "$line" | awk '{ print $1 }')"
            name="$(
                printf '%s\n' "$line" |
                    sed 's/^[[:space:]]*[0-9][0-9]*[[:space:]]*//; s/[[:space:]]*([^()]*)[[:space:]]*$//'
            )"
            if ! awk -F'|' -v wanted="$app_id" '$1 == "mas" && $3 == wanted { found = 1 } END { exit found ? 0 : 1 }' "$desired"; then
                extra=$((extra + 1))
                table_row "$apps_table" "⚠ 与仓库不同" "mas" "$name" "已安装" "未登记；可追加"
                record_action add-brewfile mas "$name" "$app_id"
            fi
        done <"$installed_mas"
    elif ! command -v mas >/dev/null 2>&1; then
        table_row "$apps_table" "? 无法比较" "mas" "App Store 应用" "mas 未安装" "无法可靠核对额外项"
    fi

    manual_cask_count=0
    ambiguous_cask_count=0
    if command -v brew >/dev/null 2>&1; then
        if ! audit_manual_cask_apps "$desired" "$installed_casks" "$apps_table"; then
            rm -f "$desired" "$installed_mas" "$installed_casks" "$apps_table"
            return 1
        fi
        manual_cask_count="$MANUAL_CASK_COUNT"
        ambiguous_cask_count="$AMBIGUOUS_CASK_COUNT"
        extra=$((extra + manual_cask_count))
    fi

    while IFS='|' read -r _app_id label _repository app_name _app_path || [ -n "${label:-}" ]; do
        [ -n "${label:-}" ] || continue
        if [ -d "$APPLICATIONS_DIR/${app_name}.app" ]; then
            present=$((present + 1))
        else
            missing=$((missing + 1))
            table_row "$apps_table" "⚠ 与仓库不同" "GitHub" "$label" "未检测到" "已登记"
        fi
    done <<EOF
$(parse_github_release_apps "$GITHUB_APPS_CONFIG")
EOF

    if [ "$missing" -eq 0 ] && [ "$extra" -eq 0 ]; then
        table_row "$apps_table" "✓ 与仓库一致" "—" "全部已登记软件" "与清单一致" "无需操作"
    fi
    table_render "$apps_table" yes
    audit_note "统计：已登记且检测到 ${present}（非 Homebrew 管理 ${unmanaged_present}）；⚠ 清单有但本机缺失 ${missing}，⚠ 本机有但未登记 ${extra}，cask 匹配待确认 ${ambiguous_cask_count}"
    if [ "$unavailable" -eq 1 ]; then
        audit_note "说明：缺少相应包管理器的条目按「未检测到」显示。"
    fi
    audit_note "范围：比较 Homebrew 顶层 formula、cask、mas，并匹配 /Applications 中可由 cask 管理的应用。"

    rm -f "$desired" "$installed_mas" "$installed_casks"
}

snapshot_defaults() {
    snapshot_temp="$(mktemp -t mac-as-code-baseline.XXXXXX)" || return 1
    mkdir -p "$STATE_DIR" || {
        rm -f "$snapshot_temp"
        return 1
    }
    printf '# captured=%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" >"$snapshot_temp"
    while IFS="$(printf '\t')" read -r kind group _item_id label domain key value_type expected || [ -n "${kind:-}" ]; do
        [ "${kind:-}" = "SETTING" ] || continue
        if current="$(read_current_default "$domain" "$key")"; then
            :
        else
            current="__MAC_AS_CODE_MISSING__"
        fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$group" "$label" "$domain" "$key" "$value_type" "$current" >>"$snapshot_temp"
    done <"$CATALOG"
    chmod 600 "$snapshot_temp"
    /usr/bin/ditto "$snapshot_temp" "$BASELINE_FILE"
    rm -f "$snapshot_temp"
    if [ "$QUIET" -eq 0 ]; then
        echo "✅ 已记录初始化配置基线：$BASELINE_FILE"
    fi
}

audit_changes() {
    changed=0
    unchanged=0
    if [ ! -f "$BASELINE_FILE" ]; then
        echo
        echo "==> 初始化后的配置变化"
        echo
        changes_table="$(mktemp -t mac-as-code-changes-table.XXXXXX)" || return 1
        table_start "$changes_table" "项目" "基线状态" "下一步"
        table_row "$changes_table" \
            "初始化基线" "尚未建立" \
            "下次应用配置后自动建立；也可运行 sh scripts/audit.sh snapshot"
        table_render "$changes_table" yes
        return 0
    fi

    echo
    echo "==> 初始化后的配置变化"
    echo
    echo "基线：$(sed -n 's/^# captured=//p' "$BASELINE_FILE" | head -n 1)"
    echo
    changes_table="$(mktemp -t mac-as-code-changes-table.XXXXXX)" || return 1
    table_start "$changes_table" "分类" "项目" "初始化时" "现在"
    while IFS="$(printf '\t')" read -r group label domain key value_type before || [ -n "${group:-}" ]; do
        case "${group:-}" in
            ""|\#*) continue ;;
        esac
        if current="$(read_current_default "$domain" "$key")"; then
            :
        else
            current="__MAC_AS_CODE_MISSING__"
        fi
        if [ "$current" = "$before" ]; then
            unchanged=$((unchanged + 1))
            continue
        fi
        changed=$((changed + 1))
        case "$group" in
            defaults) group_label="系统配置" ;;
            dock) group_label="Dock" ;;
            *) group_label="$group" ;;
        esac
        table_row "$changes_table" \
            "$group_label" \
            "△ 初始化后变化 · $label" \
            "$(print_value "$before")" \
            "$(print_value "$current")"
    done <"$BASELINE_FILE"
    if [ "$changed" -eq 0 ]; then
        table_row "$changes_table" "系统配置 / Dock" "✓ 初始化后无变化" "—" "—"
    fi
    table_render "$changes_table" yes
    audit_note "统计：初始化后变化 ${changed}，未变化 ${unchanged}"
    audit_note "范围：只追踪可解析的 defaults write 标量命令，不推断其他偏好。"
}

action_label() {
    case "$1" in
        add-brewfile|add-manual-cask) printf '加入 Brewfile' ;;
    esac
}

action_reason() {
    action_type="$1"
    case "$action_type" in
        add-brewfile)
            printf '本机已安装，但 Brewfile 没有'
            ;;
        add-manual-cask)
            printf '本机应用存在，但不是由 Homebrew 安装，Brewfile 没有'
            ;;
    esac
}

build_append_plan() {
    plan="$1"
    : >"$plan"
    action_number=0
    while IFS="$(printf '\t')" read -r action_type package_type name metadata || [ -n "${action_type:-}" ]; do
        [ -n "${action_type:-}" ] || continue
        action_number=$((action_number + 1))
        printf 'OFF|audit|%s|[%s] %s|%s\n' \
            "$action_number" \
            "$package_type" \
            "$name" \
            "$(action_reason "$action_type")" >>"$plan"
    done <"$CACHE_ACTIONS"
}

brewfile_entry_exists() {
    package_type="$1"
    name="$2"
    app_id="${3:-}"
    desired_temp="$(mktemp -t mac-as-code-desired.XXXXXX)" || return 1
    parse_brewfile "$BREWFILE" >"$desired_temp"
    if [ "$package_type" = "mas" ]; then
        awk -F'|' -v wanted="$app_id" '$1 == "mas" && $3 == wanted { found = 1 } END { exit found ? 0 : 1 }' "$desired_temp"
    else
        desired_contains "$desired_temp" "$package_type" "$name"
    fi
    found_status=$?
    rm -f "$desired_temp"
    return "$found_status"
}

append_brewfile_entry() {
    package_type="$1"
    name="$2"
    app_id="${3:-}"
    case "$package_type" in
        brew|cask)
            case "$name" in
                ''|*[!A-Za-z0-9@+_.:/-]*)
                    echo "❌ 软件包名称包含 Brewfile 不支持的字符：$name" >&2
                    return 1
                    ;;
            esac
            entry="${package_type} \"${name}\""
            ;;
        mas)
            case "$app_id" in
                ''|*[!0-9]*)
                    echo "❌ App Store ID 无效：$app_id" >&2
                    return 1
                    ;;
            esac
            escaped_name="$(printf '%s' "$name" | sed 's/\\/\\\\/g; s/"/\\"/g')"
            entry="mas \"${escaped_name}\", id: ${app_id}"
            ;;
        *)
            echo "❌ 不支持写入 Brewfile 的来源：$package_type" >&2
            return 1
            ;;
    esac

    edited="$(mktemp -t mac-as-code-Brewfile.XXXXXX)" || return 1
    backup="$(mktemp -t mac-as-code-Brewfile-backup.XXXXXX)" || {
        rm -f "$edited"
        return 1
    }
    /usr/bin/ditto "$BREWFILE" "$backup"
    if grep -Fq '# audit-added:end' "$BREWFILE"; then
        awk -v entry="$entry" '
            /^# audit-added:end$/ && !added { print entry; added = 1 }
            { print }
        ' "$BREWFILE" >"$edited"
    else
        cat "$BREWFILE" >"$edited"
        {
            echo
            echo '# audit-added:start'
            echo '# 通过 audit.sh append 确认加入；可按用途移动到上方分类。'
            printf '%s\n' "$entry"
            echo '# audit-added:end'
        } >>"$edited"
    fi
    /usr/bin/ditto "$edited" "$BREWFILE"
    if ! sh "$SCRIPTS_DIR/check_format.sh" "$BREWFILE"; then
        /usr/bin/ditto "$backup" "$BREWFILE"
        rm -f "$edited" "$backup"
        echo "❌ Brewfile 校验失败，已恢复原文件" >&2
        return 1
    fi
    rm -f "$edited" "$backup"
}

execute_append_action() {
    action_type="$1"
    package_type="$2"
    name="$3"
    metadata="${4:-}"
    case "$action_type" in
        add-brewfile)
            if brewfile_entry_exists "$package_type" "$name" "$metadata"; then
                echo "ℹ️  $name 已在 Brewfile 中，无需重复加入。"
                return 0
            fi
            case "$package_type" in
                brew)
                    if ! command -v brew >/dev/null 2>&1 || ! brew list --formula "$name" >/dev/null 2>&1; then
                        echo "❌ $name 已不是本机安装的 Homebrew formula，请重新审计" >&2
                        return 1
                    fi
                    ;;
                cask)
                    if ! command -v brew >/dev/null 2>&1 || ! brew list --cask "$name" >/dev/null 2>&1; then
                        echo "❌ $name 已不是本机安装的 Homebrew cask，请重新审计" >&2
                        return 1
                    fi
                    ;;
                mas)
                    if ! command -v mas >/dev/null 2>&1 ||
                        ! mas list 2>/dev/null | awk -v wanted="$metadata" '$1 == wanted { found = 1 } END { exit found ? 0 : 1 }'; then
                        echo "❌ $name 已不是本机可检测的 App Store 应用，请重新审计" >&2
                        return 1
                    fi
                    ;;
            esac
            append_brewfile_entry "$package_type" "$name" "$metadata"
            ;;
        add-manual-cask)
            if ! command -v brew >/dev/null 2>&1 || ! brew info --cask "$name" >/dev/null 2>&1; then
                echo "❌ Homebrew 已无法找到 cask：$name，请重新审计" >&2
                return 1
            fi
            if [ ! -d "$APPLICATIONS_DIR/$metadata" ]; then
                echo "❌ 本机已找不到 $metadata，请重新审计" >&2
                return 1
            fi
            if brewfile_entry_exists cask "$name"; then
                echo "ℹ️  $name 已在 Brewfile 中，无需重复加入。"
                return 0
            fi
            append_brewfile_entry cask "$name"
            ;;
        *)
            echo "❌ 未知追加动作：$action_type" >&2
            return 1
            ;;
    esac
}

append_selected_items() {
    print_cached_result all
    if [ ! -t 0 ]; then
        echo
        echo "ℹ️  当前不是交互终端；只完成审计，没有进入应用差异多选。"
        return 0
    fi
    selection_plan="$(mktemp -t mac-as-code-audit-selection.XXXXXX)" || return 1
    build_append_plan "$selection_plan" || {
        rm -f "$selection_plan"
        return 1
    }
    checkbox_select_step \
        "选择要处理的应用差异" \
        "audit" \
        "$selection_plan" \
        "（默认全部不选；只处理你用空格勾选的项目）"
    selection_status=$?
    if [ "$selection_status" -eq 2 ]; then
        rm -f "$selection_plan"
        return 0
    fi
    if [ "$selection_status" -ne 0 ]; then
        rm -f "$selection_plan"
        return "$selection_status"
    fi

    selected_count="$(awk -F'|' '$1 == "ON" { count++ } END { print count + 0 }' "$selection_plan")"
    if [ "$selected_count" -eq 0 ]; then
        rm -f "$selection_plan"
        echo "ℹ️  没有选中任何项目，电脑和 Brewfile 均未修改。"
        return 0
    fi

    result_table="$(mktemp -t mac-as-code-audit-results.XXXXXX)" || {
        rm -f "$selection_plan"
        return 1
    }
    table_start "$result_table" "结果" "来源" "项目" "处理"
    success_count=0
    failure_count=0
    while IFS='|' read -r state _selection_type action_number description || [ -n "${state:-}" ]; do
        [ "${state:-}" = "ON" ] || continue
        selected="$(awk -v wanted="$action_number" 'NR == wanted { print; found = 1 } END { exit found ? 0 : 1 }' "$CACHE_ACTIONS")" || {
            failure_count=$((failure_count + 1))
            table_row "$result_table" "失败" "未知" "$description" "缓存项目不存在"
            continue
        }
        IFS="$(printf '\t')" read -r action_type package_type name metadata <<EOF
$selected
EOF
        echo
        echo "==> 处理：$name（$(action_label "$action_type")）"
        if execute_append_action "$action_type" "$package_type" "$name" "$metadata"; then
            success_count=$((success_count + 1))
            table_row "$result_table" "成功" "$package_type" "$name" "$(action_label "$action_type")"
        else
            failure_count=$((failure_count + 1))
            table_row "$result_table" "失败" "$package_type" "$name" "$(action_label "$action_type")"
        fi
    done <"$selection_plan"
    rm -f "$selection_plan"

    if [ "$success_count" -gt 0 ]; then
        saved_quiet="$QUIET"
        QUIET=1
        invalidate_cache
        QUIET="$saved_quiet"
    fi
    echo
    echo "处理结果："
    table_render "$result_table"
    echo "已选择 ${selected_count} 项：成功 ${success_count}，失败 ${failure_count}。"
    if [ "$success_count" -gt 0 ]; then
        echo "审计缓存已失效，下次查询会实时验证结果。"
    fi
    [ "$failure_count" -eq 0 ]
}

review_and_apply() {
    print_cached_result all
    if [ ! -t 0 ]; then
        echo
        echo "ℹ️  当前不是交互终端；只完成审计，没有进入应用选择。"
        return 0
    fi
    echo
    printf '是否进入现有多选界面，决定要应用的设置和软件？[y/N] '
    read -r answer
    case "$answer" in
        y|Y|yes|YES)
            QUIET=1
            invalidate_cache
            exec sh "$ROOT_DIR/init.sh"
            ;;
        *)
            echo "ℹ️  保持当前电脑不变"
            ;;
    esac
}

COMMAND="all"
COMMAND_SET=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        -r|--refresh)
            REFRESH=1
            ;;
        --quiet)
            QUIET=1
            ;;
        -h|--help|help)
            usage
            exit 0
            ;;
        defaults|apps|changes|append|review|snapshot|invalidate)
            if [ "$COMMAND_SET" -eq 1 ]; then
                echo "❌ 只能指定一个审计命令" >&2
                usage
                exit 1
            fi
            COMMAND="$1"
            COMMAND_SET=1
            ;;
        *)
            echo "❌ 未知参数或命令：$1" >&2
            usage
            exit 1
            ;;
    esac
    shift
done

case "$COMMAND" in
    snapshot|invalidate)
        if [ "$REFRESH" -eq 1 ]; then
            echo "❌ --refresh 只用于审计查询" >&2
            exit 1
        fi
        ;;
    *)
        if [ "$QUIET" -eq 1 ]; then
            echo "❌ --quiet 只用于内部 snapshot / invalidate 调用" >&2
            exit 1
        fi
        ;;
esac

trap cleanup EXIT HUP INT TERM

case "$COMMAND" in
    all|defaults|apps|changes)
        ensure_cache || exit 1
        print_cached_result "$COMMAND"
        ;;
    review)
        ensure_cache || exit 1
        review_and_apply
        ;;
    append)
        ensure_cache || exit 1
        append_selected_items
        ;;
    snapshot)
        build_catalog || exit 1
        snapshot_defaults || exit 1
        saved_quiet="$QUIET"
        QUIET=1
        invalidate_cache
        QUIET="$saved_quiet"
        ;;
    invalidate)
        invalidate_cache
        ;;
esac
