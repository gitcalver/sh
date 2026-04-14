#!/bin/sh
# Copyright © 2026 Michael Shields
# SPDX-License-Identifier: MIT

set -eu

# Override this to test other implementations, such as the Go version.
GITCALVER="${GITCALVER:-$(cd "$(dirname "$0")/.." && pwd)/gitcalver.sh}"

PASS=0
FAIL=0
TOTAL=0

# Portable color output
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != "dumb" ]; then
    GREEN='\033[0;32m'
    RED='\033[0;31m'
    RESET='\033[0m'
else
    GREEN=''
    RED=''
    RESET=''
fi

pass() {
    PASS=$((PASS + 1))
    TOTAL=$((TOTAL + 1))
    printf "${GREEN}PASS${RESET} %s\n" "$1"
}

fail() {
    FAIL=$((FAIL + 1))
    TOTAL=$((TOTAL + 1))
    printf "${RED}FAIL${RESET} %s: expected %s, got %s\n" "$1" "$2" "$3"
}

assert_output() {
    test_name="$1"
    expected="$2"
    shift 2
    actual=$("$@" 2>/dev/null) || actual="EXIT:$?"
    if [ "$actual" = "$expected" ]; then
        pass "$test_name"
    else
        fail "$test_name" "$expected" "$actual"
    fi
}

assert_exit() {
    test_name="$1"
    expected_code="$2"
    shift 2
    set +e
    "$@" >/dev/null 2>&1
    actual_code=$?
    set -e
    if [ "$actual_code" -eq "$expected_code" ]; then
        pass "$test_name"
    else
        fail "$test_name" "exit $expected_code" "exit $actual_code"
    fi
}

assert_match() {
    test_name="$1"
    pattern="$2"
    shift 2
    actual=$("$@" 2>/dev/null) || actual="EXIT:$?"
    if echo "$actual" | grep -qE "$pattern"; then
        pass "$test_name"
    else
        fail "$test_name" "match /$pattern/" "$actual"
    fi
}

# Create a temporary directory for test repos
TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Helper: create a fresh git repo and cd into it
new_repo() {
    local dir="$TMPDIR_BASE/$1"
    mkdir -p "$dir"
    cd "$dir"
    git init -b main --quiet
    git config user.email "test@test.com"
    git config user.name "Test"
}

# Helper: commit with a specific UTC committer date
# Usage: commit_at "2026-04-10T09:00:00Z" "message"
commit_at() {
    local date="$1"
    local msg="${2:-commit}"
    GIT_COMMITTER_DATE="$date" git commit --allow-empty -m "$msg" --quiet \
        --date="$date"
}

# Helper: commit with a specific committer date but different author date
# Usage: commit_at_split "2026-04-10T09:00:00Z" "2026-04-09T09:00:00Z" "msg"
commit_at_split() {
    local committer_date="$1"
    local author_date="$2"
    local msg="${3:-commit}"
    GIT_COMMITTER_DATE="$committer_date" git commit --allow-empty -m "$msg" \
        --quiet --date="$author_date"
}

echo "=== gitcalver test suite ==="
echo ""

# ---- Basic version computation ----

new_repo "single_commit"
commit_at "2026-04-10T09:00:00Z"
assert_output "single commit" "20260410.1" \
    "$GITCALVER"

new_repo "three_commits_same_day"
commit_at "2026-04-10T09:00:00Z" "first"
commit_at "2026-04-10T12:00:00Z" "second"
commit_at "2026-04-10T15:00:00Z" "third"
assert_output "multiple commits same day" "20260410.3" \
    "$GITCALVER"

new_repo "commits_across_days"
commit_at "2026-04-10T09:00:00Z" "day1-a"
commit_at "2026-04-10T12:00:00Z" "day1-b"
commit_at "2026-04-11T09:00:00Z" "day2-a"
assert_output "commits across days" "20260411.1" \
    "$GITCALVER"

new_repo "day_rollover"
commit_at "2026-04-10T09:00:00Z" "day1-a"
commit_at "2026-04-10T12:00:00Z" "day1-b"
commit_at "2026-04-10T15:00:00Z" "day1-c"
commit_at "2026-04-11T08:00:00Z" "day2-a"
commit_at "2026-04-11T10:00:00Z" "day2-b"
assert_output "day rollover resets N" "20260411.2" \
    "$GITCALVER"

# ---- Prefix ----

new_repo "prefix_semver"
commit_at "2026-04-10T09:00:00Z"
commit_at "2026-04-10T14:00:00Z"
assert_output "prefix 0." "0.20260410.2" \
    "$GITCALVER" --prefix "0."

new_repo "prefix_go"
commit_at "2026-04-10T09:00:00Z"
assert_output "prefix v0." "v0.20260410.1" \
    "$GITCALVER" --prefix "v0."

# ---- Dirty workspace ----

new_repo "dirty_staged"
commit_at "2026-04-10T09:00:00Z"
echo "new" >file.txt
git add file.txt
assert_exit "dirty: staged changes" 2 \
    "$GITCALVER"

new_repo "dirty_unstaged"
commit_at "2026-04-10T09:00:00Z"
echo "tracked" >file.txt
git add file.txt
GIT_COMMITTER_DATE="2026-04-10T09:01:00Z" git commit -m "add file" --quiet \
    --date="2026-04-10T09:01:00Z"
echo "modified" >file.txt
assert_exit "dirty: unstaged changes" 2 \
    "$GITCALVER"

new_repo "dirty_untracked"
commit_at "2026-04-10T09:00:00Z"
echo "new" >untracked.txt
assert_exit "dirty: untracked non-ignored file" 2 \
    "$GITCALVER"

new_repo "clean_gitignored"
commit_at "2026-04-10T09:00:00Z"
echo "ignored.txt" >.gitignore
git add .gitignore
GIT_COMMITTER_DATE="2026-04-10T09:01:00Z" git commit -m "add gitignore" \
    --quiet --date="2026-04-10T09:01:00Z"
echo "this is ignored" >ignored.txt
assert_output "clean: gitignored file" "20260410.2" \
    "$GITCALVER"

new_repo "dirty_default"
commit_at "2026-04-10T09:00:00Z"
echo "new" >untracked.txt
assert_match "dirty -dirty" "^20260410\.1-dirty\." \
    "$GITCALVER" --dirty "-dirty"

new_repo "dirty_with_prefix"
commit_at "2026-04-10T09:00:00Z"
echo "new" >untracked.txt
assert_match "dirty with prefix 0." "^0\.20260410\.1-dirty\." \
    "$GITCALVER" --prefix "0." --dirty "-dirty"

new_repo "dirty_plus"
commit_at "2026-04-10T09:00:00Z"
echo "new" >untracked.txt
assert_match "dirty +dirty" "^20260410\.1\+dirty\." \
    "$GITCALVER" --dirty "+dirty"

new_repo "dirty_go_prefix"
commit_at "2026-04-10T09:00:00Z"
echo "new" >untracked.txt
assert_match "dirty with prefix v0." "^v0\.20260410\.1-dirty\." \
    "$GITCALVER" --prefix "v0." --dirty "-dirty"

new_repo "dirty_no_hash"
commit_at "2026-04-10T09:00:00Z"
echo "new" >untracked.txt
assert_output "dirty ~dirty no hash" "20260410.1~dirty" \
    "$GITCALVER" --dirty "~dirty" --no-dirty-hash

new_repo "dirty_snapshot"
commit_at "2026-04-10T09:00:00Z"
echo "new" >untracked.txt
assert_output "dirty -SNAPSHOT no hash" "20260410.1-SNAPSHOT" \
    "$GITCALVER" --dirty "-SNAPSHOT" --no-dirty-hash

new_repo "dirty_pre"
commit_at "2026-04-10T09:00:00Z"
echo "new" >untracked.txt
assert_match "dirty .pre.dirty" "^20260410\.1\.pre\.dirty\." \
    "$GITCALVER" --dirty ".pre.dirty"

new_repo "dirty_flag_clean_workspace"
commit_at "2026-04-10T09:00:00Z"
assert_output "--dirty on clean workspace" "20260410.1" \
    "$GITCALVER" --dirty "-dirty"

# ---- Flag validation ----

new_repo "dirty_empty_string"
commit_at "2026-04-10T09:00:00Z"
assert_exit "--dirty empty string" 1 \
    "$GITCALVER" --dirty ""

new_repo "no_dirty_hash_without_dirty"
commit_at "2026-04-10T09:00:00Z"
assert_exit "--no-dirty-hash without --dirty" 1 \
    "$GITCALVER" --no-dirty-hash

new_repo "no_dirty_overrides_dirty"
commit_at "2026-04-10T09:00:00Z"
echo "new" >untracked.txt
assert_exit "--no-dirty overrides --dirty" 2 \
    "$GITCALVER" --dirty "-dirty" --no-dirty

new_repo "dirty_no_hash_exact"
commit_at "2026-04-10T09:00:00Z"
echo "new" >untracked.txt
assert_output "--dirty --no-dirty-hash exact" "20260410.1-dirty" \
    "$GITCALVER" --dirty "-dirty" --no-dirty-hash

# ---- Argument terminator ----

new_repo "double_dash_revision"
commit_at "2026-04-10T09:00:00Z"
assert_output "-- with implicit HEAD" "20260410.1" \
    "$GITCALVER" --

new_repo "double_dash_version"
commit_at "2026-04-10T09:00:00Z"
HASH=$(git rev-parse HEAD)
assert_output "-- with version" "$HASH" \
    "$GITCALVER" -- 20260410.1

# ---- Branch enforcement ----

new_repo "wrong_branch"
commit_at "2026-04-10T09:00:00Z"
git checkout -b feature --quiet
commit_at "2026-04-10T10:00:00Z" "feature commit"
assert_exit "off-branch without --dirty" 2 \
    "$GITCALVER"

new_repo "feature_branch_dirty"
commit_at "2026-04-10T09:00:00Z" "main-c1"
git checkout -b feature --quiet
commit_at "2026-04-10T12:00:00Z" "feature-c1"
assert_match "feature branch with --dirty" "^20260410\.1-dirty\." \
    "$GITCALVER" --dirty "-dirty"

new_repo "feature_branch_no_hash"
commit_at "2026-04-10T09:00:00Z" "main-c1"
git checkout -b feature --quiet
commit_at "2026-04-10T12:00:00Z" "feature-c1"
assert_output "feature branch dirty no hash" "20260410.1-dirty" \
    "$GITCALVER" --dirty "-dirty" --no-dirty-hash

new_repo "orphan_branch"
commit_at "2026-04-10T09:00:00Z"
git checkout --orphan other --quiet
git commit --allow-empty -m "orphan" --quiet
assert_exit "orphan branch (no trace to main)" 3 \
    "$GITCALVER" --branch main

new_repo "detached_head_with_branch"
commit_at "2026-04-10T09:00:00Z"
git checkout --detach --quiet
assert_output "detached HEAD + --branch" "20260410.1" \
    "$GITCALVER" --branch main

new_repo "detached_head_no_branch"
commit_at "2026-04-10T09:00:00Z"
git checkout --detach --quiet
# With no remote and detached HEAD, auto-detection should still find local main
assert_output "detached HEAD auto-detect local main" "20260410.1" \
    "$GITCALVER"

new_repo "branch_nonexistent"
commit_at "2026-04-10T09:00:00Z"
assert_exit "--branch nonexistent" 1 \
    "$GITCALVER" --branch nonexistent

cd "$TMPDIR_BASE"
git init -b develop no_default_branch --quiet
cd no_default_branch
git config user.email "test@test.com"
git config user.name "Test"
commit_at "2026-04-10T09:00:00Z"
assert_exit "no default branch detected" 1 \
    "$GITCALVER"

# ---- Error cases ----

cd "$TMPDIR_BASE"
mkdir not_a_repo
cd not_a_repo
assert_exit "not a git repo" 1 \
    "$GITCALVER"

new_repo "empty_repo_test"
# No commits
assert_exit "empty repo" 1 \
    "$GITCALVER"

# ---- Shallow clone ----

new_repo "shallow_source"
commit_at "2026-04-10T09:00:00Z" "c1"
commit_at "2026-04-10T12:00:00Z" "c2"
git clone --depth 1 "file://$TMPDIR_BASE/shallow_source" "$TMPDIR_BASE/shallow_clone" --quiet
cd "$TMPDIR_BASE/shallow_clone"
assert_exit "shallow clone rejected" 1 \
    "$GITCALVER"

git worktree add "$TMPDIR_BASE/shallow_worktree" HEAD --quiet 2>/dev/null
cd "$TMPDIR_BASE/shallow_worktree"
assert_exit "shallow clone worktree rejected" 1 \
    "$GITCALVER"

# ---- --short in forward mode ----

new_repo "short_forward"
commit_at "2026-04-10T09:00:00Z"
assert_exit "--short in forward mode" 1 \
    "$GITCALVER" --short

# ---- Version regex anchoring ----

new_repo "version_trailing_garbage"
commit_at "2026-04-10T09:00:00Z"
assert_exit "trailing garbage not treated as version" 1 \
    "$GITCALVER" "20260410.3rc1"

# ---- First-parent / merge behavior ----

new_repo "merge_no_inflate"
commit_at "2026-04-10T09:00:00Z" "main-1"
git checkout -b feature --quiet
commit_at "2026-04-10T10:00:00Z" "feature-1"
commit_at "2026-04-10T11:00:00Z" "feature-2"
commit_at "2026-04-10T12:00:00Z" "feature-3"
git checkout main --quiet
GIT_COMMITTER_DATE="2026-04-10T13:00:00Z" \
    GIT_AUTHOR_DATE="2026-04-10T13:00:00Z" \
    git merge feature --no-ff -m "merge feature" --quiet
# First-parent: main-1 + merge commit = 2, not 5
assert_output "merges don't inflate count" "20260410.2" \
    "$GITCALVER"

# ---- UTC midnight boundary ----

new_repo "utc_midnight"
commit_at "2026-04-10T23:59:59Z" "just before midnight"
commit_at "2026-04-11T00:00:00Z" "midnight exactly"
commit_at "2026-04-11T00:00:01Z" "just after midnight"
assert_output "UTC midnight boundary" "20260411.2" \
    "$GITCALVER"

# ---- Year boundary ----

new_repo "year_boundary"
commit_at "2026-12-31T23:00:00Z" "last-of-year"
commit_at "2027-01-01T01:00:00Z" "first-of-year"
assert_output "year boundary" "20270101.1" \
    "$GITCALVER"

# ---- Strictly increasing ----

new_repo "strictly_increasing"
commit_at "2026-04-10T09:00:00Z" "c1"
V1=$("$GITCALVER" 2>/dev/null)
commit_at "2026-04-10T10:00:00Z" "c2"
V2=$("$GITCALVER" 2>/dev/null)
commit_at "2026-04-10T11:00:00Z" "c3"
V3=$("$GITCALVER" 2>/dev/null)
commit_at "2026-04-11T09:00:00Z" "c4"
V4=$("$GITCALVER" 2>/dev/null)

# Numeric comparison: YYYYMMDD part is always 8 digits so date*10000+N gives
# a single integer that increases iff the version increases.
version_ord() {
    echo "$(echo "$1" | cut -d. -f1)$(printf '%04d' "$(echo "$1" | cut -d. -f2)")"
}
O1=$(version_ord "$V1")
O2=$(version_ord "$V2")
O3=$(version_ord "$V3")
O4=$(version_ord "$V4")
if [ "$O1" -lt "$O2" ] && [ "$O2" -lt "$O3" ] && [ "$O3" -lt "$O4" ]; then
    pass "strictly increasing versions"
else
    fail "strictly increasing versions" \
        "V1<V2<V3<V4" "$V1, $V2, $V3, $V4"
fi

# ---- 1:1 mapping (unique versions) ----

new_repo "unique_versions"
commit_at "2026-04-10T09:00:00Z" "c1"
V1=$("$GITCALVER" 2>/dev/null)
commit_at "2026-04-10T10:00:00Z" "c2"
V2=$("$GITCALVER" 2>/dev/null)
commit_at "2026-04-11T09:00:00Z" "c3"
V3=$("$GITCALVER" 2>/dev/null)
if [ "$V1" != "$V2" ] && [ "$V2" != "$V3" ] && [ "$V1" != "$V3" ]; then
    pass "1:1 mapping (unique versions)"
else
    fail "1:1 mapping" "all unique" "$V1, $V2, $V3"
fi

# ---- Decreasing committer dates ----

new_repo "decreasing_dates"
commit_at "2026-04-11T09:00:00Z" "future"
# Force a commit with an earlier committer date (simulating bad rebase)
GIT_COMMITTER_DATE="2026-04-10T09:00:00Z" \
    git commit --allow-empty -m "past" --quiet \
    --date="2026-04-10T09:00:00Z"
assert_exit "decreasing committer dates" 1 \
    "$GITCALVER"

# ---- Empty commit ----

new_repo "empty_commit"
commit_at "2026-04-10T09:00:00Z" "normal"
GIT_COMMITTER_DATE="2026-04-10T10:00:00Z" \
    git commit --allow-empty -m "empty" --quiet \
    --date="2026-04-10T10:00:00Z"
assert_output "empty commit counted" "20260410.2" \
    "$GITCALVER"

# ---- Committer date vs author date ----

new_repo "committer_vs_author"
commit_at_split "2026-04-11T09:00:00Z" "2026-04-10T09:00:00Z" "rebased"
assert_output "uses committer date not author date" "20260411.1" \
    "$GITCALVER"

# ---- Default branch detection ----

new_repo "detect_local_main"
commit_at "2026-04-10T09:00:00Z"
# No remote, but local main exists
assert_output "detect local main branch" "20260410.1" \
    "$GITCALVER"

new_repo "detect_origin_head"
commit_at "2026-04-10T09:00:00Z"
git clone --bare . "$TMPDIR_BASE/detect_origin_head_remote" --quiet
git remote add origin "$TMPDIR_BASE/detect_origin_head_remote"
git fetch origin --quiet
assert_output "detect origin/HEAD" "20260410.1" \
    "$GITCALVER"

new_repo "detect_origin_main"
commit_at "2026-04-10T09:00:00Z"
git clone --bare . "$TMPDIR_BASE/detect_origin_main_remote" --quiet
git remote add origin "$TMPDIR_BASE/detect_origin_main_remote"
git fetch origin --quiet
git remote set-head origin --delete
assert_output "detect origin/main (no origin/HEAD)" "20260410.1" \
    "$GITCALVER"

# ---- Reverse lookup (version → commit) ----

new_repo "find_basic"
commit_at "2026-04-10T09:00:00Z" "c1"
HASH1=$(git rev-parse HEAD)
commit_at "2026-04-10T12:00:00Z" "c2"
HASH2=$(git rev-parse HEAD)
commit_at "2026-04-10T15:00:00Z" "c3"
HASH3=$(git rev-parse HEAD)
commit_at "2026-04-11T09:00:00Z" "c4"
HASH4=$(git rev-parse HEAD)
assert_output "find: first commit of day" "$HASH1" \
    "$GITCALVER" 20260410.1
assert_output "find: middle commit of day" "$HASH2" \
    "$GITCALVER" 20260410.2
assert_output "find: last commit of day" "$HASH3" \
    "$GITCALVER" 20260410.3
assert_output "find: next day" "$HASH4" \
    "$GITCALVER" 20260411.1

new_repo "find_short"
commit_at "2026-04-10T09:00:00Z"
SHORT=$(git rev-parse --short HEAD)
assert_output "find --short" "$SHORT" \
    "$GITCALVER" --short 20260410.1

new_repo "find_semver_format"
commit_at "2026-04-10T09:00:00Z"
HASH=$(git rev-parse HEAD)
assert_output "find: accepts semver format" "$HASH" \
    "$GITCALVER" --prefix "0." 0.20260410.1

new_repo "find_go_format"
commit_at "2026-04-10T09:00:00Z"
HASH=$(git rev-parse HEAD)
assert_output "find: accepts go format" "$HASH" \
    "$GITCALVER" --prefix "v0." v0.20260410.1

new_repo "find_not_found"
commit_at "2026-04-10T09:00:00Z"
assert_exit "find: version not found" 1 \
    "$GITCALVER" 20260410.5

new_repo "find_wrong_date"
commit_at "2026-04-10T09:00:00Z"
assert_exit "find: date not found" 1 \
    "$GITCALVER" 20260415.1

new_repo "find_roundtrip"
commit_at "2026-04-10T09:00:00Z" "c1"
commit_at "2026-04-10T12:00:00Z" "c2"
commit_at "2026-04-11T09:00:00Z" "c3"
EXPECTED_HASH=$(git rev-parse HEAD)
VERSION=$("$GITCALVER" 2>/dev/null)
FOUND_HASH=$("$GITCALVER" "$VERSION" 2>/dev/null)
if [ "$FOUND_HASH" = "$EXPECTED_HASH" ]; then
    pass "find: round-trip (version → hash → verify)"
else
    fail "find: round-trip" "$EXPECTED_HASH" "$FOUND_HASH"
fi

new_repo "find_from_feature_branch"
commit_at "2026-04-10T09:00:00Z" "main-c1"
HASH=$(git rev-parse HEAD)
git checkout -b feature --quiet
commit_at "2026-04-10T12:00:00Z" "feature-c1"
assert_output "find: works from non-default branch" "$HASH" \
    "$GITCALVER" --branch main 20260410.1

# ---- Forward computation for specific revision ----

new_repo "rev_specific"
commit_at "2026-04-10T09:00:00Z" "c1"
REV1=$(git rev-parse HEAD)
commit_at "2026-04-10T12:00:00Z" "c2"
commit_at "2026-04-11T09:00:00Z" "c3"
assert_output "revision: specific commit" "20260410.1" \
    "$GITCALVER" "$REV1"

new_repo "rev_head_tilde"
commit_at "2026-04-10T09:00:00Z" "c1"
commit_at "2026-04-10T12:00:00Z" "c2"
commit_at "2026-04-11T09:00:00Z" "c3"
assert_output "revision: HEAD~1" "20260410.2" \
    "$GITCALVER" HEAD~1

new_repo "rev_short_hash"
commit_at "2026-04-10T09:00:00Z" "c1"
SHORT=$(git rev-parse --short HEAD)
commit_at "2026-04-10T12:00:00Z" "c2"
assert_output "revision: short hash" "20260410.1" \
    "$GITCALVER" "$SHORT"

new_repo "rev_with_format"
commit_at "2026-04-10T09:00:00Z" "c1"
REV=$(git rev-parse HEAD)
commit_at "2026-04-10T12:00:00Z" "c2"
assert_output "revision: with --prefix" "0.20260410.1" \
    "$GITCALVER" --prefix "0." "$REV"

new_repo "rev_not_on_branch"
commit_at "2026-04-10T09:00:00Z" "main-c1"
git checkout -b feature --quiet
commit_at "2026-04-10T12:00:00Z" "feature-c1"
FEATURE_REV=$(git rev-parse HEAD)
git checkout main --quiet
assert_exit "revision: off-branch without --dirty" 2 \
    "$GITCALVER" "$FEATURE_REV"

new_repo "rev_off_branch_dirty"
commit_at "2026-04-10T09:00:00Z" "main-c1"
git checkout -b feature --quiet
commit_at "2026-04-10T12:00:00Z" "feature-c1"
FEATURE_REV=$(git rev-parse HEAD)
FEATURE_SHORT=$(git rev-parse --short HEAD)
git checkout main --quiet
assert_output "revision: off-branch with --dirty" \
    "20260410.1-dirty.${FEATURE_SHORT}" \
    "$GITCALVER" --dirty "-dirty" "$FEATURE_REV"

new_repo "rev_invalid"
commit_at "2026-04-10T09:00:00Z"
assert_exit "revision: invalid ref" 1 \
    "$GITCALVER" "nonexistent_ref"

# ---- Time zone handling ----

new_repo "tz_negative_offset"
commit_at "2026-04-11T02:00:00Z"
# In America/New_York (UTC-4) this is still April 10 locally,
# but the version must use the UTC date.
assert_output "TZ: negative offset uses UTC date" "20260411.1" \
    env TZ=America/New_York "$GITCALVER"

new_repo "tz_positive_offset"
commit_at "2026-04-10T22:00:00Z"
# In Asia/Tokyo (UTC+9) this is already April 11 locally,
# but the version must use the UTC date.
assert_output "TZ: positive offset uses UTC date" "20260410.1" \
    env TZ=Asia/Tokyo "$GITCALVER"

new_repo "tz_day_count_across_midnight"
commit_at "2026-04-10T23:00:00Z" "late-utc"
commit_at "2026-04-11T01:00:00Z" "early-utc"
# In Pacific/Auckland (UTC+12) both are April 11 locally,
# but in UTC they span two different days, so count resets.
assert_output "TZ: day count uses UTC boundaries" "20260411.1" \
    env TZ=Pacific/Auckland "$GITCALVER"

new_repo "tz_reverse_lookup"
commit_at "2026-04-11T02:00:00Z"
EXPECTED_HASH=$(git rev-parse HEAD)
VERSION=$(TZ=America/New_York "$GITCALVER" 2>/dev/null)
FOUND_HASH=$(TZ=America/New_York "$GITCALVER" "$VERSION" 2>/dev/null)
if [ "$FOUND_HASH" = "$EXPECTED_HASH" ]; then
    pass "TZ: reverse lookup round-trip under offset"
else
    fail "TZ: reverse lookup round-trip under offset" "$EXPECTED_HASH" "$FOUND_HASH"
fi

# ---- N >= 10 (double-digit count) ----

new_repo "large_count"
i=0
while [ "$i" -lt 11 ]; do
    hour=$(printf '%02d' "$i")
    commit_at "2026-04-10T${hour}:00:00Z" "c$((i + 1))"
    i=$((i + 1))
done
assert_output "N=11 on same day" "20260410.11" \
    "$GITCALVER"
EXPECTED_HASH=$(git rev-parse HEAD)
assert_output "N=11 round-trip" "$EXPECTED_HASH" \
    "$GITCALVER" 20260410.11

# ---- Dirty hash is HEAD, not merge-base ----

new_repo "dirty_hash_is_head"
commit_at "2026-04-10T09:00:00Z" "main-c1"
git checkout -b feature --quiet
commit_at "2026-04-10T12:00:00Z" "feature-c1"
EXPECTED_HASH=$(git rev-parse --short HEAD)
assert_output "dirty hash is HEAD not merge-base" \
    "20260410.1-dirty.${EXPECTED_HASH}" \
    "$GITCALVER" --dirty "-dirty"

# ---- Argument parsing edge cases ----

new_repo "arg_edge_cases"
commit_at "2026-04-10T09:00:00Z"
assert_exit "--help exits 0" 0 \
    "$GITCALVER" --help
assert_exit "--prefix without argument" 1 \
    "$GITCALVER" --prefix
assert_exit "--dirty without argument" 1 \
    "$GITCALVER" --dirty
assert_exit "--branch without argument" 1 \
    "$GITCALVER" --branch
assert_exit "leading zero in N rejected" 1 \
    "$GITCALVER" 20260410.01
assert_exit "multiple positional args rejected" 1 \
    "$GITCALVER" HEAD HEAD
assert_exit "options after -- treated as positional" 1 \
    "$GITCALVER" -- --dirty "-dirty"
assert_exit "multiple args after -- rejected" 1 \
    "$GITCALVER" -- HEAD HEAD

# ---- Summary ----

echo ""
echo "=== Results: $PASS passed, $FAIL failed, $TOTAL total ==="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
