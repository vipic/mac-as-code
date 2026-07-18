#!/bin/sh
# 检查用户编写的 config 是否符合约定格式（不执行装机）。
# 用法：
#   sh scripts/check_format.sh              # 查仓库 config
#   sh scripts/check_format.sh --self-test  # 用固定件验证本脚本 + 再查仓库 config
set -u

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"
SELF="$SCRIPTS_DIR/check_format.sh"
FIXTURES="$ROOT_DIR/tests/fixtures"
FAILED=0
CHECKED=0
VERBOSE="${VERBOSE:-0}"

usage() {
    cat <<'EOF'
用法：sh scripts/check_format.sh [路径...]
      sh scripts/check_format.sh --self-test
      bash scripts/check_format.sh 亦可

检查 defaults / dock 注解项、plugins 与 Brewfile 格式。无参数时检查：
  config/defaults_config.sh
  config/defaults_dock.sh
  config/plugins/*.sh
  config/Brewfile

  --self-test   用 tests/fixtures 验证本脚本（改 check_format 时用）
                固定件故意错误默认不打印；VERBOSE=1 可展开
  -v, --verbose 与 --self-test 联用，打印固定件检查详情

注解项格式（defaults / dock）：
  # my-setting | 这一项的说明（多选里显示）
  defaults write NSGlobalDomain SomeKey -int 1

插件（config/plugins/<id>.sh）文件头：
  # <id> | 说明（id 须与文件名一致）

Brewfile 启用行仅支持：
  brew "name"
  cask "name"
  mas "Name", id: 123456789
EOF
}

pass() {
    echo "  ✅ $1"
}

fail() {
    echo "  ❌ $1"
    FAILED=1
}

section() {
    echo
    echo "==> $1"
}

# 检查 defaults / dock 注解脚本
check_annotated_shell() {
    file="$1"
    label="${2:-$file}"
    errors="$(mktemp -t mac-as-code-fmt.XXXXXX)"
    counts=""

    section "注解项：$label"
    CHECKED=$((CHECKED + 1))

    if [ ! -f "$file" ]; then
        fail "文件不存在：$file"
        rm -f "$errors"
        return 1
    fi

    # shell 语法（文件前半 runner + 注解体整体需可解析；exit 后语句仍参与 -n）
    if ! sh -n "$file" 2>"$errors"; then
        fail "shell 语法错误（sh -n）"
        sed 's/^/     /' "$errors"
    else
        pass "shell 语法（sh -n）"
    fi

    counts="$(
        awk -v errfile="$errors" '
            BEGIN {
                item_count = 0
                err_count = 0
                first_item_line = 0
            }
            function trim(s) {
                sub(/^[[:space:]]+/, "", s)
                sub(/[[:space:]]+$/, "", s)
                return s
            }
            function emit(msg) {
                err_count++
                print msg >> errfile
            }
            function flush_item() {
                if (cur_id == "") return
                if (body_lines == 0) {
                    emit(sprintf("第 %d 行：项「%s」缺少命令体（注解头后至少一行可执行命令）", cur_line, cur_id))
                }
                cur_id = ""
                cur_label = ""
                body_lines = 0
            }
            {
                line = $0
                # 合法项头：# id | 说明
                if (match(line, /^#[[:space:]]*[A-Za-z0-9_-]+[[:space:]]*\|/)) {
                    flush_item()
                    raw = line
                    sub(/^#[[:space:]]*/, "", raw)
                    id = raw
                    sub(/[[:space:]]*\|.*/, "", id)
                    label = raw
                    sub(/^[^|]*\|[[:space:]]*/, "", label)
                    label = trim(label)
                    if (id == "") {
                        emit(sprintf("第 %d 行：项 id 为空", NR))
                        next
                    }
                    if (label == "") {
                        emit(sprintf("第 %d 行：项「%s」说明为空（| 后需要说明文字）", NR, id))
                        next
                    }
                    if (seen[id]++) {
                        emit(sprintf("第 %d 行：项 id「%s」重复（先前出现过）", NR, id))
                    }
                    if (first_item_line == 0) first_item_line = NR
                    cur_id = id
                    cur_label = label
                    cur_line = NR
                    body_lines = 0
                    item_count++
                    next
                }
                # 疑似项头但格式不对（方便发现写错）
                if (match(line, /^#[[:space:]]*[A-Za-z0-9_-]+[[:space:]]*(\||:|-)/) \
                    || match(line, /^#[[:space:]]*[A-Za-z0-9_-]+[[:space:]]+[^|].*\|/)) {
                    # 已由合法分支处理的不再告警
                    if (!match(line, /^#[[:space:]]*[A-Za-z0-9_-]+[[:space:]]*\|/)) {
                        emit(sprintf("第 %d 行：疑似项头格式不对，应为「# id | 说明」：%s", NR, line))
                    }
                } else if (match(line, /^#[[:space:]]*[a-z][A-Za-z0-9_-]*[[:space:]]*\|/)) {
                    # id 以小写开头但含非法字符时上面可能漏掉；再兜一层
                    if (!match(line, /^#[[:space:]]*[A-Za-z0-9_-]+[[:space:]]*\|/)) {
                        emit(sprintf("第 %d 行：项 id 只能含字母、数字、_、-：%s", NR, line))
                    }
                }
                if (cur_id != "") {
                    body = line
                    # 去掉行尾注释后的纯空白不算命令；整行 # 普通注释可保留在项内
                    if (match(body, /^[[:space:]]*#/)) {
                        next
                    }
                    sub(/[[:space:]]+#.*$/, "", body)
                    body = trim(body)
                    if (body != "") body_lines++
                }
            }
            END {
                flush_item()
                if (item_count == 0) {
                    emit("未找到任何注解项（需要至少一项「# id | 说明」）")
                }
                printf "%d %d %d\n", item_count, err_count, first_item_line
            }
        ' "$file"
    )"

    item_count="$(printf '%s' "$counts" | awk '{ print $1 }')"
    err_count="$(printf '%s' "$counts" | awk '{ print $2 }')"
    first_item_line="$(printf '%s' "$counts" | awk '{ print $3 }')"

    if [ "${err_count:-0}" -gt 0 ]; then
        fail "注解项格式：发现 ${err_count} 处问题（共解析 ${item_count} 项）"
        sed 's/^/     /' "$errors"
    else
        pass "注解项格式：${item_count} 项（自第 ${first_item_line} 行起）"
    fi

    # 逐项抽出命令体做 sh -n，避免写坏的多行命令进多选后才爆
    body_err=0
    if [ "${item_count:-0}" -gt 0 ]; then
        body_dir="$(mktemp -d -t mac-as-code-bodies.XXXXXX)"
        awk -v outdir="$body_dir" '
            /^#[[:space:]]*[A-Za-z0-9_-]+[[:space:]]*\|/ {
                if (cur != "") close(cur)
                line = $0
                sub(/^#[[:space:]]*/, "", line)
                id = line
                sub(/[[:space:]]*\|.*/, "", id)
                gsub(/[^A-Za-z0-9_-]/, "_", id)
                cur = outdir "/" id ".sh"
                print "#!/bin/sh" > cur
                next
            }
            cur { print >> cur }
        ' "$file"
        for body in "$body_dir"/*.sh; do
            [ -f "$body" ] || continue
            id="$(basename "$body" .sh)"
            if ! sh -n "$body" 2>"$errors"; then
                body_err=$((body_err + 1))
                fail "项「${id}」命令体 shell 语法错误"
                sed 's/^/     /' "$errors"
            fi
        done
        rm -rf "$body_dir"
        if [ "$body_err" -eq 0 ]; then
            pass "各注解项命令体 shell 语法"
        fi
    fi

    rm -f "$errors"
}

# 检查 Brewfile
check_brewfile() {
    file="$1"
    label="${2:-$file}"
    errors="$(mktemp -t mac-as-code-brew.XXXXXX)"
    counts=""

    section "Brewfile：$label"
    CHECKED=$((CHECKED + 1))

    if [ ! -f "$file" ]; then
        fail "文件不存在：$file"
        rm -f "$errors"
        return 1
    fi

    counts="$(
        awk -v errfile="$errors" '
            BEGIN { active = 0; err_count = 0 }
            function trim(s) {
                sub(/^[[:space:]]+/, "", s)
                sub(/[[:space:]]+$/, "", s)
                return s
            }
            function emit(msg) {
                err_count++
                print msg >> errfile
            }
            {
                raw = $0
                line = $0
                # 去掉注释
                sub(/[[:space:]]*#.*$/, "", line)
                line = trim(line)
                if (line == "") next
                active++
                if (match(line, /^brew[[:space:]]+"/)) {
                    name = line
                    sub(/^brew[[:space:]]+"/, "", name)
                    if (match(name, /^"/)) {
                        emit(sprintf("第 %d 行：brew 名称为空", NR))
                        next
                    }
                    if (!match(name, /^[^"]+"/)) {
                        emit(sprintf("第 %d 行：brew 名称缺少闭合引号：%s", NR, raw))
                        next
                    }
                    sub(/".*/, "", name)
                    rest = line
                    sub(/^brew[[:space:]]+"[^"]+"/, "", rest)
                    rest = trim(rest)
                    if (rest != "") emit(sprintf("第 %d 行：brew 行多余内容：%s", NR, raw))
                    next
                }
                if (match(line, /^cask[[:space:]]+"/)) {
                    name = line
                    sub(/^cask[[:space:]]+"/, "", name)
                    if (match(name, /^"/)) {
                        emit(sprintf("第 %d 行：cask 名称为空", NR))
                        next
                    }
                    if (!match(name, /^[^"]+"/)) {
                        emit(sprintf("第 %d 行：cask 名称缺少闭合引号：%s", NR, raw))
                        next
                    }
                    sub(/".*/, "", name)
                    rest = line
                    sub(/^cask[[:space:]]+"[^"]+"/, "", rest)
                    rest = trim(rest)
                    if (rest != "") emit(sprintf("第 %d 行：cask 行多余内容：%s", NR, raw))
                    next
                }
                if (match(line, /^mas[[:space:]]+"/)) {
                    name = line
                    sub(/^mas[[:space:]]+"/, "", name)
                    if (match(name, /^"/)) {
                        emit(sprintf("第 %d 行：mas 名称为空", NR))
                        next
                    }
                    if (!match(name, /^[^"]+"/)) {
                        emit(sprintf("第 %d 行：mas 名称缺少闭合引号：%s", NR, raw))
                        next
                    }
                    sub(/".*/, "", name)
                    if (!match(line, /id:[[:space:]]*[0-9][0-9]*/)) {
                        emit(sprintf("第 %d 行：mas 缺少「id: 数字」：%s", NR, raw))
                    }
                    next
                }
                emit(sprintf("第 %d 行：无法识别（仅支持 brew / cask / mas）：%s", NR, raw))
            }
            END {
                if (active == 0) emit("没有启用的 brew/cask/mas 行（可能全被注释）")
                printf "%d %d\n", active, err_count
            }
        ' "$file"
    )"

    active="$(printf '%s' "$counts" | awk '{ print $1 }')"
    err_count="$(printf '%s' "$counts" | awk '{ print $2 }')"

    if [ "${err_count:-0}" -gt 0 ]; then
        fail "Brewfile 格式：发现 ${err_count} 处问题（启用行 ${active}）"
        sed 's/^/     /' "$errors"
    else
        pass "Brewfile 格式：${active} 条启用项"
    fi

    rm -f "$errors"
}

# 插件脚本：文件名即 id，须有匹配的「# id | 说明」头
check_plugin_script() {
    file="$1"
    label="${2:-$file}"
    id=""
    meta_id=""
    meta_label=""
    header_count=0
    errors="$(mktemp -t mac-as-code-plugin.XXXXXX)"

    section "插件：${label}"
    CHECKED=$((CHECKED + 1))

    if [ ! -f "$file" ]; then
        fail "文件不存在：${file}"
        rm -f "$errors"
        return 1
    fi

    id="$(basename "$file" .sh)"

    if ! sh -n "$file" 2>"$errors"; then
        fail "shell 语法错误（sh -n）"
        sed 's/^/     /' "$errors"
    else
        pass "shell 语法（sh -n）"
    fi

    header_count="$(
        awk '
            /^#[[:space:]]*[A-Za-z0-9_-]+[[:space:]]*\|/ { c++ }
            END { print c + 0 }
        ' "$file"
    )"

    if [ "$header_count" -eq 0 ]; then
        fail "缺少插件头「# ${id} | 说明」"
    else
        meta_id="$(
            awk '
                /^#[[:space:]]*[A-Za-z0-9_-]+[[:space:]]*\|/ {
                    line = $0
                    sub(/^#[[:space:]]*/, "", line)
                    id = line
                    sub(/[[:space:]]*\|.*/, "", id)
                    print id
                    exit
                }
            ' "$file"
        )"
        meta_label="$(
            awk '
                /^#[[:space:]]*[A-Za-z0-9_-]+[[:space:]]*\|/ {
                    line = $0
                    sub(/^#[[:space:]]*/, "", line)
                    sub(/^[^|]*\|[[:space:]]*/, "", line)
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
                    print line
                    exit
                }
            ' "$file"
        )"
        if [ "$meta_id" != "$id" ]; then
            fail "项头 id「${meta_id}」与文件名「${id}」不一致"
        elif [ -z "$meta_label" ]; then
            fail "项头说明为空"
        else
            pass "插件头：${meta_id} | ${meta_label}"
        fi
        if [ "$header_count" -gt 1 ]; then
            fail "插件文件应只有一个「# id | 说明」头（当前 ${header_count} 个）"
        fi
    fi

    rm -f "$errors"
}

check_path() {
    path="$1"
    base="$(basename "$path")"
    case "$path" in
        */plugins/*.sh)
            check_plugin_script "$path"
            return 0
            ;;
    esac
    case "$base" in
        Brewfile|*Brewfile*|*.brewfile)
            check_brewfile "$path"
            ;;
        *.sh)
            # 含注解项头则按注解检查，否则只做 sh -n
            if grep -q '^#[[:space:]]*[A-Za-z0-9_-]\{1,\}[[:space:]]*|' "$path" 2>/dev/null; then
                check_annotated_shell "$path"
            else
                section "shell：$path"
                CHECKED=$((CHECKED + 1))
                if sh -n "$path" 2>/dev/null; then
                    pass "shell 语法（sh -n）"
                else
                    fail "shell 语法错误（sh -n）"
                    sh -n "$path" 2>&1 | sed 's/^/     /' || true
                fi
            fi
            ;;
        *)
            section "跳过：$path"
            echo "  ℹ️  无法识别文件类型，跳过"
            FAILED=1
            ;;
    esac
}

# 自测：子进程跑本脚本，只核对退出码（固定件故意错误默认不展示）
assert_exit() {
    case_name="$1"
    expect="$2"
    shift 2
    out="$(mktemp -t mac-as-code-selftest.XXXXXX)"
    RAN=$((RAN + 1))

    set +e
    "$@" >"$out" 2>&1
    status=$?
    set +e

    if [ "$status" -eq "$expect" ]; then
        echo "✅ PASS: ${case_name}"
        if [ "$VERBOSE" = "1" ]; then
            sed 's/^/   /' "$out"
        fi
    else
        echo "❌ FAIL: ${case_name} (expect exit ${expect}, actual ${status})"
        sed 's/^/   /' "$out"
        SELF_FAILED=1
    fi
    rm -f "$out"
}

run_self_test() {
    RAN=0
    SELF_FAILED=0

    if [ ! -d "$FIXTURES" ]; then
        echo "❌ 找不到固定件目录：${FIXTURES}"
        exit 1
    fi

    echo "🧪 自测 check_format（固定件）..."
    assert_exit "fixtures/good_defaults.sh" 0 sh "$SELF" "$FIXTURES/good_defaults.sh"
    assert_exit "fixtures/bad_defaults.sh" 1 sh "$SELF" "$FIXTURES/bad_defaults.sh"
    assert_exit "fixtures/good_Brewfile" 0 sh "$SELF" "$FIXTURES/good_Brewfile"
    assert_exit "fixtures/bad_Brewfile" 1 sh "$SELF" "$FIXTURES/bad_Brewfile"

    echo
    echo "🔍 再检查仓库 config..."
    set +e
    sh "$SELF"
    status=$?
    set +e
    RAN=$((RAN + 1))
    if [ "$status" -eq 0 ]; then
        echo "✅ PASS: repo config"
    else
        echo "❌ FAIL: repo config"
        SELF_FAILED=1
    fi

    echo
    echo "================ 自测汇总 ================"
    if [ "$SELF_FAILED" -ne 0 ]; then
        echo "❌ 自测未通过（共 ${RAN} 组）"
        exit 1
    fi
    echo "✅ 自测通过（共 ${RAN} 组）"
    exit 0
}

# ---------- main ----------

SELF_TEST=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        --self-test)
            SELF_TEST=1
            shift
            ;;
        -v|--verbose)
            VERBOSE=1
            shift
            ;;
        --)
            shift
            break
            ;;
        -*)
            echo "❌ 未知参数：$1"
            usage
            exit 1
            ;;
        *)
            break
            ;;
    esac
done

if [ "$SELF_TEST" = "1" ]; then
    if [ "$#" -gt 0 ]; then
        echo "❌ --self-test 不能与路径参数同用"
        exit 1
    fi
    run_self_test
fi

echo "🔍 检查配置格式..."

if [ "$#" -eq 0 ]; then
    check_annotated_shell "$ROOT_DIR/config/defaults_config.sh" "config/defaults_config.sh"
    check_annotated_shell "$ROOT_DIR/config/defaults_dock.sh" "config/defaults_dock.sh"
    if [ -d "$ROOT_DIR/config/plugins" ]; then
        for plugin in "$ROOT_DIR/config/plugins"/*.sh; do
            [ -f "$plugin" ] || continue
            check_plugin_script "$plugin" "config/plugins/$(basename "$plugin")"
        done
    fi
    check_brewfile "$ROOT_DIR/config/Brewfile" "config/Brewfile"
else
    for path in "$@"; do
        check_path "$path"
    done
fi

echo
if [ "$FAILED" -ne 0 ]; then
    echo "❌ 格式检查未通过（已检查 ${CHECKED} 个文件）"
    exit 1
fi
echo "✅ 格式检查通过（已检查 ${CHECKED} 个文件）"
exit 0
