#!/bin/sh
# 从实时状态生成执行计划；不修改电脑、仓库或审计缓存。
set -eu
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
export MAC_AS_CODE_AUDIT_LIBRARY=1
# shellcheck source=audit.sh
. "$SCRIPTS_DIR/audit.sh"
[ "$#" -eq 2 ] || { echo "用法：sh scripts/plan.sh <计划文件> <详情文件>" >&2; exit 1; }
output_plan="$1"
output_details="$2"
work_dir="$(mktemp -d -t mac-as-code-plan-build.XXXXXX)"
trap 'rm -rf "$work_dir"; cleanup' EXIT HUP INT TERM
build_catalog
create_default_plan "$BREWFILE" "$work_dir/full.plan" "${MAC_AS_CODE_CONFIG_DIR:-$ROOT_DIR/config}"
: >"$output_plan"
: >"$output_details"
mas_readable=0
if command -v mas >/dev/null 2>&1 && mas list >"$work_dir/mas" 2>/dev/null; then
    mas_readable=1
fi
# 以注解项为执行单位；同一项中的多个键只产生一个操作。
while IFS='|' read -r _state item_type item_name item_extra; do
    item_status=manual
    item_label="$item_extra"
    item_detail="无法自动比较；执行此项会运行清单中的命令"
    case "$item_type" in
        defaults|dock)
            awk -F '\t' -v t="$item_type" -v n="$item_name" '$2 == t && $3 == n' "$CATALOG" >"$work_dir/keys"
            if ! grep -q '^UNSUPPORTED' "$work_dir/keys" && [ -s "$work_dir/keys" ]; then
                item_status=met
                : >"$work_dir/values"
                while IFS="$(printf '\t')" read -r _kind _group _id _label domain key value_type expected; do
                    expected="$(normalize_expected "$value_type" "$expected")"
                    current="$(read_current_default "$domain" "$key" 2>/dev/null || printf '__MAC_AS_CODE_MISSING__')"
                    current="$(normalize_expected "$value_type" "$current")"
                    if [ "$current" != "$expected" ]; then
                        item_status=pending
                        printf '%s: %s → %s; ' "$key" "$(print_value "$current")" "$expected" >>"$work_dir/values"
                    fi
                done <"$work_dir/keys"
                item_detail="$(cat "$work_dir/values")"
                [ "$item_status" != met ] || item_detail="与配置清单一致"
            fi
            case "$item_name" in
                launchpad-grid|clear-and-pin-apps|simple-password)
                    item_status=manual
                    item_detail="需明确选择：$item_label"
                    ;;
            esac
            ;;
        brew|cask)
            item_label="$item_name"
            item_status=pending
            item_detail="未检测到 → 安装（${item_type}）"
            if command -v brew >/dev/null 2>&1; then
                brew_kind=--formula
                [ "$item_type" != cask ] || brew_kind=--cask
                if brew list "$brew_kind" "$item_name" >/dev/null 2>&1; then
                    item_status=met
                    item_detail="已安装"
                elif [ "$item_type" = cask ] && cask_application_exists "$item_name"; then
                    item_status=met
                    item_detail="应用已存在（非 Homebrew 安装）"
                fi
            elif [ "$item_type" = cask ]; then
                item_status=manual
                item_detail="Homebrew 尚未安装，无法可靠识别现有应用；选择后尝试安装"
            fi
            ;;
        mas)
            item_label="$item_name"
            if [ "$mas_readable" -eq 1 ]; then
                if awk -v id="$item_extra" '$1 == id { found = 1 } END { exit found ? 0 : 1 }' "$work_dir/mas"; then
                    item_status=met
                    item_detail="已安装"
                else
                    item_status=pending
                    item_detail="未检测到 → 从 App Store 安装"
                fi
            elif mas_application_exists "$item_extra"; then
                item_status=met
                item_detail="应用已存在"
            else
                item_detail="无法读取 App Store 安装清单；选择后安装，可能需要登录"
            fi
            ;;
        github-release)
            app_path="$(parse_github_release_apps "$GITHUB_APPS_CONFIG" | awk -F '|' -v id="$item_name" '$1 == id { print $5 }')"
            if [ -n "$app_path" ] && [ -d "$APPLICATIONS_DIR/${app_path##*/}" ]; then
                item_status=met
                item_detail="已安装；此流程不自动升级软件"
            else
                item_status=pending
                item_detail="未检测到 → 安装（GitHub Releases）"
            fi
            ;;
        recipe)
            if [ "$item_name" = oh-my-zsh ]; then
                if [ -d "${ZSH:-$HOME/.oh-my-zsh}" ]; then
                    item_status=met
                    item_detail="已安装"
                else
                    item_status=pending
                    item_detail="未检测到 → 安装 Oh My Zsh"
                fi
            fi
            ;;
    esac
    item_detail="$(printf '%s' "$item_detail" | tr '\t\n|' '   ')"
    item_label="$(printf '%s' "$item_label" | tr '\t\n|' '   ')"
    printf '%s\t%s\t%s\t%s\t%s\n' "$item_type" "$item_name" "$item_status" "$item_label" "$item_detail" >>"$output_details"
    # 已满足项仅进入详情；调整选择时也无需重复勾选。
    if [ "$item_status" != met ]; then
        state=OFF
        [ "$item_status" != pending ] || state=ON
        printf '%s|%s|%s|%s\n' "$state" "$item_type" "$item_name" "$item_extra" >>"$output_plan"
    fi
done <"$work_dir/full.plan"
