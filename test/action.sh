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

new_repo second_parent_release_line_accepted
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
# Under 0.3, continuity is any-parent reachability plus a not-later date, not
# first-parent membership: the previous tag's target is the merge's second
# parent, dated before the merge, so publication is accepted.
assert_success 'second-parent release line is accepted when not later-dated' \
    publish 20260410.1 20260410

new_repo tag_target_unreachable
commit_at 2026-04-09 base
git -C "$REPO" switch --quiet --orphan abandoned
commit_at 2026-04-09 abandoned-tag-target
abandoned=$(git -C "$REPO" rev-parse HEAD)
push_tag 20260409.1 "$abandoned"
git -C "$REPO" switch --quiet main
commit_at 2026-04-10 main-1
push_branch
assert_failure 'previous tag target on unrelated history is rejected' \
    'previous canonical tag target is not reachable from HEAD' \
    publish 20260410.1 20260410

new_repo incident_topology_publish
commit_at 2026-04-09 base
git -C "$REPO" switch --quiet -c feature
commit_at 2026-04-10 feature-1
git -C "$REPO" switch --quiet main
commit_at 2026-04-10 main-2
push_branch
assert_success 'publish before reparenting' publish 20260410.1 20260410
# Reproduce the incident: merge main into feature, then fast-forward main
# onto the merge. main-2 leaves main's first-parent chain (the merge's first
# parent is feature-1) but remains reachable through the merge's second
# parent, at the same date, so the next publish succeeds at the higher
# cohort-based version instead of being permanently blocked.
git -C "$REPO" switch --quiet feature
GIT_AUTHOR_DATE='2026-04-10T13:00:00Z' \
    GIT_COMMITTER_DATE='2026-04-10T13:00:00Z' \
    git -C "$REPO" merge --quiet --no-ff main -m "merge main into feature"
git -C "$REPO" switch --quiet main
git -C "$REPO" merge --quiet --ff-only feature
push_branch
assert_success 'publish after reparenting succeeds at the higher cohort version' \
    publish 20260410.3 20260410

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

new_repo shallow_continuity_unprovable
commit_at 2026-04-01 c1
commit_at 2026-04-01 c2
commit_at 2026-04-01 c3
tag_target=$(git -C "$REPO" rev-parse HEAD)
commit_at 2026-04-02 c4
commit_at 2026-04-03 c5
commit_at 2026-04-09 c6
commit_at 2026-04-10 c7
push_branch
push_tag 20260401.1 "$tag_target"
# A shallow work clone leaves the fetched tag target and HEAD on disconnected
# local islands even though full history connects them: the tag fetch brings
# the target's own complete closure but not the intervening commits beyond
# the shallow boundary, so a negative reachability answer is not definitive
# and must surface as unprovable, not as a permanent continuity failure.
rm -rf "$REPO"
git clone --quiet --depth 2 --single-branch --branch main \
    "file://$REMOTE_REPO" "$REPO"
git -C "$REPO" remote rename origin upstream
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name 'GitCalVer Test'
assert_failure 'shallow clone cannot prove tag continuity' \
    'local history cannot prove continuity' publish 20260410.1 20260410

new_repo continuity_missing_object
commit_at 2026-04-01 old
tag_target=$(git -C "$REPO" rev-parse HEAD)
commit_at 2026-04-05 middle
middle=$(git -C "$REPO" rev-parse HEAD)
commit_at 2026-04-06 later
commit_at 2026-04-10 tip
push_branch
push_tag 20260401.1 "$tag_target"
# A missing intermediate object (deep enough that reading HEAD itself still
# works) makes the ancestry walk fail outright — neither yes nor no — which
# must surface as unprovable.
rm "$REPO/.git/objects/${middle:0:2}/${middle:2}"
assert_failure 'missing object cannot prove tag continuity' \
    'local history cannot prove continuity' publish 20260410.1 20260410

printf '%s passed, %s failed\n' "$passed" "$failed"
((failed == 0))
