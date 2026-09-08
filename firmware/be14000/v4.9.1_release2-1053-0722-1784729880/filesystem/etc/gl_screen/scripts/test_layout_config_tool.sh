#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
TOOL="$SCRIPT_DIR/layout_config_tool.lua"

if command -v lua >/dev/null 2>&1; then
    LUA_BIN="lua"
elif command -v lua5.4 >/dev/null 2>&1; then
    LUA_BIN="lua5.4"
elif command -v lua5.3 >/dev/null 2>&1; then
    LUA_BIN="lua5.3"
else
    echo "未找到 lua 解释器"
    exit 1
fi

TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT INT TERM

fail() {
    echo "[FAIL] $1"
    exit 1
}

assert_contains() {
    file_path="$1"
    text="$2"
    if ! grep -F "$text" "$file_path" >/dev/null 2>&1; then
        fail "未找到期望内容: $text"
    fi
}

assert_not_contains() {
    file_path="$1"
    text="$2"
    if grep -F "$text" "$file_path" >/dev/null 2>&1; then
        fail "出现了不期望内容: $text"
    fi
}

assert_file_equals() {
    file_path="$1"
    expected="$2"
    actual=$(cat "$file_path")
    if [ "$actual" != "$expected" ]; then
        echo "----- 实际内容 -----"
        cat "$file_path"
        echo "-------------------"
        fail "文件内容不符合预期: $file_path"
    fi
}

run_tool_in_case() {
    case_root="$1"
    shift
    (
        cd "$case_root"
        "$LUA_BIN" "$TOOL" "$@"
    )
}

make_case_one_tree() {
    root="$1"
    mkdir -p "$root/config/p1/dpr" "$root/config/p1/ndpr"
    mkdir -p "$root/config/s1/dpr" "$root/config/s1/ndpr"
    mkdir -p "$root/config/i1/dpr" "$root/config/i1/ndpr"
    mkdir -p "$root/main" "$root/boot"

    cat > "$root/config/p1/screen.mk" << 'EOF'
GL_USE_SCREEN := s1
EOF

    cat > "$root/config/s1/screen.mk" << 'EOF'
GL_USE_INCH := i1
EOF

    cat > "$root/config/i1/dpr/layout" << 'EOF'
// 注释行，不应当作为 key 参与检查
gap_keep 10
sort_b 2
sort_a 1
unused_drop 1
used_keep 11
EOF

    cat > "$root/config/s1/dpr/layout" << 'EOF'
unused_drop 2
used_keep 22
EOF

    cat > "$root/config/p1/dpr/layout" << 'EOF'
gap_keep 30
unused_drop 3
used_keep 33
EOF

    cat > "$root/config/i1/ndpr/layout" << 'EOF'
ndpr_unused_drop 1
EOF

    cat > "$root/config/s1/ndpr/layout" << 'EOF'
ndpr_gap_keep 20
ndpr_unused_drop 2
EOF

    cat > "$root/config/p1/ndpr/layout" << 'EOF'
ndpr_unused_drop 3
EOF

    cat > "$root/main/used_key.c" << 'EOF'
const char *k1 = "used_keep";
const char *k2 = "gap_keep";
const char *k3 = "sort_a";
const char *k4 = "sort_b";
const char *k5 = "ndpr_gap_keep";
EOF

    cat > "$root/boot/used_key.c" << 'EOF'
const char *boot = "boot_only_key";
EOF
}

run_case_one() {
    case_root="$TMP_ROOT/case_one"
    make_case_one_tree "$case_root"

    check_before_out="$case_root/check_before.log"
    if run_tool_in_case "$case_root" check "$case_root/config" > "$check_before_out" 2>&1; then
        fail "check 阶段应检测到问题并返回非 0"
    fi

    assert_contains "$check_before_out" "type=GAP"
    assert_contains "$check_before_out" "type=UNUSED_KEY"
    assert_not_contains "$check_before_out" "key=//"

    fix_out="$case_root/fix.log"
    run_tool_in_case "$case_root" fix "$case_root/config" > "$fix_out" 2>&1
    assert_contains "$fix_out" "changed_files="

    check_after_out="$case_root/check_after.log"
    run_tool_in_case "$case_root" check "$case_root/config" > "$check_after_out" 2>&1
    assert_contains "$check_after_out" "SUMMARY real_issues=0"

    assert_file_equals "$case_root/config/i1/dpr/layout" "gap_keep 10
sort_a 1
sort_b 2
used_keep 11"

    assert_file_equals "$case_root/config/s1/dpr/layout" "gap_keep 30
used_keep 22"

    assert_file_equals "$case_root/config/p1/dpr/layout" "used_keep 33"

    assert_file_equals "$case_root/config/i1/ndpr/layout" "ndpr_gap_keep 20"

    assert_file_equals "$case_root/config/s1/ndpr/layout" ""
    assert_file_equals "$case_root/config/p1/ndpr/layout" ""

    assert_not_contains "$case_root/config/i1/dpr/layout" "unused_drop"
    assert_not_contains "$case_root/config/i1/ndpr/layout" "ndpr_unused_drop"
}

make_case_two_tree() {
    root="$1"
    mkdir -p "$root/config/p2/dpr" "$root/config/p2/ndpr"
    mkdir -p "$root/config/s2/dpr" "$root/config/s2/ndpr"
    mkdir -p "$root/config/i2/dpr" "$root/config/i2/ndpr"
    mkdir -p "$root/main"

    cat > "$root/config/p2/screen.mk" << 'EOF'
GL_USE_SCREEN := s2
EOF

    cat > "$root/config/s2/screen.mk" << 'EOF'
GL_USE_INCH := i2
EOF

    cat > "$root/config/i2/dpr/layout" << 'EOF'
only_unused 1
EOF

    cat > "$root/config/s2/dpr/layout" << 'EOF'
only_unused 2
EOF

    cat > "$root/config/p2/dpr/layout" << 'EOF'
only_unused 3
EOF

    cat > "$root/main/source_only.c" << 'EOF'
const char *source_only = "exists_but_boot_missing";
EOF
}

run_case_two() {
    case_root="$TMP_ROOT/case_two"
    make_case_two_tree "$case_root"

    out="$case_root/check.log"
    run_tool_in_case "$case_root" check "$case_root/config" > "$out" 2>&1

    assert_contains "$out" "type=SKIP_SOURCE_CHECK"
    assert_not_contains "$out" "type=UNUSED_KEY"
    assert_contains "$out" "SUMMARY real_issues=0"
}

run_case_three() {
    case_root="$TMP_ROOT/case_three"
    make_case_one_tree "$case_root"

    out="$case_root/default_mode.log"
    (
        cd "$case_root"
        if "$LUA_BIN" "$TOOL" check > "$out" 2>&1; then
            fail "默认目录 check 应返回非 0"
        fi
    )

    assert_contains "$out" "type=GAP"
}

run_case_four() {
    case_root="$TMP_ROOT/case_four"
    make_case_one_tree "$case_root"

    run_tool_in_case "$case_root" fix "$case_root/config" >/dev/null 2>&1

    before_hash=$(find "$case_root/config" -type f -name layout -print0 | sort -z | xargs -0 cat | cksum)
    run_tool_in_case "$case_root" fix "$case_root/config" >/dev/null 2>&1
    after_hash=$(find "$case_root/config" -type f -name layout -print0 | sort -z | xargs -0 cat | cksum)

    if [ "$before_hash" != "$after_hash" ]; then
        fail "fix 二次执行应无额外变更"
    fi
}

make_case_five_tree() {
    root="$1"
    mkdir -p "$root/config/p3/dpr" "$root/config/p3/ndpr"
    mkdir -p "$root/config/s3/dpr" "$root/config/s3/ndpr"
    mkdir -p "$root/config/r3/dpr" "$root/config/r3/ndpr"

    cat > "$root/config/p3/screen.mk" << 'EOF'
GL_USE_SCREEN := s3
EOF

    cat > "$root/config/s3/screen.mk" << 'EOF'
GL_USE_REFERENCE := r3
EOF

    cat > "$root/config/r3/dpr/layout" << 'EOF'
ref_keep 1
EOF
}

run_case_five() {
    case_root="$TMP_ROOT/case_five"
    make_case_five_tree "$case_root"

    out="$case_root/check.log"
    run_tool_in_case "$case_root" check "$case_root/config" > "$out" 2>&1

    assert_contains "$out" "PRODUCT p3 CHAIN r3->s3->p3"
    assert_contains "$out" "type=SKIP_SOURCE_CHECK"
    assert_contains "$out" "SUMMARY real_issues=0"
}

make_case_six_tree() {
    root="$1"
    mkdir -p "$root/config/p4/dpr" "$root/config/p4/ndpr"
    mkdir -p "$root/config/s4/dpr" "$root/config/s4/ndpr"
    mkdir -p "$root/config/i4/dpr" "$root/config/i4/ndpr"
    mkdir -p "$root/config/r4/dpr" "$root/config/r4/ndpr"

    cat > "$root/config/p4/screen.mk" << 'EOF'
GL_USE_SCREEN := s4
EOF

    cat > "$root/config/s4/screen.mk" << 'EOF'
GL_USE_INCH := i4
GL_USE_REFERENCE := r4
EOF
}

run_case_six() {
    case_root="$TMP_ROOT/case_six"
    make_case_six_tree "$case_root"

    out="$case_root/check.log"
    if run_tool_in_case "$case_root" check "$case_root/config" > "$out" 2>&1; then
        fail "存在多 GL_USE_ 冲突时 check 应返回非 0"
    fi

    assert_contains "$out" "type=CHAIN_INVALID"
    assert_contains "$out" "action=NEXT_LAYER_CONFLICT"
}

make_case_seven_tree() {
    root="$1"
    mkdir -p "$root/config/p5/dpr" "$root/config/p5/ndpr"
    mkdir -p "$root/config/s5/dpr" "$root/config/s5/ndpr"
    mkdir -p "$root/config/r5/dpr" "$root/config/r5/ndpr"

    cat > "$root/config/p5/screen.mk" << 'EOF'
GL_USE_SCREEN := s5
EOF

    cat > "$root/config/s5/screen.mk" << 'EOF'
GL_USE_INCH := r5
GL_USE_REFERENCE := r5
EOF

    cat > "$root/config/r5/dpr/layout" << 'EOF'
same_target_keep 1
EOF
}

run_case_seven() {
    case_root="$TMP_ROOT/case_seven"
    make_case_seven_tree "$case_root"

    out="$case_root/check.log"
    run_tool_in_case "$case_root" check "$case_root/config" > "$out" 2>&1

    assert_contains "$out" "PRODUCT p5 CHAIN r5->s5->p5"
    assert_not_contains "$out" "type=CHAIN_INVALID"
    assert_contains "$out" "SUMMARY real_issues=0"
}

make_case_eight_tree() {
    root="$1"
    mkdir -p "$root/config/p6/dpr" "$root/config/p6/ndpr"
    mkdir -p "$root/config/s6/dpr" "$root/config/s6/ndpr"
    mkdir -p "$root/main" "$root/boot"

    cat > "$root/config/p6/screen.mk" << 'EOF'
GL_USE_SCREEN := s6
EOF

    cat > "$root/config/s6/dpr/layout" << 'EOF'
HOME_LABEL_TEXT "text_ok"
HOME_LABEL_FONT "font_ok"
HOME_LABEL_SIZE 16
OTHER_LABEL_TEXT "text_drop"
OTHER_LABEL_FONT "font_drop"
OTHER_LABEL_SIZE 14
EOF

    cat > "$root/main/source_key.c" << 'EOF'
const char *source_key = "HOME";
EOF

    cat > "$root/boot/source_key.c" << 'EOF'
const char *boot_key = "BOOT_ONLY";
EOF
}

run_case_eight() {
    case_root="$TMP_ROOT/case_eight"
    make_case_eight_tree "$case_root"

    check_out="$case_root/check.log"
    if run_tool_in_case "$case_root" check "$case_root/config" > "$check_out" 2>&1; then
        fail "仅 _LABEL_SIZE/_LABEL_FONT 允许跳过，_LABEL_TEXT 应触发 UNUSED_KEY 并返回非 0"
    fi

    assert_not_contains "$check_out" "key=HOME_LABEL_FONT type=UNUSED_KEY"
    assert_not_contains "$check_out" "key=OTHER_LABEL_FONT type=UNUSED_KEY"
    assert_not_contains "$check_out" "key=HOME_LABEL_SIZE type=UNUSED_KEY"
    assert_not_contains "$check_out" "key=OTHER_LABEL_SIZE type=UNUSED_KEY"
    assert_contains "$check_out" "key=HOME_LABEL_TEXT type=UNUSED_KEY"
    assert_contains "$check_out" "key=OTHER_LABEL_TEXT type=UNUSED_KEY"

    run_tool_in_case "$case_root" fix "$case_root/config" >/dev/null 2>&1

    assert_file_equals "$case_root/config/s6/dpr/layout" "HOME_LABEL_FONT \"font_ok\"
HOME_LABEL_SIZE 16
OTHER_LABEL_FONT \"font_drop\"
OTHER_LABEL_SIZE 14"
}

run_case_one
run_case_two
run_case_three
run_case_four
run_case_five
run_case_six
run_case_seven
run_case_eight

echo "[PASS] test_layout_config_tool.sh"
