#!/usr/bin/env bash
# Copyright © 2026 Michael Shields
# SPDX-License-Identifier: MIT

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)
PUBLISH="$ROOT/action/publish.sh"
TMPDIR_BASE=$(mktemp -d "${TMPDIR:-/tmp}/gitcalver-action.XXXXXX")
trap 'rm -rf "$TMPDIR_BASE"' EXIT

passed=0
failed=0

pass() {
    printf 'ok - %s\n' "$1"
    passed=$((passed + 1))
}

fail_test() {
    printf 'not ok - %s\n%s\n' "$1" "$2" >&2
    failed=$((failed + 1))
}

new_repo() {
    local name=$1 branch=${2:-main}

    CASE_DIR="$TMPDIR_BASE/$name"
    REPO="$CASE_DIR/work"
    REMOTE_REPO="$CASE_DIR/remote.git"
    mkdir -p "$CASE_DIR"
    git init --bare --quiet "$REMOTE_REPO"
    git init --quiet --initial-branch="$branch" "$REPO"
    git -C "$REPO" config user.email test@example.com
    git -C "$REPO" config user.name 'GitCalVer Test'
    git -C "$REPO" remote add upstream "$REMOTE_REPO"
    BRANCH=$branch
}

commit_at() {
    local date=$1 message=$2

    GIT_AUTHOR_DATE="${date}T12:00:00Z" \
        GIT_COMMITTER_DATE="${date}T12:00:00Z" \
        git -C "$REPO" commit --quiet --allow-empty -m "$message"
}

push_branch() {
    git -C "$REPO" push --quiet upstream \
        "refs/heads/$BRANCH:refs/heads/$BRANCH"
    git -C "$REPO" update-ref "refs/remotes/upstream/$BRANCH" \
        "refs/heads/$BRANCH"
}

push_tag() {
    local name=$1 target=$2

    git -C "$REPO" push --quiet upstream "$target:refs/tags/$name"
}

publish() {
    local version=$1 date=$2 prefix=${3-} tag_prefix=${4-}
    local dirty=${5:-false}

    (
        cd "$REPO"
        VERSION="$version" \
            VERSION_DATE="$date" \
            DIRTY="$dirty" \
            VERSION_PREFIX="$prefix" \
            TAG_PREFIX="$tag_prefix" \
            REMOTE=upstream \
            BRANCH_OVERRIDE="$BRANCH" \
            bash "$PUBLISH"
    )
}

assert_success() {
    local label=$1
    shift
    local output

    if output=$("$@" 2>&1); then
        pass "$label"
    else
        fail_test "$label" "$output"
    fi
}

assert_failure() {
    local label=$1 expected=$2
    shift 2
    local output

    if output=$("$@" 2>&1); then
        fail_test "$label" "unexpected success: $output"
    elif [[ $output == *"$expected"* ]]; then
        pass "$label"
    else
        fail_test "$label" "expected '$expected', got: $output"
    fi
}

remote_tag_target() {
    git --git-dir="$REMOTE_REPO" rev-parse --verify "refs/tags/$1^{commit}"
}

new_repo publish_prefixed trunk
commit_at 2026-04-09 first
commit_at 2026-04-10 second
push_branch
head=$(git -C "$REPO" rev-parse HEAD)
assert_success 'publish prefixed canonical tag' \
    publish 0.20260410.1 20260410 0. release/v
if [[ $(remote_tag_target release/v0.20260410.1) == "$head" ]]; then
    pass 'published tag points to HEAD'
else
    fail_test 'published tag points to HEAD' 'remote tag target differs'
fi
assert_success 'matching tag retry is idempotent' \
    publish 0.20260410.1 20260410 0. release/v

new_repo mismatched_tag
commit_at 2026-04-09 first
old=$(git -C "$REPO" rev-parse HEAD)
commit_at 2026-04-10 second
push_branch
push_tag 20260410.1 "$old"
assert_failure 'same tag on another commit is rejected' \
    'already exists on a different commit' publish 20260410.1 20260410
if [[ $(remote_tag_target 20260410.1) == "$old" ]]; then
    pass 'mismatched tag is not moved'
else
    fail_test 'mismatched tag is not moved' 'remote tag was changed'
fi

new_repo stale_tip
commit_at 2026-04-09 first
push_branch
commit_at 2026-04-10 unpushed
assert_failure 'unpushed HEAD is rejected' \
    'HEAD is not the latest tip' publish 20260410.1 20260410

new_repo invalid_date
commit_at 2026-04-09 first
push_branch
push_tag 20260230.1 HEAD
commit_at 2026-04-10 second
push_branch
assert_failure 'invalid canonical tag date is rejected' \
    'canonical tag has an invalid date' publish 20260410.1 20260410

new_repo wrong_tag_date
commit_at 2026-04-08 first
old=$(git -C "$REPO" rev-parse HEAD)
push_tag 20260409.1 "$old"
commit_at 2026-04-10 second
push_branch
assert_failure 'canonical tag date must match its commit' \
    'does not match its commit date' publish 20260410.1 20260410

new_repo global_latest
commit_at 2026-04-09 first
commit_at 2026-04-10 second
push_branch
main_head=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" switch --quiet --orphan abandoned
commit_at 2026-04-11 abandoned
abandoned=$(git -C "$REPO" rev-parse HEAD)
push_tag 20260411.1 "$abandoned"
git -C "$REPO" switch --quiet main
[[ $(git -C "$REPO" rev-parse HEAD) == "$main_head" ]]
assert_failure 'unreachable global latest tag blocks reuse' \
    'is not newer than canonical tag' publish 20260410.1 20260410

new_repo merge_orientation
commit_at 2026-04-08 base
git -C "$REPO" switch --quiet -c feature
commit_at 2026-04-09 feature
feature=$(git -C "$REPO" rev-parse HEAD)
push_tag 20260409.1 "$feature"
git -C "$REPO" switch --quiet main
commit_at 2026-04-09 main
GIT_AUTHOR_DATE='2026-04-10T12:00:00Z' \
    GIT_COMMITTER_DATE='2026-04-10T12:00:00Z' \
    git -C "$REPO" merge --quiet --no-ff feature -m merge
push_branch
assert_failure 'second-parent release line is rejected' \
    "not on HEAD's first-parent chain" publish 20260410.1 20260410

new_repo first_parent_merge
commit_at 2026-04-08 base
commit_at 2026-04-09 main
main_parent=$(git -C "$REPO" rev-parse HEAD)
push_tag 20260409.1 "$main_parent"
git -C "$REPO" switch --quiet -c feature HEAD~1
commit_at 2026-04-09 feature
git -C "$REPO" switch --quiet main
GIT_AUTHOR_DATE='2026-04-10T12:00:00Z' \
    GIT_COMMITTER_DATE='2026-04-10T12:00:00Z' \
    git -C "$REPO" merge --quiet --no-ff feature -m merge
push_branch
assert_success 'first-parent release line survives a merge' \
    publish 20260410.1 20260410

printf '%s passed, %s failed\n' "$passed" "$failed"
((failed == 0))
