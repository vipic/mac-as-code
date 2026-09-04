#!/bin/sh
set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$TESTS_DIR/.." && pwd)"
AUDIT="$ROOT_DIR/scripts/audit.sh"
SANDBOX="$(mktemp -d -t mac-as-code-audit-test.XXXXXX)"
BIN_DIR="$SANDBOX/bin"
CONFIG_DIR="$SANDBOX/config"
STATE_DIR="$SANDBOX/state"
APPLICATIONS_DIR="$SANDBOX/Applications"
DEFAULTS_STATE="$SANDBOX/defaults-state"
CASK_ARTIFACTS="$SANDBOX/cask-artifacts.tsv"
PASSED=0
FAILED=0

cleanup() {
    rm -rf "$SANDBOX"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$BIN_DIR" "$CONFIG_DIR" "$APPLICATIONS_DIR/Demo.app" "$APPLICATIONS_DIR/Adoptable.app" "$APPLICATIONS_DIR/Manual.app"

cat >"$CASK_ARTIFACTS" <<'EOF'
demo-cask	Demo.app
adoptable	Adoptable.app
manual-cask	Manual.app
EOF

cat >"$CONFIG_DIR/defaults_config.sh" <<'EOF'
# menu-visible | 始终显示菜单栏
defaults write TestDomain MenuVisible -int 0

# greeting | 带空格的字符串设置
defaults write TestDomain Greeting -string "hello world"

# complex | 复合字典设置
defaults write TestDomain Complex -dict-add enabled '<true/>'
EOF

cat >"$CONFIG_DIR/defaults_dock.sh" <<'EOF'
# dock-hidden | Dock 自动隐藏
defaults write DockDomain Hidden -bool true
EOF

cat >"$CONFIG_DIR/Brewfile" <<'EOF'
brew "wanted-formula"
cask "wanted-cask"
cask "adoptable"
mas "Wanted Store", id: 123
EOF

cat >"$CONFIG_DIR/github_release_apps.conf" <<'EOF'
owner/demo|Demo
EOF

cat >"$DEFAULTS_STATE" <<'EOF'
TestDomain|MenuVisible|1
TestDomain|Greeting|hello world
DockDomain|Hidden|1
EOF

cat >"$BIN_DIR/defaults" <<'EOF'
#!/bin/sh
if [ "$1" != "read" ]; then
    exit 2
fi
awk -F'|' -v domain="$2" -v key="$3" '
    $1 == domain && $2 == key { print $3; found = 1 }
    END { exit found ? 0 : 1 }
' "$MOCK_DEFAULTS_STATE"
EOF

cat >"$BIN_DIR/brew" <<'EOF'
#!/bin/sh
case "$1:$2:${3:-}" in
    list:--formula:wanted-formula|list:--cask:wanted-cask) exit 0 ;;
    leaves::)
        printf 'wanted-formula\nextra-formula\n'
        ;;
    list:--cask:)
        printf 'wanted-cask\nextra-cask\n'
        ;;
    list:--formula:*|list:--cask:*) exit 1 ;;
    info:--cask:adoptable)
        printf '==> Artifacts\nAdoptable.app (App)\n'
        ;;
    info:--cask:*) exit 1 ;;
    *) exit 1 ;;
esac
EOF

cat >"$BIN_DIR/mas" <<'EOF'
#!/bin/sh
if [ "$1" = "list" ]; then
    printf '123 Wanted Store (1.0)\n999 Extra Store (2.0)\n'
    exit 0
fi
exit 1
EOF

chmod +x "$BIN_DIR/defaults" "$BIN_DIR/brew" "$BIN_DIR/mas"

run_audit() {
    PATH="$BIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin" \
    MOCK_DEFAULTS_STATE="$DEFAULTS_STATE" \
    MAC_AS_CODE_DEFAULTS_CONFIG="$CONFIG_DIR/defaults_config.sh" \
    MAC_AS_CODE_DOCK_CONFIG="$CONFIG_DIR/defaults_dock.sh" \
    MAC_AS_CODE_BREWFILE="$CONFIG_DIR/Brewfile" \
    MAC_AS_CODE_GITHUB_APPS_CONFIG="$CONFIG_DIR/github_release_apps.conf" \
    MAC_AS_CODE_APPLICATIONS_DIR="$APPLICATIONS_DIR" \
    MAC_AS_CODE_CASK_ARTIFACTS_FILE="$CASK_ARTIFACTS" \
    MAC_AS_CODE_STATE_DIR="$STATE_DIR" \
    MAC_AS_CODE_CACHE_DIR="$SANDBOX/cache" \
        sh "$AUDIT" "$@"
}

assert_contains() {
    name="$1"
    expected="$2"
    shift 2
    output="$(mktemp -t mac-as-code-audit-output.XXXXXX)"
    if "$@" >"$output" 2>&1 && grep -Fq "$expected" "$output"; then
        echo "✅ PASS: $name"
        PASSED=$((PASSED + 1))
    else
        echo "❌ FAIL: $name"
        sed 's/^/   /' "$output"
        FAILED=$((FAILED + 1))
    fi
    rm -f "$output"
}

assert_not_contains() {
    name="$1"
    unexpected="$2"
    shift 2
    output="$(mktemp -t mac-as-code-audit-output.XXXXXX)"
    if "$@" >"$output" 2>&1 && ! grep -Fq "$unexpected" "$output"; then
        echo "✅ PASS: $name"
        PASSED=$((PASSED + 1))
    else
        echo "❌ FAIL: $name"
        sed 's/^/   /' "$output"
        FAILED=$((FAILED + 1))
    fi
    rm -f "$output"
}

assert_count() {
    name="$1"
    pattern="$2"
    expected_count="$3"
    shift 3
    output="$(mktemp -t mac-as-code-audit-output.XXXXXX)"
    if "$@" >"$output" 2>&1; then
        actual_count="$(grep -Fc "$pattern" "$output" || true)"
    else
        actual_count=-1
    fi
    if [ "$actual_count" -eq "$expected_count" ]; then
        echo "✅ PASS: $name"
        PASSED=$((PASSED + 1))
    else
        echo "❌ FAIL: $name（期望 ${expected_count}，实际 ${actual_count}）"
        sed 's/^/   /' "$output"
        FAILED=$((FAILED + 1))
    fi
    rm -f "$output"
}

assert_contains "当天第一次查询明确标记实时数据" "数据来源：实时查询，已更新今日缓存" run_audit defaults
assert_contains "当天后续查询明确标记缓存数据" "数据来源：今日缓存" run_audit defaults
assert_contains "每次输出标记审计开始" "mac-as-code 审计开始" run_audit defaults
assert_contains "每次输出标记审计结束" "mac-as-code 审计结束" run_audit defaults
assert_contains "每次输出标记产生结果的命令" "命令：sh scripts/audit.sh defaults" run_audit defaults
assert_count "完整审计的三个分区使用同一表头" "分类" 3 run_audit all
assert_contains "使用终端表格显示当前值和仓库期望值" "不同" run_audit defaults
assert_not_contains "终端表格不输出 Markdown 分隔符" "|---|" run_audit defaults
assert_contains "给出可直接执行的 defaults 命令" "defaults write TestDomain MenuVisible -int '0'" run_audit defaults
assert_contains "识别无法安全推导的复合命令" "无法自动比较" run_audit defaults
assert_contains "字符串中的空格可以解析" "一致 2，不同 1" run_audit defaults
assert_contains "显示本机额外的 Homebrew formula" "extra-formula" run_audit apps
assert_contains "显示本机额外的 cask" "extra-cask" run_audit apps
assert_contains "显示本机额外的 App Store 应用" "Extra Store" run_audit apps
assert_contains "识别已在 Brewfile 但尚未由 Homebrew 管理的 cask" "应用存在，但未由 Homebrew 管理" run_audit apps
assert_not_contains "Brewfile 已有的未管理 cask 不进入追加列表" "adopt-cask" cat "$SANDBOX/cache/actions.tsv"
assert_contains "为额外软件生成加入 Brewfile 的单项动作" "add-brewfile" cat "$SANDBOX/cache/actions.tsv"
assert_contains "识别本机手工安装且可由 cask 管理的应用" "manual-cask" run_audit apps
assert_contains "为手工安装应用生成追加 Brewfile 动作" "add-manual-cask" cat "$SANDBOX/cache/actions.tsv"
assert_contains "非交互 append 不执行所列动作" "只完成审计，没有进入应用差异多选" run_audit append

cat >"$DEFAULTS_STATE" <<'EOF'
TestDomain|MenuVisible|0
TestDomain|Greeting|hello world
DockDomain|Hidden|1
EOF
assert_contains "当天后续查询继续使用缓存" "defaults write TestDomain MenuVisible" run_audit defaults
assert_contains "refresh 强制实时查询并更新缓存" "数据来源：实时查询，已更新今日缓存" run_audit --refresh defaults
assert_contains "refresh 后缓存包含最新状态" "一致 3，不同 0" run_audit defaults

cat >"$DEFAULTS_STATE" <<'EOF'
TestDomain|MenuVisible|1
TestDomain|Greeting|hello world
DockDomain|Hidden|1
EOF
assert_contains "记录初始化基线" "已记录初始化配置基线" run_audit snapshot
cat >"$DEFAULTS_STATE" <<'EOF'
TestDomain|MenuVisible|0
TestDomain|Greeting|hello world
DockDomain|Hidden|1
EOF
assert_contains "使用终端表格显示初始化后的设置变化" "已变化" run_audit changes
assert_contains "非交互 review 只审计不应用" "只完成审计，没有进入应用选择" run_audit review

echo
if [ "$FAILED" -ne 0 ]; then
    echo "❌ 审计测试失败：${FAILED} 组失败，${PASSED} 组通过"
    exit 1
fi
echo "✅ 审计测试通过：${PASSED} 组"
