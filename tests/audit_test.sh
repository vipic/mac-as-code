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

SCENARIO_FAILED=0
SCENARIO_OUTPUT=""

scenario_begin() {
    SCENARIO_NAME="$1"
    SCENARIO_FAILED=0
    SCENARIO_OUTPUT="$(mktemp -t mac-as-code-audit-output.XXXXXX)"
}

capture_audit() {
    if ! run_audit "$@" >"$SCENARIO_OUTPUT" 2>&1; then
        echo "   命令执行失败：audit.sh $*"
        SCENARIO_FAILED=1
    fi
}

expect_contains() {
    file="$1"
    expected="$2"
    if ! grep -Fq "$expected" "$file"; then
        echo "   缺少预期内容：$expected"
        SCENARIO_FAILED=1
    fi
}

expect_not_contains() {
    file="$1"
    unexpected="$2"
    if grep -Fq "$unexpected" "$file"; then
        echo "   出现不应存在的内容：$unexpected"
        SCENARIO_FAILED=1
    fi
}

scenario_end() {
    if [ "$SCENARIO_FAILED" -eq 0 ]; then
        echo "✅ PASS: $SCENARIO_NAME"
        PASSED=$((PASSED + 1))
    else
        echo "❌ FAIL: $SCENARIO_NAME"
        sed 's/^/   /' "$SCENARIO_OUTPUT"
        FAILED=$((FAILED + 1))
    fi
    rm -f "$SCENARIO_OUTPUT"
}

scenario_begin "配置审计区分差异、标量命令和无法安全推导的设置"
capture_audit defaults
expect_contains "$SCENARIO_OUTPUT" "defaults write TestDomain MenuVisible -int '0'"
expect_contains "$SCENARIO_OUTPUT" "无法自动比较"
expect_contains "$SCENARIO_OUTPUT" "当前值"
expect_contains "$SCENARIO_OUTPUT" "仓库期望"
expect_contains "$SCENARIO_OUTPUT" "⚠ 与仓库不同"
expect_contains "$SCENARIO_OUTPUT" "与仓库一致 2，⚠ 与仓库不同 1"
scenario_end

scenario_begin "应用审计覆盖包管理器差异和可匹配的手工安装应用"
capture_audit apps
expect_contains "$SCENARIO_OUTPUT" "extra-formula"
expect_contains "$SCENARIO_OUTPUT" "extra-cask"
expect_contains "$SCENARIO_OUTPUT" "Extra Store"
expect_contains "$SCENARIO_OUTPUT" "应用存在（非 Homebrew）"
expect_contains "$SCENARIO_OUTPUT" "manual-cask"
expect_contains "$SCENARIO_OUTPUT" "本机"
expect_contains "$SCENARIO_OUTPUT" "仓库清单"
expect_contains "$SCENARIO_OUTPUT" "⚠ 与仓库不同"
expect_contains "$SANDBOX/cache/actions.tsv" "add-brewfile"
expect_contains "$SANDBOX/cache/actions.tsv" "add-manual-cask"
expect_not_contains "$SANDBOX/cache/actions.tsv" "adopt-cask"
scenario_end

cat >"$DEFAULTS_STATE" <<'EOF'
TestDomain|MenuVisible|0
TestDomain|Greeting|hello world
DockDomain|Hidden|1
EOF
scenario_begin "当天缓存保持快照，refresh 后读取最新状态"
capture_audit defaults
expect_contains "$SCENARIO_OUTPUT" "defaults write TestDomain MenuVisible"
capture_audit --refresh defaults
expect_contains "$SCENARIO_OUTPUT" "与仓库一致 3，⚠ 与仓库不同 0"
expect_contains "$SCENARIO_OUTPUT" "实时查询，已更新今日缓存"
scenario_end

cat >"$DEFAULTS_STATE" <<'EOF'
TestDomain|MenuVisible|1
TestDomain|Greeting|hello world
DockDomain|Hidden|1
EOF
scenario_begin "基线能够发现初始化后发生的设置变化"
capture_audit snapshot
cat >"$DEFAULTS_STATE" <<'EOF'
TestDomain|MenuVisible|0
TestDomain|Greeting|hello world
DockDomain|Hidden|1
EOF
capture_audit changes
expect_contains "$SCENARIO_OUTPUT" "初始化时"
expect_contains "$SCENARIO_OUTPUT" "△ 初始化后变化"
scenario_end

scenario_begin "非交互 append 保持 Brewfile 不变"
brewfile_before="$(mktemp -t mac-as-code-Brewfile-before.XXXXXX)"
cp "$CONFIG_DIR/Brewfile" "$brewfile_before"
capture_audit append
if ! cmp -s "$brewfile_before" "$CONFIG_DIR/Brewfile"; then
    echo "   非交互 append 修改了 Brewfile"
    SCENARIO_FAILED=1
fi
rm -f "$brewfile_before"
scenario_end

scenario_begin "help 是审计命令和数据位置的统一查询入口"
capture_audit help
expect_contains "$SCENARIO_OUTPUT" "sh scripts/audit.sh defaults"
expect_contains "$SCENARIO_OUTPUT" "sh scripts/audit.sh append"
expect_contains "$SCENARIO_OUTPUT" ".cache/mac-as-code/audit/"
scenario_end

echo
if [ "$FAILED" -ne 0 ]; then
    echo "❌ 审计测试失败：${FAILED} 组失败，${PASSED} 组通过"
    exit 1
fi
echo "✅ 审计测试通过：${PASSED} 个核心场景"
