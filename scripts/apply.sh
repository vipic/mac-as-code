#!/bin/sh
set -u

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_DIR="$ROOT_DIR/config"
SCRIPTS_DIR="$ROOT_DIR/scripts"
# shellcheck source=common.sh
. "$SCRIPTS_DIR/common.sh"

if [ "$#" -ne 0 ] || [ ! -r "${MAC_AS_CODE_INPUT_PLAN:-}" ]; then
    echo "内部执行器，请运行 sh mac.sh 并从菜单确认操作。" >&2
    exit 1
fi

PLAN_FILE="$(mktemp -t mac-as-code-plan.XXXXXX)"
export MAC_AS_CODE_PLAN="$PLAN_FILE"
MAC_AS_CODE_RESULTS="$(mktemp -t mac-as-code.XXXXXX)"
export MAC_AS_CODE_RESULTS
export MAC_AS_CODE_LOG_DIR="$ROOT_DIR/logs"
: >"$MAC_AS_CODE_RESULTS"
trap 'rm -f "$MAC_AS_CODE_RESULTS" "$PLAN_FILE"' EXIT

cat "$MAC_AS_CODE_INPUT_PLAN" >"$PLAN_FILE" || exit 1

if [ "$(uname -s)" != Darwin ]; then
    echo "此任务只能在 macOS 上执行。" >&2
    exit 1
fi
retry_dir="${MAC_AS_CODE_STATE_DIR:-$HOME/.local/state/mac-as-code}"
mkdir -p "$retry_dir" || exit 1
chmod 700 "$retry_dir" || exit 1
# 中断或前置条件失败时仍能重试，执行完成后再缩减为失败项。
retry_temp="$(mktemp "$retry_dir/retry.XXXXXX")" || exit 1
awk -F '|' '$1 == "ON"' "$PLAN_FILE" >"$retry_temp"
mv "$retry_temp" "$retry_dir/retry.plan" || exit 1
if awk -F '|' '$1 == "ON" && $2 != "defaults" && $2 != "dock" { found=1 } END { exit found ? 0 : 1 }' "$PLAN_FILE"; then
    if ! xcode-select -p >/dev/null 2>&1; then
        echo "安装软件需要 Xcode Command Line Tools，正在打开系统安装器…"
        xcode-select --install
        echo "安装完成后重新运行 sh mac.sh，已满足项会自动跳过。"
        exit 1
    fi
    sh "$SCRIPTS_DIR/doctor.sh" --pre || exit 1
fi

# App Store：多选已决定装哪些；这里只处理登录，不再问「继续/跳过全部」
confirm_mas_upfront() {
    mas_on=0
    apple_id=""

    while IFS='|' read -r state type name id; do
        [ "$state" = "ON" ] && [ "$type" = "mas" ] || continue
        if command -v mas >/dev/null 2>&1 && mas list 2>/dev/null | awk -v wanted="$id" '$1 == wanted { found = 1 } END { exit found ? 0 : 1 }'; then
            continue
        fi
        mas_on=$((mas_on + 1))
    done <"$PLAN_FILE"

    if [ "$mas_on" -eq 0 ]; then
        export MAC_AS_CODE_SKIP_MAS=1
        return 0
    fi

    echo
    echo "======== App Store（将按多选安装 ${mas_on} 个）========"
    while IFS='|' read -r state type name id; do
        [ "$state" = "ON" ] && [ "$type" = "mas" ] || continue
        echo "  - ${name}"
    done <"$PLAN_FILE"

    if apple_id_signed_in; then
        apple_id="$(apple_id_account)"
        echo "✅ 已检测到 Apple ID：${apple_id}，稍后按清单安装"
        export MAC_AS_CODE_MAS_READY=1
        return 0
    fi

    if [ ! -t 0 ]; then
        echo "未检测到 Apple ID，请在交互终端登录后重试。" >&2
        return 1
    fi

    echo "⚠️  未检测到 Apple ID，打开 App Store，请登录后按 Enter 继续"
    open -a "App Store" 2>/dev/null || true

    while true; do
        ui_document "App Store 登录" "请在 App Store 完成登录，然后按 Enter 检查。" login
        input_status=$?
        case "$input_status" in
            1) return 2 ;;
            2|3) return "$input_status" ;;
        esac
        if apple_id_signed_in; then
            apple_id="$(apple_id_account)"
            echo "✅ 已检测到 Apple ID：${apple_id}"
            export MAC_AS_CODE_MAS_READY=1
            ui_execution "继续安装软件"
            return 0
        fi
        echo "仍未检测到登录，请登录后再按 Enter（或 Ctrl+C 中止）"
        open -a "App Store" 2>/dev/null || true
    done
}

confirm_mas_upfront || exit $?

STEP_FAIL_COUNT=0
STEP_INDEX=0
STEP_TOTAL="$(awk -F '|' '
    $1 == "ON" {
        if ($2 == "recipe" || $2 == "github-release") recipes++
        else if ($2 == "brew" || $2 == "cask" || $2 == "mas") groups["brew"]=1
        else groups[$2]=1
    }
    END { for (g in groups) n++; print n+recipes }
' "$PLAN_FILE")"

run_step() {
    name="$1"
    description="$2"
    script_path="$3"
    shift 3

    echo
    STEP_INDEX=$((STEP_INDEX + 1))
    echo "[$STEP_INDEX/$STEP_TOTAL] $description"
    if sh "$script_path" "$@"; then
        record_result "OK" "步骤:$name" "完成"
    else
        echo "⚠️  步骤失败：${name}（已记录，继续执行后续步骤）"
        record_result "FAIL" "步骤:$name" "脚本退出非零"
        STEP_FAIL_COUNT=$((STEP_FAIL_COUNT + 1))
    fi
}

maybe_run_type() {
    type_name="$1"
    step_name="$2"
    description="$3"
    script_path="$4"

    if ! plan_has_on "$PLAN_FILE" "$type_name"; then
        echo
        echo "⏭️  跳过：${description}（未选中任何项）"
        record_result "SKIP" "步骤:$step_name" "用户未选中"
        return 0
    fi
    run_step "$step_name" "$description" "$script_path"
}

maybe_run_brew() {
    brew_on="$(plan_count_on "$PLAN_FILE" "brew")"
    cask_on="$(plan_count_on "$PLAN_FILE" "cask")"
    mas_on="$(plan_count_on "$PLAN_FILE" "mas")"

    if [ "${brew_on:-0}" -eq 0 ] && [ "${cask_on:-0}" -eq 0 ] && [ "${mas_on:-0}" -eq 0 ]; then
        echo
        echo "⏭️  跳过：安装 Homebrew 及软件（未选中任何软件）"
        record_result "SKIP" "步骤:brew" "用户未选中任何软件"
        return 0
    fi

    run_step "brew" "🍺 安装 Homebrew 及软件..." "$SCRIPTS_DIR/brew.sh"
}

maybe_run_recipes() {
    state=""
    type=""
    name=""
    label=""
    script=""

    if ! plan_has_on "$PLAN_FILE" "recipe" &&
        ! plan_has_on "$PLAN_FILE" "github-release"; then
        echo
        echo "⏭️  跳过：Recipes / GitHub Releases 应用（未选中任何项）"
        record_result "SKIP" "步骤:recipe" "用户未选中"
        return 0
    fi

    while IFS='|' read -r state type name label || [ -n "${state:-}" ]; do
        [ "${state:-}" = "ON" ] || continue
        case "${type:-}" in
            recipe)
                script="$CONFIG_DIR/recipes/${name}.sh"
                if [ ! -f "$script" ]; then
                    echo
                    echo "❌ Recipe 脚本不存在：${script}"
                    record_result "FAIL" "recipe:${name}" "脚本不存在"
                    STEP_FAIL_COUNT=$((STEP_FAIL_COUNT + 1))
                    continue
                fi
                run_step "recipe:${name}" "🧩 ${label:-$name}..." "$script"
                ;;
            github-release)
                script="$SCRIPTS_DIR/github_release_apps.sh"
                run_step \
                    "github-release:${name}" \
                    "📦 ${label:-$name}..." \
                    "$script" \
                    "$name"
                ;;
        esac
    done <"$PLAN_FILE"
}

maybe_run_type "defaults" "defaults" "🔧 修改系统设置..." "$CONFIG_DIR/defaults_config.sh"
maybe_run_brew
maybe_run_recipes
maybe_run_type "dock" "dock" "🖥️  配置 Dock..." "$CONFIG_DIR/defaults_dock.sh"

# 软件或设置可能已经变化，使当天的审计结果失效。
if ! sh "$SCRIPTS_DIR/audit.sh" snapshot --quiet; then
    echo "无法更新设置基线；本次修改的结果仍见下方。"
    sh "$SCRIPTS_DIR/audit.sh" invalidate --quiet || true
fi

# 保存本次未完成的选择，供下一次仅重试失败项。
retry_temp="$(mktemp "$retry_dir/retry.XXXXXX")" || exit 1
awk -F '\t' '
    FILENAME == ARGV[1] { seen[$2]=1; if ($1 == "FAIL") failed[$2] = 1; next }
    {
        split($0, p, "|")
        if (p[1] != "ON") next
        key = p[2] ":" p[3]
        retry = failed[key]
        if ((p[2] == "brew" || p[2] == "cask" || p[2] == "mas") && failed["Homebrew"]) retry = 1
        if ((p[2] == "brew" || p[2] == "cask" || p[2] == "mas") && failed["步骤:brew"] && !seen[key]) retry = 1
        if (p[2] == "mas" && failed["mas"]) retry = 1
        if ((p[2] == "recipe" || p[2] == "github-release") && failed["步骤:" key]) retry = 1
        if (retry) print $0
    }
' "$MAC_AS_CODE_RESULTS" "$PLAN_FILE" >"$retry_temp"
mv "$retry_temp" "$retry_dir/retry.plan" || exit 1
print_results_summary "$MAC_AS_CODE_RESULTS"
summary_status=$?
persist_results_log "$MAC_AS_CODE_RESULTS" "apply" "$ROOT_DIR"

echo
if [ "$summary_status" -eq 0 ] && [ "$STEP_FAIL_COUNT" -eq 0 ]; then
    echo "✅ 全部完成"
    echo "如需恢复个人数据：运行 sh mac.sh，选择从备份恢复。"
    exit 0
fi

echo "⚠️  执行结束，但仍有失败项；可从 sh mac.sh 的配置菜单重试失败项；详情见日志。"
exit 1
