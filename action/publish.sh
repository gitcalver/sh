#!/usr/bin/env bash
# Copyright © 2026 Michael Shields
# SPDX-License-Identifier: MIT

set -euo pipefail
export LC_ALL=C

fail() {
    printf '::error::gitcalver: %s\n' "$1" >&2
    exit 1
}

notice() {
    printf '::notice::gitcalver: %s\n' "$1"
}

valid_date() {
    local value=$1 year month day leap max_day

    [[ $value =~ ^([0-9]{4})([0-9]{2})([0-9]{2})$ ]] || return 1
    year=$((10#${BASH_REMATCH[1]}))
    month=$((10#${BASH_REMATCH[2]}))
    day=$((10#${BASH_REMATCH[3]}))
    ((year >= 1 && month >= 1 && month <= 12 && day >= 1)) || return 1

    leap=0
    if ((year % 4 == 0 && (year % 100 != 0 || year % 400 == 0))); then
        leap=1
    fi
    case $month in
        2) max_day=$((28 + leap)) ;;
        4 | 6 | 9 | 11) max_day=30 ;;
        *) max_day=31 ;;
    esac
    ((day <= max_day))
}

version_is_greater() {
    local left_date=$1 left_count=$2 right_date=$3 right_count=$4

    if [[ $left_date != "$right_date" ]]; then
        [[ $left_date > $right_date ]]
        return
    fi
    if ((${#left_count} != ${#right_count})); then
        ((${#left_count} > ${#right_count}))
        return
    fi
    [[ $left_count > $right_count ]]
}

detect_branch() {
    local remote_prefix ref

    if [[ -n $BRANCH_OVERRIDE ]]; then
        printf '%s\n' "$BRANCH_OVERRIDE"
        return
    fi

    remote_prefix="refs/remotes/$REMOTE/"
    ref=$(git symbolic-ref "refs/remotes/$REMOTE/HEAD" 2>/dev/null || true)
    if [[ $ref == "$remote_prefix"* ]]; then
        printf '%s\n' "${ref#"$remote_prefix"}"
        return
    fi
    if git rev-parse --verify "refs/remotes/$REMOTE/main" >/dev/null 2>&1; then
        printf 'main\n'
        return
    fi
    if git rev-parse --verify "refs/remotes/$REMOTE/master" >/dev/null 2>&1; then
        printf 'master\n'
        return
    fi
    if git rev-parse --verify refs/heads/main >/dev/null 2>&1; then
        printf 'main\n'
        return
    fi
    if git rev-parse --verify refs/heads/master >/dev/null 2>&1; then
        printf 'master\n'
        return
    fi
    return 1
}

remote_head() {
    local result oid ref

    result=$(git ls-remote --heads "$REMOTE" "refs/heads/$BRANCH") ||
        fail "cannot read branch $BRANCH from remote $REMOTE"
    IFS=$'\t' read -r oid ref <<<"$result"
    [[ -n $oid && $ref == "refs/heads/$BRANCH" && $result != *$'\n'* ]] ||
        fail "cannot resolve branch $BRANCH on remote $REMOTE"
    printf '%s\n' "$oid"
}

TEMP_REF="refs/gitcalver/action-tag-$$-$RANDOM"
cleanup() {
    git update-ref -d "$TEMP_REF" >/dev/null 2>&1 || true
}
trap cleanup EXIT

fetch_tag_target() {
    local name=$1 expected_oid=$2 fetched_oid target

    cleanup
    git fetch --quiet --no-tags "$REMOTE" \
        "refs/tags/$name:$TEMP_REF" ||
        fail "cannot fetch canonical tag $name from remote $REMOTE"
    fetched_oid=$(git rev-parse --verify "$TEMP_REF") ||
        fail "cannot resolve canonical tag $name"
    [[ $fetched_oid == "$expected_oid" ]] ||
        fail "canonical tag $name changed while publication was running"
    target=$(git rev-parse --verify "$TEMP_REF^{commit}") ||
        fail "canonical tag $name does not name a commit"
    printf '%s\n' "$target"
}

first_parent_contains() {
    local descendant=$1 ancestor=$2 chain commit last stored_parent

    chain=$(git rev-list --first-parent "$descendant") ||
        fail "cannot prove the selected branch's first-parent history"
    last=
    while IFS= read -r commit; do
        [[ -n $commit ]] || continue
        last=$commit
        if [[ $commit == "$ancestor" ]]; then
            return 0
        fi
    done <<<"$chain"

    [[ -n $last ]] || fail "cannot read the selected branch's history"
    stored_parent=$(git cat-file commit "$last" 2>/dev/null |
        sed -n '/^$/q; s/^parent //p' | sed -n '1p') ||
        fail "cannot inspect the selected branch's history"
    [[ -z $stored_parent ]] ||
        fail "local history cannot prove continuity with the previous canonical tag"
    return 1
}

: "${VERSION:?VERSION is required}"
: "${VERSION_DATE:?VERSION_DATE is required}"
: "${DIRTY:?DIRTY is required}"
VERSION_PREFIX=${VERSION_PREFIX-}
TAG_PREFIX=${TAG_PREFIX-}
REMOTE=${REMOTE:-origin}
BRANCH_OVERRIDE=${BRANCH_OVERRIDE-}

[[ $DIRTY == false ]] || fail "refusing to tag dirty version: $VERSION"
[[ -n $REMOTE && $REMOTE != -* && $REMOTE != *$'\n'* ]] ||
    fail "remote must be a non-empty remote name"
git remote get-url "$REMOTE" >/dev/null 2>&1 ||
    fail "remote does not exist: $REMOTE"

if [[ $VERSION != "$VERSION_PREFIX"* ]]; then
    fail "version $VERSION does not start with prefix $VERSION_PREFIX"
fi
candidate_core=${VERSION#"$VERSION_PREFIX"}
if [[ ! $candidate_core =~ ^([0-9]{8})\.([1-9][0-9]*)$ ]]; then
    fail "version is not a clean GitCalVer version: $VERSION"
fi
candidate_date=${BASH_REMATCH[1]}
candidate_count=${BASH_REMATCH[2]}
valid_date "$candidate_date" || fail "version has an invalid date: $VERSION"
[[ $VERSION_DATE == "$candidate_date" ]] ||
    fail "version date output does not match version: $VERSION"

TAG="${TAG_PREFIX}${VERSION}"
git check-ref-format "refs/tags/$TAG" >/dev/null 2>&1 ||
    fail "tag name is invalid: $TAG"

BRANCH=$(detect_branch) || fail "cannot determine selected branch"
git check-ref-format "refs/heads/$BRANCH" >/dev/null 2>&1 ||
    fail "selected branch name is invalid: $BRANCH"
git check-ref-format "refs/remotes/$REMOTE/$BRANCH" >/dev/null 2>&1 ||
    fail "remote or selected branch name is invalid"

export GIT_NO_LAZY_FETCH=1 GIT_NO_REPLACE_OBJECTS=1
head_oid=$(git rev-parse --verify 'HEAD^{commit}') || fail "HEAD is not a commit"
head_date=$(TZ=UTC git show -s --format=%cd \
    --date=format-local:%Y%m%d "$head_oid") || fail "cannot read HEAD date"
[[ $head_date == "$candidate_date" ]] ||
    fail "version date $candidate_date does not match HEAD date $head_date"

git fetch --quiet --no-tags "$REMOTE" \
    "+refs/heads/$BRANCH:refs/remotes/$REMOTE/$BRANCH" ||
    fail "cannot refresh branch $BRANCH from remote $REMOTE"
remote_tip=$(git rev-parse --verify "refs/remotes/$REMOTE/$BRANCH^{commit}") ||
    fail "cannot resolve refreshed branch $BRANCH"
[[ $remote_tip == "$head_oid" ]] ||
    fail "HEAD is not the latest tip of $REMOTE/$BRANCH"

tag_stem="${TAG_PREFIX}${VERSION_PREFIX}"
latest_name=
latest_date=
latest_count=
latest_oid=
candidate_oid=
remote_tags=$(git ls-remote --tags --refs "$REMOTE") ||
    fail "cannot read tags from remote $REMOTE"
while IFS=$'\t' read -r oid ref; do
    [[ $ref == refs/tags/* ]] || continue
    name=${ref#refs/tags/}
    [[ $name == "$tag_stem"* ]] || continue
    core=${name#"$tag_stem"}
    [[ $core =~ ^([0-9]{8})\.([1-9][0-9]*)$ ]] || continue
    date=${BASH_REMATCH[1]}
    count=${BASH_REMATCH[2]}
    valid_date "$date" ||
        fail "canonical tag has an invalid date: $name"

    if [[ $name == "$TAG" ]]; then
        candidate_oid=$oid
    fi
    if [[ -z $latest_name ]] ||
        version_is_greater "$date" "$count" "$latest_date" "$latest_count"; then
        latest_name=$name
        latest_date=$date
        latest_count=$count
        latest_oid=$oid
    fi
done <<<"$remote_tags"

if [[ -n $latest_name ]] &&
    version_is_greater "$latest_date" "$latest_count" \
        "$candidate_date" "$candidate_count"; then
    fail "version $VERSION is not newer than canonical tag $latest_name"
fi

if [[ -n $candidate_oid ]]; then
    [[ $latest_name == "$TAG" ]] ||
        fail "tag $TAG exists but is not the latest canonical tag"
    candidate_target=$(fetch_tag_target "$TAG" "$candidate_oid")
    [[ $candidate_target == "$head_oid" ]] ||
        fail "tag $TAG already exists on a different commit ($candidate_target)"
    [[ $(remote_head) == "$head_oid" ]] ||
        fail "HEAD is no longer the latest tip of $REMOTE/$BRANCH"
    notice "tag $TAG already exists at HEAD"
    exit 0
fi

if [[ -n $latest_name ]]; then
    latest_target=$(fetch_tag_target "$latest_name" "$latest_oid")
    latest_target_date=$(TZ=UTC git show -s --format=%cd \
        --date=format-local:%Y%m%d "$latest_target") ||
        fail "cannot read commit date for canonical tag $latest_name"
    [[ $latest_target_date == "$latest_date" ]] ||
        fail "canonical tag $latest_name does not match its commit date $latest_target_date"
    if ! first_parent_contains "$head_oid" "$latest_target"; then
        fail "previous canonical tag $latest_name is not on HEAD's first-parent chain"
    fi
fi

if git push --atomic "$REMOTE" \
    "$head_oid:refs/heads/$BRANCH" "$head_oid:refs/tags/$TAG"; then
    notice "created and pushed tag $TAG"
    exit 0
fi

# A concurrent publisher may have claimed the same version after the global
# scan. Treat the same target as an idempotent retry, but never move the tag.
raced_tag=$(git ls-remote --tags --refs "$REMOTE" "refs/tags/$TAG") ||
    fail "cannot verify tag $TAG after push failure"
if [[ -n $raced_tag && $raced_tag != *$'\n'* ]]; then
    IFS=$'\t' read -r raced_oid raced_ref <<<"$raced_tag"
    if [[ $raced_ref == "refs/tags/$TAG" ]]; then
        raced_target=$(fetch_tag_target "$TAG" "$raced_oid")
        if [[ $raced_target == "$head_oid" && $(remote_head) == "$head_oid" ]]; then
            notice "tag $TAG was concurrently created at HEAD"
            exit 0
        fi
        fail "tag $TAG was claimed by a different commit ($raced_target)"
    fi
fi
fail "could not claim tag $TAG without force"
