#!/bin/sh
set -u

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_DIR="$ROOT_DIR/config"
SCRIPTS_DIR="$ROOT_DIR/scripts"
# shellcheck source=scripts/common.sh
. "$SCRIPTS_DIR/common.sh"

if ! command -v create_default_plan >/dev/null 2>&1; then
    echo "❌ 未能加载 scripts/common.sh（${SCRIPTS_DIR}/common.sh）"
    echo "   请在仓库根目录执行：sh init.sh  或  bash init.sh"
    exit 1
fi

START_FROM=""
SKIP_DOCTOR=0
YES_MODE=0
PLAN_FILE=""

usage() {
    cat <<'EOF'
用法：sh init.sh [--from <步骤名>] [--skip-doctor] [--yes]
      bash init.sh 亦可

装机主入口：分步多选（↑↓ / 空格）→ 系统设置 → 软件 → Dock。
默认先跑装机前 doctor；结果汇总保存到项目内 logs/（无装机后 doctor）。

步骤名：defaults, brew, plugin, dock（zsh 仍可作为 plugin 的别名）
示例：
  sh init.sh
  bash init.sh
  sh init.sh --from brew
  sh init.sh --yes              # 跳过多选，默认全选
  sh init.sh --skip-doctor      # 跳过装机前检查

Git 用户信息随 backup / restore 迁移 ~/.gitconfig，不在装机流程里配置。
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        --skip-doctor)
            SKIP_DOCTOR=1
            shift
            ;;
        --yes|-y)
            YES_MODE=1
            shift
            ;;
        --from)
            if [ -z "${2:-}" ]; then
                echo "❌ --from 需要指定步骤名：defaults, brew, plugin, dock"
                exit 1
            fi
            START_FROM="$2"
            shift 2
            ;;
        *)
            echo "❌ 未知参数：$1"
            usage
            exit 1
            ;;
    esac
done

# 检查 Xcode Command Line Tools
if ! xcode-select -p >/dev/null 2>&1; then
    echo "📦 安装 Xcode Command Line Tools..."
    xcode-select --install
    echo "⚠️  安装完成后请重新运行本脚本"
    exit 0
fi

if [ "$SKIP_DOCTOR" -eq 0 ]; then
    echo
    echo "======== 装机前检查 ========"
    if ! sh "$SCRIPTS_DIR/doctor.sh" --pre; then
        echo "⚠️  装机前检查未通过；若仍要继续，可用：sh init.sh --skip-doctor"
        exit 1
    fi
fi

PLAN_FILE="$(mktemp -t mac-as-code-plan.XXXXXX)"
export MAC_AS_CODE_PLAN="$PLAN_FILE"
MAC_AS_CODE_RESULTS="$(mktemp -t mac-as-code.XXXXXX)"
export MAC_AS_CODE_RESULTS
export MAC_AS_CODE_LOG_DIR="$ROOT_DIR/logs"
: >"$MAC_AS_CODE_RESULTS"
trap 'rm -f "$MAC_AS_CODE_RESULTS" "$PLAN_FILE"' EXIT

create_default_plan "$CONFIG_DIR/Brewfile" "$PLAN_FILE" "$CONFIG_DIR"
edit_plan_interactive "$PLAN_FILE" "$YES_MODE"
plan_status=$?
if [ "$plan_status" -eq 2 ]; then
    exit 0
fi
if [ "$plan_status" -ne 0 ]; then
    exit "$plan_status"
fi

# App Store：多选已决定装哪些；这里只处理登录，不再问「继续/跳过全部」
confirm_mas_upfront() {
    mas_on=0
    apple_id=""

    while IFS='|' read -r state type name id; do
        [ "$state" = "ON" ] && [ "$type" = "mas" ] || continue
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

    if [ "$YES_MODE" = "1" ] || [ ! -t 0 ]; then
        echo "ℹ️  非交互模式：未检测到 Apple ID，仍尝试安装（可能失败）"
        export MAC_AS_CODE_MAS_READY=1
        return 0
    fi

    echo "⚠️  未检测到 Apple ID，打开 App Store，请登录后按 Enter 继续"
    open -a "App Store" 2>/dev/null || true

    while true; do
        printf "登录完成后按 Enter > "
        if ! read -r answer; then
            echo
            echo "⚠️  无法确认登录，仍继续尝试安装"
            export MAC_AS_CODE_MAS_READY=1
            return 0
        fi
        if apple_id_signed_in; then
            apple_id="$(apple_id_account)"
            echo "✅ 已检测到 Apple ID：${apple_id}"
            export MAC_AS_CODE_MAS_READY=1
            return 0
        fi
        echo "仍未检测到登录，请登录后再按 Enter（或 Ctrl+C 中止）"
        open -a "App Store" 2>/dev/null || true
    done
}

confirm_mas_upfront

STEP_FAIL_COUNT=0

run_step() {
    name="$1"
    description="$2"
    script_path="$3"

    if [ -n "$START_FROM" ] && [ "$START_FROM" != "$name" ]; then
        echo "⏭️  跳过：${description}"
        record_result "SKIP" "步骤:$name" "未到达 --from 起始步骤"
        return 0
    fi
    START_FROM=""

    echo
    echo "$description"
    if sh "$script_path"; then
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

maybe_run_plugins() {
    state=""
    type=""
    name=""
    label=""
    script=""

    if ! plan_has_on "$PLAN_FILE" "plugin"; then
        echo
        echo "⏭️  跳过：插件（未选中任何项）"
        record_result "SKIP" "步骤:plugin" "用户未选中"
        return 0
    fi

    # --from plugin（或旧别名 zsh）从此步开始；其它起始步则整段跳过
    if [ -n "$START_FROM" ] && [ "$START_FROM" != "plugin" ] && [ "$START_FROM" != "zsh" ]; then
        echo
        echo "⏭️  跳过：插件（未到达 --from 起始步骤）"
        while IFS='|' read -r state type name label || [ -n "${state:-}" ]; do
            [ "${state:-}" = "ON" ] && [ "${type:-}" = "plugin" ] || continue
            record_result "SKIP" "plugin:${name}" "未到达 --from 起始步骤"
        done <"$PLAN_FILE"
        return 0
    fi
    START_FROM=""

    while IFS='|' read -r state type name label || [ -n "${state:-}" ]; do
        [ "${state:-}" = "ON" ] && [ "${type:-}" = "plugin" ] || continue
        script="$CONFIG_DIR/plugins/${name}.sh"
        if [ ! -f "$script" ]; then
            echo
            echo "❌ 插件脚本不存在：${script}"
            record_result "FAIL" "plugin:${name}" "脚本不存在"
            STEP_FAIL_COUNT=$((STEP_FAIL_COUNT + 1))
            continue
        fi
        run_step "plugin:${name}" "🐚 ${label:-$name}..." "$script"
    done <"$PLAN_FILE"
}

maybe_run_type "defaults" "defaults" "🔧 修改系统设置..." "$CONFIG_DIR/defaults_config.sh"
maybe_run_brew
maybe_run_plugins
maybe_run_type "dock" "dock" "🖥️  配置 Dock..." "$CONFIG_DIR/defaults_dock.sh"

print_results_summary "$MAC_AS_CODE_RESULTS"
summary_status=$?
persist_results_log "$MAC_AS_CODE_RESULTS" "init" "$ROOT_DIR"

echo
if [ "$summary_status" -eq 0 ] && [ "$STEP_FAIL_COUNT" -eq 0 ]; then
    echo "✅ 全部完成"
    echo "如需恢复个人数据（含 Git 配置）：进入 backup 快照目录执行 sh restore.sh"
    exit 0
fi

echo "⚠️  执行结束，但仍有失败项；请根据上方汇总与 logs/ 中的报告手动处理。"
exit 1
