#!/bin/sh
set -u

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"
# shellcheck source=common.sh
. "$SCRIPTS_DIR/common.sh"

CONFIG_FILE="$ROOT_DIR/config/github_release_apps.conf"
TARGET_ID="${1:-}"
FOUND_COUNT=0
FAIL_COUNT=0

if [ ! -f "$CONFIG_FILE" ]; then
    echo "❌ 未找到 GitHub Releases 应用清单：${CONFIG_FILE}"
    exit 1
fi

while IFS='|' read -r app_id label repository app_name app_path <&3; do
    [ -n "$app_id" ] || continue
    if [ -n "$TARGET_ID" ] && [ "$app_id" != "$TARGET_ID" ]; then
        continue
    fi

    FOUND_COUNT=$((FOUND_COUNT + 1))
    echo
    echo "======== ${label} ========"
    if ! sh "$SCRIPTS_DIR/install_github_release_app.sh" \
        "$repository" \
        "$app_name" \
        "$app_path"; then
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
done 3<<EOF
$(parse_github_release_apps "$CONFIG_FILE")
EOF

if [ -n "$TARGET_ID" ] && [ "$FOUND_COUNT" -eq 0 ]; then
    echo "❌ 清单中没有 GitHub Releases 应用：${TARGET_ID}"
    exit 2
fi

if [ "$FOUND_COUNT" -eq 0 ]; then
    echo "ℹ️  GitHub Releases 应用清单为空"
    exit 0
fi

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
exit 0
