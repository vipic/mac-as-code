#!/bin/sh
# 隔离 HOME、配置、命令与输出；不访问网络或运行安装器。
set -eu
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SANDBOX="$(mktemp -d -t mac-as-code-workflow-test.XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT HUP INT TERM
mkdir -p "$SANDBOX/bin" "$SANDBOX/config/recipes" "$SANDBOX/home" "$SANDBOX/Applications/Demo.app"
export HOME="$SANDBOX/home"
export ZSH="$HOME/.oh-my-zsh"
export PATH="$SANDBOX/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export MAC_AS_CODE_CONFIG_DIR="$SANDBOX/config"
export MAC_AS_CODE_DEFAULTS_CONFIG="$SANDBOX/config/defaults_config.sh"
export MAC_AS_CODE_DOCK_CONFIG="$SANDBOX/config/defaults_dock.sh"
export MAC_AS_CODE_BREWFILE="$SANDBOX/config/Brewfile"
export MAC_AS_CODE_GITHUB_APPS_CONFIG="$SANDBOX/config/github_release_apps.conf"
export MAC_AS_CODE_APPLICATIONS_DIR="$SANDBOX/Applications"
export MAC_AS_CODE_STATE_DIR="$SANDBOX/state"
export MAC_AS_CODE_CACHE_DIR="$SANDBOX/cache"
export TEST_DEFAULTS_STATE="$SANDBOX/defaults"
cat >"$MAC_AS_CODE_DEFAULTS_CONFIG" <<'EOF'
# matched | 已满足的设置
defaults write Test Same -bool true
# grouped | 多键设置
defaults write Test One -int 1
defaults write Test Two -int 2
# complex | 需要确认的复合设置
defaults write Test Complex -dict-add key value
EOF
cat >"$MAC_AS_CODE_DOCK_CONFIG" <<'EOF'
# launchpad-grid | 重置布局
defaults write Dock ResetLaunchPad -int 1
EOF
cat >"$MAC_AS_CODE_BREWFILE" <<'EOF'
brew "installed"
brew "missing"
cask "present-cask"
mas "Store App", id: 123
EOF
cat >"$MAC_AS_CODE_GITHUB_APPS_CONFIG" <<'EOF'
owner/demo|Demo
owner/missing|Missing
EOF
cat >"$SANDBOX/config/recipes/custom.sh" <<'EOF'
#!/bin/sh
# custom | 自定义步骤
exit 0
EOF
cat >"$TEST_DEFAULTS_STATE" <<'EOF'
Test|Same|1
Test|One|1
Test|Two|0
Dock|ResetLaunchPad|1
EOF
cat >"$SANDBOX/bin/defaults" <<'EOF'
#!/bin/sh
[ "$1" = read ] || exit 99
awk -F '|' -v d="$2" -v k="$3" '$1==d && $2==k {print $3; found=1} END {exit found ? 0 : 1}' "$TEST_DEFAULTS_STATE"
EOF
cat >"$SANDBOX/bin/brew" <<'EOF'
#!/bin/sh
case "$*" in
    'list --formula installed'|'list --cask present-cask') exit 0 ;;
    'list --formula missing') exit 1 ;;
    *) echo "测试中禁止未声明的 brew 调用：$*" >&2; exit 99 ;;
esac
EOF
cat >"$SANDBOX/bin/mas" <<'EOF'
#!/bin/sh
[ "$1" = list ] || exit 99
printf '123 Store App (1.0)\n'
EOF
cat >"$SANDBOX/bin/curl" <<'EOF'
#!/bin/sh
exit 99
EOF
chmod +x "$SANDBOX/bin/"*
fail() { echo "失败：$*" >&2; exit 1; }
pass() { echo "通过：$*"; }
sh "$ROOT_DIR/scripts/plan.sh" "$SANDBOX/plan" "$SANDBOX/details"
grep -q '^ON|defaults|grouped|' "$SANDBOX/plan" || fail '多键差异未被选中'
[ "$(grep -c '|grouped|' "$SANDBOX/plan")" -eq 1 ] || fail '多键设置重复执行'
! grep -q '|matched|' "$SANDBOX/plan" || fail '已满足设置未折叠'
grep -q '^OFF|defaults|complex|' "$SANDBOX/plan" || fail '复合设置默认执行'
grep -q '^OFF|dock|launchpad-grid|' "$SANDBOX/plan" || fail '重置布局默认执行'
grep -q '^OFF|recipe|custom|' "$SANDBOX/plan" || fail '未知 recipe 默认执行'
grep -q '^ON|brew|missing|' "$SANDBOX/plan" || fail '未安装软件未进入计划'
grep -q '^ON|github-release|missing|' "$SANDBOX/plan" || fail 'GitHub 软件未进入计划'
! grep -q '|demo|' "$SANDBOX/plan" || fail '已存在 GitHub 软件重复安装'
! grep -q '|installed|' "$SANDBOX/plan" || fail '已安装软件重复安装'
! grep -q '|Store App|' "$SANDBOX/plan" || fail '已安装 MAS 应用重复安装'
grep -q 'Two: 0 → 2' "$SANDBOX/details" || fail '缺少当前值与目标值'
pass '实时计划去重、折叠已满足项，并保留需确认项'

# 状态改变后下一次计划立即反映，不使用当天缓存。
sed 's/Test|Two|0/Test|Two|2/' "$TEST_DEFAULTS_STATE" >"$SANDBOX/new"
mv "$SANDBOX/new" "$TEST_DEFAULTS_STATE"
sh "$ROOT_DIR/scripts/plan.sh" "$SANDBOX/plan" "$SANDBOX/details"
! grep -q '|grouped|' "$SANDBOX/plan" || fail '计划读取了过期状态'
[ ! -d "$SANDBOX/cache" ] || fail '生成计划不应写入审计缓存'
pass '计划始终读取实时状态'

for task in '' configure backup restore; do
    # task 为受控的单词或空串。
    # shellcheck disable=SC2086
    if sh "$ROOT_DIR/init.sh" $task </dev/null >"$SANDBOX/out" 2>&1; then
        fail "非交互 $task 未拒绝隐式执行"
    fi
done
sh "$ROOT_DIR/init.sh" --help >"$SANDBOX/out"
grep -q 'restore' "$SANDBOX/out" || fail '帮助缺少恢复入口'
[ ! -d "$HOME/Desktop" ] || fail '打开入口或帮助创建了备份'
pass '非交互入口与帮助无执行副作用'

# 部分成功时，仅更新成功应用项的基线。
sh "$ROOT_DIR/scripts/audit.sh" snapshot --quiet
sed 's/Test|Same|1/Test|Same|0/; s/Test|Two|2/Test|Two|5/' "$TEST_DEFAULTS_STATE" >"$SANDBOX/new"
mv "$SANDBOX/new" "$TEST_DEFAULTS_STATE"
printf 'OK\tdefaults:grouped\t完成\n' >"$SANDBOX/results"
MAC_AS_CODE_RESULTS="$SANDBOX/results" sh "$ROOT_DIR/scripts/audit.sh" snapshot --quiet
awk -F '\t' '$3=="Test" && $4=="Same" {exit $6==1 ? 0 : 1}' "$SANDBOX/state/defaults-baseline.tsv" || fail '无关基线被覆盖'
awk -F '\t' '$3=="Test" && $4=="Two" {exit $6==5 ? 0 : 1}' "$SANDBOX/state/defaults-baseline.tsv" || fail '成功项基线未更新'
pass '部分应用保留无关项目的变化基线'

# 从模板提取独立恢复脚本，只验证拒绝路径，绝不触及真实应用。
mkdir "$SANDBOX/snapshot"
awk '/^RESTORE_SCRIPT$/ {inside=0} inside {print} /cat >.*RESTORE_SCRIPT/ {inside=1}' "$ROOT_DIR/scripts/backup.sh" >"$SANDBOX/snapshot/restore.sh"
[ -s "$SANDBOX/snapshot/restore.sh" ] || fail '恢复模板未提取'
bash -n "$SANDBOX/snapshot/restore.sh"
if bash "$SANDBOX/snapshot/restore.sh" </dev/null >"$SANDBOX/out" 2>&1; then fail '独立恢复隐式执行'; fi
if bash "$SANDBOX/snapshot/restore.sh" --yes >"$SANDBOX/out" 2>&1; then fail '独立恢复接受无校验快照'; fi
if sh "$ROOT_DIR/init.sh" restore --yes "$SANDBOX/snapshot" >"$SANDBOX/out" 2>&1; then fail '恢复入口接受无校验快照'; fi
printf 'invalid\n' >"$SANDBOX/snapshot/SHA256SUMS"
if sh "$ROOT_DIR/init.sh" restore --yes "$SANDBOX/snapshot" >"$SANDBOX/out" 2>&1; then fail '恢复入口接受损坏快照'; fi
pass '独立恢复与统一入口拒绝缺失或损坏的校验数据'



# 实际执行器使用隔离的仓库与命令，验证只应用计划项和失败重试。
mkdir -p "$SANDBOX/repo/config/recipes"
cp -R "$ROOT_DIR/scripts" "$SANDBOX/repo/scripts"
cp "$ROOT_DIR/init.sh" "$SANDBOX/repo/init.sh"
awk '/^# menu-bar-visible / {exit} {print}' "$ROOT_DIR/config/defaults_config.sh" >"$SANDBOX/repo/config/defaults_config.sh"
cat >>"$SANDBOX/repo/config/defaults_config.sh" <<'EOF'
# first | 第一个设置
defaults write Test First -int 1
# fail | 失败的设置
defaults write Test Fail -int 1
# untouched | 未选择设置
defaults write Test Untouched -int 1
EOF
cp "$MAC_AS_CODE_DOCK_CONFIG" "$SANDBOX/repo/config/defaults_dock.sh"
: >"$SANDBOX/repo/config/Brewfile"
: >"$SANDBOX/repo/config/github_release_apps.conf"
export TEST_WRITES="$SANDBOX/writes"
cat >"$SANDBOX/bin/defaults" <<'EOF'
#!/bin/sh
case "$1" in
    read) exit 1 ;;
    write)
        printf '%s\n' "$3" >>"$TEST_WRITES"
        [ "$3" != Fail ]
        ;;
    *) exit 99 ;;
esac
EOF
cat >"$SANDBOX/bin/killall" <<'EOF'
#!/bin/sh
exit 0
EOF
cat >"$SANDBOX/bin/uname" <<'EOF'
#!/bin/sh
printf 'Darwin\n'
EOF
chmod +x "$SANDBOX/bin/"*
export MAC_AS_CODE_DEFAULTS_CONFIG="$SANDBOX/repo/config/defaults_config.sh"
export MAC_AS_CODE_DOCK_CONFIG="$SANDBOX/repo/config/defaults_dock.sh"
export MAC_AS_CODE_BREWFILE="$SANDBOX/repo/config/Brewfile"
export MAC_AS_CODE_GITHUB_APPS_CONFIG="$SANDBOX/repo/config/github_release_apps.conf"
printf 'ON|defaults|first|第一个设置\nON|defaults|fail|失败的设置\nOFF|defaults|untouched|未选择设置\n' >"$SANDBOX/input.plan"
if MAC_AS_CODE_INPUT_PLAN="$SANDBOX/input.plan" sh "$SANDBOX/repo/scripts/apply.sh" --yes >"$SANDBOX/out" 2>&1; then
    cat "$SANDBOX/out"
    fail '部分失败应返回非零'
fi
grep -qx First "$TEST_WRITES" || fail '未执行选中设置'
grep -qx Fail "$TEST_WRITES" || fail '未尝试第二个设置'
! grep -q Untouched "$TEST_WRITES" || fail '执行了未选择设置'
[ "$(wc -l <"$SANDBOX/state/retry.plan" | tr -d ' ')" -eq 1 ] || fail '重试计划包含非失败项'
grep -q '^ON|defaults|fail|' "$SANDBOX/state/retry.plan" || fail '重试计划缺失失败项'
pass '执行器仅应用选中项，并只记录失败项供重试'

# 确认后复核发现变化时，自动模式停止，不能执行过期计划。
cat >"$SANDBOX/repo/scripts/plan.sh" <<'EOF'
#!/bin/sh
set -eu
n=0
[ ! -f "$TEST_SCAN_COUNT" ] || n="$(cat "$TEST_SCAN_COUNT")"
n=$((n+1))
printf '%s' "$n" >"$TEST_SCAN_COUNT"
printf 'ON|defaults|first|测试设置\n' >"$1"
printf 'defaults\tfirst\tpending\t测试设置\t%s → 1\n' "$n" >"$2"
EOF
cat >"$SANDBOX/repo/scripts/apply.sh" <<'EOF'
#!/bin/sh
touch "$TEST_EXECUTED"
EOF
export TEST_SCAN_COUNT="$SANDBOX/scans"
export TEST_EXECUTED="$SANDBOX/executed"
if sh "$SANDBOX/repo/init.sh" configure --yes >"$SANDBOX/out" 2>&1; then fail '复核变化时没有停止'; fi
[ ! -f "$TEST_EXECUTED" ] || fail '执行了过期计划'
grep -q '状态已变化' "$SANDBOX/out" || fail '没有说明复核失败原因'
pass '确认后状态变化时停止自动执行'

echo "工作流测试通过。"
