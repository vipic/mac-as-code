#!/bin/sh
set -eu

# 从 GitHub 最新正式 Release 安装单一 DMG 应用。
# 用法：sh scripts/install_github_release_app.sh <owner/repo> <App 名称> [安装路径]

REPOSITORY="${1:-}"
APP_NAME="${2:-}"
APP_PATH="${3:-}"

if [ -z "$REPOSITORY" ] || [ -z "$APP_NAME" ]; then
    echo "用法：sh scripts/install_github_release_app.sh <owner/repo> <App 名称> [安装路径]"
    exit 2
fi

case "$REPOSITORY" in
    */*) ;;
    *)
        echo "❌ GitHub 仓库格式无效：${REPOSITORY}（应为 owner/repo）"
        exit 2
        ;;
esac

if [ -z "$APP_PATH" ]; then
    APP_PATH="/Applications/${APP_NAME}.app"
fi

for required_command in curl plutil hdiutil shasum codesign ditto; do
    if ! command -v "$required_command" >/dev/null 2>&1; then
        echo "❌ 缺少安装所需命令：${required_command}"
        exit 1
    fi
done

RELEASE_API="https://api.github.com/repos/${REPOSITORY}/releases/latest"
RELEASE_PAGE="https://github.com/${REPOSITORY}/releases"
TEMP_DIR="$(mktemp -d -t mac-as-code-github-app.XXXXXX)"
RELEASE_JSON="$TEMP_DIR/release.json"
DMG_PATH="$TEMP_DIR/installer.dmg"
MOUNT_PATH="$TEMP_DIR/mount"
MOUNTED=0

cleanup() {
    if [ "$MOUNTED" -eq 1 ]; then
        hdiutil detach "$MOUNT_PATH" -quiet >/dev/null 2>&1 || true
    fi
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "🔎 查询 ${APP_NAME} 最新版本..."
if ! curl -fsSL \
    --retry 3 \
    --connect-timeout 15 \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    -H "User-Agent: Mac-As-Code" \
    "$RELEASE_API" \
    -o "$RELEASE_JSON"; then
    echo "❌ 无法读取 GitHub Release：${RELEASE_PAGE}"
    exit 1
fi

LATEST_TAG="$(
    plutil -extract tag_name raw -o - "$RELEASE_JSON" 2>/dev/null || true
)"
ASSET_COUNT="$(
    plutil -extract assets raw -o - "$RELEASE_JSON" 2>/dev/null || true
)"

case "$ASSET_COUNT" in
    ''|*[!0-9]*)
        echo "❌ 无法读取 GitHub Release 资产列表"
        exit 1
        ;;
esac

DOWNLOAD_URL=""
EXPECTED_SHA256=""
ASSET_INDEX=0
DMG_COUNT=0
ARCH_DMG_COUNT=0
FIRST_DMG_URL=""
FIRST_DMG_SHA256=""
ARCH_DMG_URL=""
ARCH_DMG_SHA256=""
UNIVERSAL_DMG_COUNT=0
UNIVERSAL_DMG_URL=""
UNIVERSAL_DMG_SHA256=""
MACHINE_ARCH="${MAC_AS_CODE_MACHINE_ARCH:-$(uname -m)}"

# 在 Rosetta 进程中 uname 可能返回 x86_64，但应安装 Apple Silicon 包。
if [ -z "${MAC_AS_CODE_MACHINE_ARCH:-}" ] &&
    [ "$MACHINE_ARCH" = "x86_64" ] &&
    [ "$(sysctl -in sysctl.proc_translated 2>/dev/null || true)" = "1" ]; then
    MACHINE_ARCH="arm64"
fi

while [ "$ASSET_INDEX" -lt "$ASSET_COUNT" ]; do
    ASSET_NAME="$(
        plutil \
            -extract "assets.${ASSET_INDEX}.name" \
            raw -o - "$RELEASE_JSON" 2>/dev/null || true
    )"
    ASSET_URL="$(
        plutil \
            -extract "assets.${ASSET_INDEX}.browser_download_url" \
            raw -o - "$RELEASE_JSON" 2>/dev/null || true
    )"

    case "$ASSET_URL" in
        *.dmg)
            DMG_COUNT=$((DMG_COUNT + 1))
            ASSET_NAME_LOWER="$(
                printf '%s\n' "$ASSET_NAME" |
                    tr '[:upper:]' '[:lower:]'
            )"
            ASSET_DIGEST="$(
                plutil \
                    -extract "assets.${ASSET_INDEX}.digest" \
                    raw -o - "$RELEASE_JSON" 2>/dev/null || true
            )"
            ASSET_SHA256=""
            case "$ASSET_DIGEST" in
                sha256:*) ASSET_SHA256="${ASSET_DIGEST#sha256:}" ;;
            esac

            if [ "$DMG_COUNT" -eq 1 ]; then
                FIRST_DMG_URL="$ASSET_URL"
                FIRST_DMG_SHA256="$ASSET_SHA256"
            fi

            ASSET_ARCH=""
            case "$ASSET_NAME_LOWER" in
                *arm64*.dmg|*aarch64*.dmg)
                    ASSET_ARCH="arm64"
                    ;;
                *x64*.dmg|*x86_64*.dmg|*amd64*.dmg|*intel*.dmg)
                    ASSET_ARCH="x86_64"
                    ;;
                *)
                    UNIVERSAL_DMG_COUNT=$((UNIVERSAL_DMG_COUNT + 1))
                    UNIVERSAL_DMG_URL="$ASSET_URL"
                    UNIVERSAL_DMG_SHA256="$ASSET_SHA256"
                    ;;
            esac

            if [ "$ASSET_ARCH" = "$MACHINE_ARCH" ]; then
                ARCH_DMG_COUNT=$((ARCH_DMG_COUNT + 1))
                ARCH_DMG_URL="$ASSET_URL"
                ARCH_DMG_SHA256="$ASSET_SHA256"
            fi
            ;;
    esac

    ASSET_INDEX=$((ASSET_INDEX + 1))
done

if [ "$DMG_COUNT" -eq 1 ]; then
    DOWNLOAD_URL="$FIRST_DMG_URL"
    EXPECTED_SHA256="$FIRST_DMG_SHA256"
elif [ "$DMG_COUNT" -gt 1 ] && [ "$ARCH_DMG_COUNT" -eq 1 ]; then
    DOWNLOAD_URL="$ARCH_DMG_URL"
    EXPECTED_SHA256="$ARCH_DMG_SHA256"
    echo "🧭 检测到 ${MACHINE_ARCH}，选择 ${DOWNLOAD_URL##*/}"
elif [ "$DMG_COUNT" -gt 1 ] &&
    [ "$ARCH_DMG_COUNT" -eq 0 ] &&
    [ "$UNIVERSAL_DMG_COUNT" -eq 1 ]; then
    DOWNLOAD_URL="$UNIVERSAL_DMG_URL"
    EXPECTED_SHA256="$UNIVERSAL_DMG_SHA256"
    echo "🧭 未找到 ${MACHINE_ARCH} 专用包，选择通用 DMG：${DOWNLOAD_URL##*/}"
elif [ "$DMG_COUNT" -gt 1 ]; then
    echo "❌ 最新 Release 含 ${DMG_COUNT} 个 DMG，无法为 ${MACHINE_ARCH} 唯一选包"
    echo "   请检查：${RELEASE_PAGE}"
    exit 1
fi

if [ -z "$LATEST_TAG" ] || [ -z "$DOWNLOAD_URL" ]; then
    echo "❌ 最新 Release 中没有找到可安装的 DMG"
    echo "   请检查：${RELEASE_PAGE}"
    exit 1
fi

LATEST_VERSION="${LATEST_TAG#v}"

if [ "${MAC_AS_CODE_RESOLVE_ONLY:-0}" = "1" ]; then
    echo "✅ ${APP_NAME} ${LATEST_VERSION}：${DOWNLOAD_URL##*/}"
    exit 0
fi

CURRENT_VERSION=""
if [ -f "$APP_PATH/Contents/Info.plist" ]; then
    CURRENT_VERSION="$(
        /usr/libexec/PlistBuddy \
            -c "Print :CFBundleShortVersionString" \
            "$APP_PATH/Contents/Info.plist" 2>/dev/null || true
    )"
fi

if [ "$CURRENT_VERSION" = "$LATEST_VERSION" ]; then
    echo "✅ ${APP_NAME} ${CURRENT_VERSION} 已安装，当前就是最新版"
    exit 0
fi

if [ -n "$CURRENT_VERSION" ]; then
    echo "⬆️  ${APP_NAME} ${CURRENT_VERSION} → ${LATEST_VERSION}"
else
    echo "⬇️  准备安装 ${APP_NAME} ${LATEST_VERSION}"
fi

echo "⬇️  下载 ${DOWNLOAD_URL##*/}..."
if ! curl -fL \
    --retry 3 \
    --connect-timeout 15 \
    "$DOWNLOAD_URL" \
    -o "$DMG_PATH"; then
    echo "❌ ${APP_NAME} 安装包下载失败"
    exit 1
fi

if [ -n "$EXPECTED_SHA256" ]; then
    ACTUAL_SHA256="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
    if [ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]; then
        echo "❌ SHA-256 校验失败，停止安装"
        exit 1
    fi
    echo "✅ SHA-256 校验通过"
else
    echo "⚠️  GitHub Release 未提供 SHA-256，跳过文件校验"
fi

mkdir -p "$MOUNT_PATH"
echo "💿 挂载安装镜像..."
if ! hdiutil attach "$DMG_PATH" \
    -mountpoint "$MOUNT_PATH" \
    -nobrowse \
    -readonly \
    -quiet; then
    echo "❌ DMG 挂载失败"
    exit 1
fi
MOUNTED=1

SOURCE_APP=""
if [ -d "$MOUNT_PATH/${APP_NAME}.app" ]; then
    SOURCE_APP="$MOUNT_PATH/${APP_NAME}.app"
else
    for candidate in "$MOUNT_PATH"/*.app; do
        if [ -d "$candidate" ]; then
            if [ -n "$SOURCE_APP" ]; then
                echo "❌ DMG 中包含多个应用，无法自动确定安装目标"
                exit 1
            fi
            SOURCE_APP="$candidate"
        fi
    done
fi

if [ -z "$SOURCE_APP" ]; then
    echo "❌ DMG 中没有找到应用程序"
    exit 1
fi

if ! codesign --verify --deep --strict "$SOURCE_APP" >/dev/null 2>&1; then
    echo "❌ ${APP_NAME} 应用签名校验失败，停止安装"
    exit 1
fi
echo "✅ 应用签名校验通过"

echo "📦 安装 ${APP_NAME} 到 ${APP_PATH}..."
if ! ditto "$SOURCE_APP" "$APP_PATH"; then
    echo "❌ 无法写入 ${APP_PATH}"
    exit 1
fi

echo "✅ ${APP_NAME} ${LATEST_VERSION} 安装完成"
