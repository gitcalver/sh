#!/bin/sh
#
# gitcalver.sh: derive version numbers from git history
#
# See https://gitcalver.org for details.
#
# Copyright © 2026 Michael Shields
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

set -eu

VERSION=""
EXIT_ERROR=1
EXIT_DIRTY=2
EXIT_NOT_TRACEABLE=3
EXIT_INCOMPLETE_HISTORY=4

usage() {
    cat <<'EOF'
Usage: gitcalver [OPTIONS] [REVISION | VERSION]

Derive a version number from git history using calendar versioning.

If REVISION is a git revision (commit, tag, branch), output its version.
If VERSION is a gitcalver version number, output the corresponding commit hash.
If neither is given, output the version for HEAD.
Use -- to separate options from a revision that starts with -.

Options:
  --prefix PREFIX     Literal string prepended to version (default: empty);
                      required to strip prefix in reverse lookup
  --dirty STRING      Enable dirty versions; append STRING.HASH to base
                      (STRING must not be empty; HASH is seven characters)
  --no-dirty          Refuse dirty versions (overrides --dirty)
  --no-dirty-hash     Suppress .HASH suffix (requires --dirty)
  --branch BRANCH     Base branch name (e.g. "main"); overrides auto-detection
  --remote REMOTE     Remote used for cached branch detection (default: origin)
  --short             Output first seven object-ID characters (reverse mode)
  --version           Show version information
  --help              Show this help

Exit codes:
  0   Success
  1   Error (not a git repo, no commits, decreasing dates, etc.)
  2   Dirty workspace or off default branch (without --dirty)
  3   Cannot trace to default branch
  4   Local history is insufficient to prove the result
EOF
    exit 0
}

die() {
    printf 'gitcalver: %s\n' "$1" >&2
    exit "${2:-$EXIT_ERROR}"
}

# --- Parse arguments ---

PREFIX=""
DIRTY_STRING=""
DIRTY_SET=false
NO_DIRTY=false
NO_DIRTY_HASH=false
BRANCH_OVERRIDE=""
REMOTE="origin"
POSITIONAL=""
TARGET_SET=false
SHORT_HASH=false

while [ $# -gt 0 ]; do
    case "$1" in
    --prefix)
        [ $# -ge 2 ] || die "--prefix requires an argument"
        PREFIX="$2"
        shift 2
        ;;
    --dirty)
        [ $# -ge 2 ] || die "--dirty requires an argument"
        [ -n "$2" ] || die "--dirty requires a non-empty argument"
        DIRTY_STRING="$2"
        DIRTY_SET=true
        shift 2
        ;;
    --no-dirty)
        NO_DIRTY=true
        shift
        ;;
    --no-dirty-hash)
        NO_DIRTY_HASH=true
        shift
        ;;
    --branch)
        [ $# -ge 2 ] || die "--branch requires an argument"
        BRANCH_OVERRIDE="$2"
        shift 2
        ;;
    --remote)
        [ $# -ge 2 ] || die "--remote requires an argument"
        [ -n "$2" ] || die "--remote requires a non-empty argument"
        REMOTE="$2"
        shift 2
        ;;
    --short)
        SHORT_HASH=true
        shift
        ;;
    --version)
        if [ -n "$VERSION" ]; then
            printf 'gitcalver %s\n' "$VERSION"
        else
            printf 'gitcalver (development)\n'
        fi
        exit 0
        ;;
    --help)
        usage
        ;;
    --)
        shift
        break
        ;;
    -*)
        die "unknown option: $1"
        ;;
    *)
        ! $TARGET_SET || die "unexpected argument: $1"
        POSITIONAL="$1"
        TARGET_SET=true
        shift
        ;;
    esac
done

# Handle positional argument after --
if [ $# -gt 0 ]; then
    ! $TARGET_SET || die "unexpected argument: $1"
    POSITIONAL="$1"
    TARGET_SET=true
    [ $# -le 1 ] || die "unexpected argument: $2"
fi

# Validate flag combinations
if $NO_DIRTY_HASH && ! $DIRTY_SET; then
    die "--no-dirty-hash requires --dirty"
fi

# Versions are one line. A line break in the caller-managed prefix would make
# forward output impossible to parse back exactly.
case "$PREFIX" in
*'
'*) die "--prefix must not contain a newline" ;;
esac

# Version calculation is local-only. In a partial clone, missing objects must
# produce the incomplete-history result instead of implicitly contacting a
# promisor remote. Replacement refs are also excluded so every invocation sees
# the repository's actual object graph.
GIT_NO_LAZY_FETCH=1
GIT_NO_REPLACE_OBJECTS=1
export GIT_NO_LAZY_FETCH GIT_NO_REPLACE_OBJECTS

# --- Verify git repository ---

git rev-parse --git-dir >/dev/null 2>&1 ||
    die "not a git repository"

# Resolve repository metadata through the common directory so linked worktrees
# see the same shallow boundary and deprecated graft file as the main worktree.
GIT_COMMON_DIR=$(git rev-parse --git-common-dir) ||
    die "cannot resolve git common directory"
case "$GIT_COMMON_DIR" in
/*) ;;
*)
    GIT_COMMON_DIR=$(cd "$GIT_COMMON_DIR" && pwd -P) ||
        die "cannot resolve git common directory"
    ;;
esac

SHALLOW_FILE="$GIT_COMMON_DIR/shallow"
GRAFT_FILE="$GIT_COMMON_DIR/info/grafts"

if [ -e "$GRAFT_FILE" ]; then
    die "commit graft file is not supported: $GRAFT_FILE" \
        "$EXIT_INCOMPLETE_HISTORY"
fi

# --- Verify commits exist ---

HEAD_OID=$(git rev-parse --verify HEAD 2>/dev/null) ||
    die "no commits in repository"
git cat-file -e "$HEAD_OID^{commit}" 2>/dev/null ||
    die "HEAD commit is missing from local history" \
        "$EXIT_INCOMPLETE_HISTORY"

IS_BARE_REPOSITORY=$(git rev-parse --is-bare-repository)

# --- Determine and verify default branch ---

# These helpers run in ( ) subshells, not { } blocks, so scratch variables stay
# function-local without the non-POSIX `local` keyword; each communicates only
# through stdout and its exit status.
detect_default_branch() (
    # 1. Explicit override
    if [ -n "$BRANCH_OVERRIDE" ]; then
        printf '%s\n' "$BRANCH_OVERRIDE"
        exit 0
    fi

    # 2. Cached remote default. Strip only the remote-tracking prefix, not every
    # path component: a branch name may itself contain slashes (e.g.
    # "release/v1"), and "${ref##*/}" would mangle it down to the last segment.
    remote_prefix="refs/remotes/$REMOTE/"
    ref=$(git symbolic-ref "refs/remotes/$REMOTE/HEAD" 2>/dev/null) || true
    if [ -n "$ref" ]; then
        case "$ref" in
        "$remote_prefix"*)
            printf '%s\n' "${ref#"$remote_prefix"}"
            exit 0
            ;;
        esac
    fi

    # 3. Check the selected remote's main, then master
    if git rev-parse --verify "refs/remotes/$REMOTE/main" >/dev/null 2>&1; then
        echo "main"
        exit 0
    fi
    if git rev-parse --verify "refs/remotes/$REMOTE/master" >/dev/null 2>&1; then
        echo "master"
        exit 0
    fi

    # 4. Check local main, then master
    if git rev-parse --verify refs/heads/main >/dev/null 2>&1; then
        echo "main"
        exit 0
    fi
    if git rev-parse --verify refs/heads/master >/dev/null 2>&1; then
        echo "master"
        exit 0
    fi

    exit 1
)

DEFAULT_BRANCH=$(detect_default_branch) ||
    die "cannot determine default branch"

# Resolve the tip commit of the selected branch. Prefer the local ref so
# unpushed commits on that branch remain clean; otherwise use the selected
# remote's cached tracking ref. This never contacts the remote.
resolve_branch_tip() (
    branch="$1"
    git rev-parse --verify "refs/heads/$branch" 2>/dev/null ||
        git rev-parse --verify "refs/remotes/$REMOTE/$branch" 2>/dev/null
)

# Read the actual first parent for one locally available commit. This is used
# only to distinguish a real root from a shallow or missing-parent boundary
# after a bulk Git traversal has stopped; it is never called once per commit.
get_stored_first_parent() {
    commit_object=$(git cat-file commit "$1" 2>/dev/null) || return 1
    STORED_FIRST_PARENT=$(printf '%s\n' "$commit_object" |
        sed -n '/^$/q; s/^parent //p' | sed -n '1p')
}

# A negative reachability result is conclusive only when the target's known
# ancestry did not stop at a shallow boundary and did not encounter a missing
# promised commit.
history_is_complete() (
    git rev-list "$1" >/dev/null 2>&1 || exit "$EXIT_INCOMPLETE_HISTORY"
    [ -f "$SHALLOW_FILE" ] || exit 0

    while IFS= read -r boundary; do
        [ -n "$boundary" ] || continue
        if git merge-base --is-ancestor "$boundary" "$1" 2>/dev/null; then
            get_stored_first_parent "$boundary" ||
                exit "$EXIT_INCOMPLETE_HISTORY"
            [ -z "$STORED_FIRST_PARENT" ] ||
                exit "$EXIT_INCOMPLETE_HISTORY"
        else
            ancestor_status=$?
            [ "$ancestor_status" -eq 1 ] ||
                exit "$EXIT_INCOMPLETE_HISTORY"
        fi
    done <"$SHALLOW_FILE"
)

# Find the newest selected-chain commit reachable from an off-chain target.
# Reachability considers every parent of the target, so a feature branch that
# has merged the selected branch anchors at that newer selected-branch commit.
find_reachable_branch_anchor() (
    rev="$1"
    branch_tip="$2"

    # Excluding rev removes its full ancestry from the selected first-parent
    # walk. The oldest remaining commit is therefore the child of the newest
    # reachable anchor. If nothing remains, the selected tip itself is
    # reachable. A root with no first parent means the histories do not meet.
    unreachable_count=$(git rev-list --count --first-parent \
        "$branch_tip" "^$rev" 2>/dev/null) ||
        exit "$EXIT_INCOMPLETE_HISTORY"
    if [ "$unreachable_count" -eq 0 ]; then
        printf '%s\n' "$branch_tip"
        exit 0
    fi

    if anchor=$(git rev-parse --verify \
        "$branch_tip~$unreachable_count^{commit}" 2>/dev/null); then
        printf '%s\n' "$anchor"
        exit 0
    fi

    # The selected walk either reached a real root or stopped at incomplete
    # history. Inspect only its last known commit to distinguish those cases.
    last_index=$((unreachable_count - 1))
    last_unreachable=$(git rev-parse --verify \
        "$branch_tip~$last_index^{commit}" 2>/dev/null) ||
        exit "$EXIT_INCOMPLETE_HISTORY"
    get_stored_first_parent "$last_unreachable" ||
        exit "$EXIT_INCOMPLETE_HISTORY"
    [ -z "$STORED_FIRST_PARENT" ] || exit "$EXIT_INCOMPLETE_HISTORY"

    # The selected walk reached a real root. The histories are conclusively
    # unrelated only if the target walk is complete as well.
    history_is_complete "$rev" || exit "$EXIT_INCOMPLETE_HISTORY"
    exit "$EXIT_NOT_TRACEABLE"
)

# Cache the selected branch tip once so every calculation in this invocation
# uses the same local view even if another process updates a ref concurrently.
DEFAULT_BRANCH_TIP=$(resolve_branch_tip "$DEFAULT_BRANCH") ||
    die "cannot resolve default branch: $DEFAULT_BRANCH"
git cat-file -e "$DEFAULT_BRANCH_TIP^{commit}" 2>/dev/null ||
    die "selected branch tip is missing from local history: $DEFAULT_BRANCH" \
        "$EXIT_INCOMPLETE_HISTORY"

# Match a bare YYYYMMDD.N version string.
# Outputs the version on success, produces no output on failure.
parse_gitcalver_version() {
    # A version is a single line. Reject embedded newlines up front: grep -x
    # matches any one line, so a multi-line argument could otherwise smuggle a
    # valid version line past it.
    case "$1" in
    *'
'*) return 0 ;;
    esac
    printf '%s\n' "$1" | grep -xE '[0-9]{8}\.[1-9][0-9]*' || true
}

# Validate the YYYYMMDD segment as a Gregorian calendar date. Keeping this
# separate from the shape parser makes version-shaped inputs take reverse-mode
# precedence even when their date is invalid; they fail as versions rather
# than falling through to revision parsing.
valid_gitcalver_date() {
    printf '%s\n' "$1" | awk '
        {
            y = substr($0, 1, 4) + 0
            m = substr($0, 5, 2) + 0
            d = substr($0, 7, 2) + 0
            leap = (y % 4 == 0 && (y % 100 != 0 || y % 400 == 0))
            days[1] = 31; days[2] = 28 + leap; days[3] = 31
            days[4] = 30; days[5] = 31; days[6] = 30
            days[7] = 31; days[8] = 31; days[9] = 30
            days[10] = 31; days[11] = 30; days[12] = 31
            exit !(y >= 1 && m >= 1 && m <= 12 && d >= 1 && d <= days[m])
        }
    '
}

# --- Reverse lookup (version → commit) ---

LOOKUP="$POSITIONAL"
if $TARGET_SET && [ -n "$PREFIX" ]; then
    case "$LOOKUP" in
    "$PREFIX"*) LOOKUP="${LOOKUP#"$PREFIX"}" ;;
    esac
fi

CORE=$(parse_gitcalver_version "$LOOKUP")

if [ -n "$PREFIX" ] && [ -n "$CORE" ] && [ "$LOOKUP" = "$POSITIONAL" ]; then
    die "version $POSITIONAL is missing required prefix \"$PREFIX\""
fi

find_version_commit() (
    target_date="$1"
    target_n="$2"
    branch_tip="$3"

    # Stream one first-parent log through awk. It emits a single constant-size
    # result as soon as the target date block and its older boundary are known;
    # reverse lookup therefore uses O(date-block) memory inside awk and only
    # one Git process, even when the requested version is deep in history.
    result=$(TZ=UTC git log "$branch_tip" --first-parent \
        --format='%H%x09%cd' --date=format-local:'%Y%m%d' 2>/dev/null |
        awk -F '\t' -v td="$target_date" -v tn="$target_n" '
            function emit_found(state,    idx) {
                idx = count - tn + 1
                if (idx >= 1 && idx <= count) {
                    print state, hashes[idx], last
                } else {
                    print state, "-", last
                }
                done = 1
            }
            NR > 1 && ($2 + 0) > (newer + 0) {
                print "decreasing", $2, newer
                done = 1
                exit
            }
            {
                newer = $2
                last = $1
                if ($2 == td) {
                    hashes[++count] = $1
                    next
                }
                if (($2 + 0) < (td + 0)) {
                    if (count > 0) {
                        emit_found("found")
                    } else {
                        print "notfound"
                        done = 1
                    }
                    exit
                }
            }
            END {
                if (done) exit
                if (NR == 0) {
                    print "missing"
                } else if (count > 0) {
                    emit_found("boundary")
                } else {
                    print "boundary", "-", last
                }
            }
        ')

    read -r state value detail <<EOF
$result
EOF
    state=${state:-missing}
    case "$state" in
    found)
        [ "$value" != "-" ] || die "version not found: $POSITIONAL"
        printf '%s\n' "$value"
        ;;
    notfound)
        die "version not found: $POSITIONAL"
        ;;
    decreasing)
        die "committer dates go backwards (found $value after $detail in history)"
        ;;
    boundary)
        candidate=$value
        last=$detail
        get_stored_first_parent "$last" ||
            die "local history ended before version could be proved" \
                "$EXIT_INCOMPLETE_HISTORY"
        [ -z "$STORED_FIRST_PARENT" ] ||
            die "local history ended before version could be proved" \
                "$EXIT_INCOMPLETE_HISTORY"
        [ "$candidate" != "-" ] || die "version not found: $POSITIONAL"
        printf '%s\n' "$candidate"
        ;;
    *)
        die "local history ended before version could be proved" \
            "$EXIT_INCOMPLETE_HISTORY"
        ;;
    esac
)

if [ -n "$CORE" ]; then
    TARGET_DATE=${CORE%%.*}
    TARGET_N=${CORE#*.}

    valid_gitcalver_date "$TARGET_DATE" ||
        die "invalid date in version: $POSITIONAL"

    [ "$TARGET_N" -gt 0 ] 2>/dev/null ||
        die "invalid count in version: $POSITIONAL"

    if FOUND=$(find_version_commit \
        "$TARGET_DATE" "$TARGET_N" "$DEFAULT_BRANCH_TIP"); then
        :
    else
        exit $?
    fi

    if $SHORT_HASH; then
        printf '%.7s\n' "$FOUND"
    else
        printf '%s\n' "$FOUND"
    fi
    exit 0
fi

# --- Forward computation (revision → version) ---

if $SHORT_HASH; then
    die "--short is only valid in reverse lookup mode"
fi

if $TARGET_SET; then
    # --verify is required for safety: without it, git rev-parse echoes an
    # unrecognized option-like argument (e.g. "-foo") back unchanged and exits
    # 0, so the "validation" would pass and the attacker-controlled string would
    # flow on into git merge-base/git log as an option. --verify forces a single
    # resolved revision and rejects anything that is not one.
    if REV=$(git rev-parse --verify "$POSITIONAL^{commit}" 2>/dev/null); then
        :
    elif RESOLVED_REV=$(git rev-parse --verify "$POSITIONAL" 2>/dev/null) &&
        ! git cat-file -e "$RESOLVED_REV" 2>/dev/null; then
        die "revision is missing from local history: $POSITIONAL" \
            "$EXIT_INCOMPLETE_HISTORY"
    else
        die "not a gitcalver version or git revision: $POSITIONAL"
    fi
else
    REV=$(git rev-parse --verify 'HEAD^{commit}' 2>/dev/null) ||
        die "no commits in repository"
fi

OFF_BRANCH=false
DIRTY_REV="$REV"
if BRANCH_ANCHOR=$(find_reachable_branch_anchor \
    "$REV" "$DEFAULT_BRANCH_TIP"); then
    :
else
    anchor_status=$?
    if [ "$anchor_status" -eq "$EXIT_INCOMPLETE_HISTORY" ]; then
        die "local history cannot prove the target's selected-branch relationship" \
            "$EXIT_INCOMPLETE_HISTORY"
    fi
    if ! $TARGET_SET; then
        die "cannot trace HEAD to the default branch ($DEFAULT_BRANCH)" \
            "$EXIT_NOT_TRACEABLE"
    else
        die "cannot trace $POSITIONAL to the default branch ($DEFAULT_BRANCH)" \
            "$EXIT_NOT_TRACEABLE"
    fi
fi
if [ "$BRANCH_ANCHOR" != "$REV" ]; then
    REV="$BRANCH_ANCHOR"
    OFF_BRANCH=true
fi

# --- Check dirty workspace (only for HEAD) ---

IS_DIRTY=false
if ! $TARGET_SET; then
    if $OFF_BRANCH; then
        IS_DIRTY=true
    elif [ "$IS_BARE_REPOSITORY" = "false" ]; then
        WORKTREE_STATUS=$(git status --porcelain 2>/dev/null) ||
            die "local history cannot prove workspace state" \
                "$EXIT_INCOMPLETE_HISTORY"
        [ -z "$WORKTREE_STATUS" ] || IS_DIRTY=true
    fi
elif $OFF_BRANCH; then
    IS_DIRTY=true
fi

if $IS_DIRTY && { $NO_DIRTY || ! $DIRTY_SET; }; then
    if $OFF_BRANCH; then
        die "off the default branch ($DEFAULT_BRANCH)" "$EXIT_DIRTY"
    else
        die "workspace is dirty" "$EXIT_DIRTY"
    fi
fi

# --- Compute version ---

# Walk only as far as the first different-date commit. A shallow or partial
# boundary is safe after that commit has supplied the earlier date; inside the
# target's date block it makes the count unprovable.
compute_version_fields() (
    result=$(TZ=UTC git log "$1" --first-parent \
        --format='%H%x09%cd' --date=format-local:'%Y%m%d' 2>/dev/null |
        awk -F '\t' '
            NR == 1 {
                date = $2
                count = 1
                last = $1
                next
            }
            $2 == date {
                count++
                last = $1
                next
            }
            {
                print "complete", date, count, $2
                done = 1
                exit
            }
            END {
                if (done) exit
                if (NR == 0) {
                    print "missing"
                } else {
                    print "boundary", date, count, last
                }
            }
        ')

    read -r state date count boundary_date <<EOF
$result
EOF
    state=${state:-missing}
    case "$state" in
    complete)
        if [ "$boundary_date" -gt "$date" ]; then
            die "committer dates go backwards (found $boundary_date after $date in history)"
        fi
        printf '%s %s\n' "$date" "$count"
        ;;
    boundary)
        get_stored_first_parent "$boundary_date" ||
            die "local history ended inside the target date block" \
                "$EXIT_INCOMPLETE_HISTORY"
        [ -z "$STORED_FIRST_PARENT" ] ||
            die "local history ended inside the $date date block" \
                "$EXIT_INCOMPLETE_HISTORY"
        printf '%s %s\n' "$date" "$count"
        ;;
    *)
        die "local history ended inside the target date block" \
            "$EXIT_INCOMPLETE_HISTORY"
        ;;
    esac
)

if VERSION_FIELDS=$(compute_version_fields "$REV"); then
    read -r DATE COUNT <<EOF
$VERSION_FIELDS
EOF
else
    exit $?
fi

# --- Format output ---

VERSION="${PREFIX}${DATE}.${COUNT}"

if $IS_DIRTY; then
    if $NO_DIRTY_HASH; then
        printf '%s%s\n' "$VERSION" "$DIRTY_STRING"
    else
        HASH=$(printf '%.7s' "$DIRTY_REV")
        printf '%s%s.%s\n' "$VERSION" "$DIRTY_STRING" "$HASH"
    fi
else
    printf '%s\n' "$VERSION"
fi
