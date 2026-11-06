#!/bin/sh
# 验证 Apple ID / App Store 登录探测的多系统回退；不读取真实偏好、不访问网络。
set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$TESTS_DIR/.." && pwd)"
SANDBOX="$(mktemp -d -t mac-as-code-common-test.XXXXXX)"
BIN_DIR="$SANDBOX/bin"
trap 'rm -rf "$SANDBOX"' EXIT HUP INT TERM

mkdir -p "$BIN_DIR"
cat >"$BIN_DIR/defaults" <<'EOF'
#!/bin/sh
[ "$1" = "read" ] || exit 2
case "$2:${3:-}" in
    MobileMeAccounts:Accounts)
        [ -n "${MOCK_APPLE_ID:-}" ] || exit 1
        printf '(\n    {\n        AccountID = "%s";\n    }\n)\n' "$MOCK_APPLE_ID"
        ;;
    com.apple.appleaccount.informationcache:AAIsAccountSignedIn)
        [ "${MOCK_SIGNED_IN:-0}" = "1" ] || exit 1
        printf '1\n'
        ;;
    com.apple.appleaccount.informationcache:AAAccountFullName)
        [ -n "${MOCK_APPLE_NAME:-}" ] || exit 1
        printf '%s\n' "$MOCK_APPLE_NAME"
        ;;
    com.apple.itunescloud:ICDefaultsKeyAuthServiceClientTokenCache)
        [ "${MOCK_TOKEN_CACHE:-0}" = "1" ] || exit 1
        printf '{\n    10403194163 = {length = 519, bytes = 0x00};\n}\n'
        ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$BIN_DIR/defaults"
export PATH="$BIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin"

fail() { echo "失败：$*" >&2; exit 1; }
pass() { echo "通过：$*"; }

# 每个场景在独立子 shell 中加载被测函数，避免变量与状态互相影响。
probe() {
    (
        # shellcheck source=../scripts/common.sh
        . "$ROOT_DIR/scripts/common.sh"
        "$@"
    )
}

reset_mocks() {
    MOCK_APPLE_ID=""
    MOCK_SIGNED_IN=0
    MOCK_APPLE_NAME=""
    MOCK_TOKEN_CACHE=0
    export MOCK_APPLE_ID MOCK_SIGNED_IN MOCK_APPLE_NAME MOCK_TOKEN_CACHE
}

# 旧版 macOS：MobileMeAccounts 可直接读出 Apple ID。
reset_mocks
MOCK_APPLE_ID="user@example.com"
[ "$(probe apple_id_account)" = "user@example.com" ] || fail '未从 MobileMeAccounts 读取账号'
[ "$(probe apple_id_label)" = "user@example.com" ] || fail '旧系统未使用 Apple ID 作为显示名'
probe apple_id_signed_in || fail '旧系统登录状态未被识别'
pass '旧版 macOS 通过 MobileMeAccounts 识别登录'

# 新版 macOS：MobileMeAccounts 不存在，改读 Apple 账户信息缓存。
reset_mocks
MOCK_SIGNED_IN=1
MOCK_APPLE_NAME="Test User"
[ -z "$(probe apple_id_account)" ] || fail '新版系统不应凭空得到 Apple ID'
[ "$(probe apple_id_label)" = "Test User" ] || fail '新版系统未回退到账户姓名'
probe apple_id_signed_in || fail '新版系统登录状态未被识别'
pass '新版 macOS 通过 Apple 账户缓存识别登录'

# 只有媒体令牌缓存时，仍视为 App Store 已登录。
reset_mocks
MOCK_TOKEN_CACHE=1
[ -z "$(probe apple_id_label)" ] || fail '无账号信息时不应显示伪造的 Apple ID'
probe apple_id_signed_in || fail '媒体令牌缓存未被识别'
pass '媒体令牌缓存可作为 App Store 登录信号'

# 所有信号都缺失时返回未登录，由调用方提示并提供继续入口。
reset_mocks
if probe apple_id_signed_in; then
    fail '没有任何登录信号时仍判定为已登录'
fi
pass '无法读取登录状态时不会误判为已登录'

# 分页后的 a / n 只作用于当前页，不能影响看不到的项目。
pagination_plan="$(mktemp -t mac-as-code-page-plan.XXXXXX)"
cat >"$pagination_plan" <<'PLAN'
ON|defaults|a|
ON|defaults|b|
ON|defaults|c|
ON|defaults|d|
ON|brew|keep|
PLAN
probe plan_set_page_state "$pagination_plan" "defaults|dock" OFF 1 2
[ "$(awk -F'|' '$2 == "defaults" && $3 == "a" { print $1 }' "$pagination_plan")" = "OFF" ] || fail '第 1 页首个项目未被清空'
[ "$(awk -F'|' '$2 == "defaults" && $3 == "c" { print $1 }' "$pagination_plan")" = "ON" ] || fail '第 3 个项目被第 1 页的清空影响'
probe plan_set_page_state "$pagination_plan" "defaults|dock" ON 3 2
[ "$(awk -F'|' '$2 == "defaults" && $3 == "c" { print $1 }' "$pagination_plan")" = "ON" ] || fail '第 3 个项目未被第 2 页选中'
[ "$(awk -F'|' '$2 == "brew" && $3 == "keep" { print $1 }' "$pagination_plan")" = "ON" ] || fail '其他类别的项目被分页操作影响'
rm -f "$pagination_plan"
pass '分页全选与清空只影响当前页'
