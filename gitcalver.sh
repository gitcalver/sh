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
# the repository's actual object graph. Git must also use the shallow and graft
# files checked below, and honor core.commitGraph=false.
GIT_NO_LAZY_FETCH=1
GIT_NO_REPLACE_OBJECTS=1
export GIT_NO_LAZY_FETCH GIT_NO_REPLACE_OBJECTS
unset GIT_SHALLOW_FILE GIT_GRAFT_FILE GIT_TEST_COMMIT_GRAPH

# --- Verify git repository ---

# Resolve repository metadata through the common directory so linked worktrees
# see the same shallow boundary and deprecated graft file as the main worktree.
GIT_COMMON_DIR=$(git rev-parse --git-common-dir 2>/dev/null) ||
    die "not a git repository"
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

# --- Determine and verify default branch ---

# These helpers run in ( ) subshells, not { } blocks, so scratch variables stay
# function-local without the non-POSIX `local` keyword; each communicates only
# through stdout and its exit status.

# Keep in lockstep with detect_branch in action/publish.sh.
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

    # 3. Check the selected remote's main and master, then local main and
    # master
    for candidate in "refs/remotes/$REMOTE/main" "refs/remotes/$REMOTE/master" \
        refs/heads/main refs/heads/master; do
        if git rev-parse --verify "$candidate" >/dev/null 2>&1; then
            printf '%s\n' "${candidate##*/}"
            exit 0
        fi
    done

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

# A commit that a bulk Git traversal treated as parentless is a genuine root
# only if its stored object is present locally and lists no parent; a missing
# object or a stored parent means the traversal stopped at a shallow or
# partial-clone cut instead. Used only after a traversal has stopped; never
# called once per commit.
is_genuine_root() (
    commit_object=$(git cat-file commit "$1" 2>/dev/null) || exit 1
    # Anchor to the start of the line: header continuation lines (gpgsig,
    # mergetag) begin with a single space that awk's default field splitting
    # strips, so an unanchored $1 == "parent" would take a continuation line
    # whose text starts with that word for a real parent header and
    # misclassify a genuine root as incomplete history.
    printf '%s\n' "$commit_object" |
        awk '/^$/ { exit 0 } /^parent / { exit 1 }'
)

# A negative reachability result is conclusive only when the target's known
# ancestry did not stop at a shallow boundary and did not encounter a missing
# promised commit.
history_is_complete() (
    git rev-list "$1" -- >/dev/null 2>&1 || exit "$EXIT_INCOMPLETE_HISTORY"
    [ -f "$SHALLOW_FILE" ] || exit 0

    while IFS= read -r boundary; do
        [ -n "$boundary" ] || continue
        if git merge-base --is-ancestor "$boundary" "$1" 2>/dev/null; then
            is_genuine_root "$boundary" ||
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
        "$branch_tip" "^$rev" -- 2>/dev/null) ||
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
    is_genuine_root "$last_unreachable" || exit "$EXIT_INCOMPLETE_HISTORY"

    # The selected walk reached a real root. The histories are conclusively
    # unrelated only if the target walk is complete as well.
    history_is_complete "$rev" || exit "$EXIT_INCOMPLETE_HISTORY"
    exit "$EXIT_NOT_TRACEABLE"
)

# Howard Hinnant's civil_from_days. A timestamp too large for shell arithmetic
# is printed unchanged.
utc_date() (
    case "$1" in
    ????????????????*)
        printf '%s\n' "$1"
        exit 0
        ;;
    esac
    days=$(($1 / 86400 + 719468))
    era=$((days / 146097))
    doe=$((days - era * 146097))
    yoe=$(((doe - doe / 1460 + doe / 36524 - doe / 146096) / 365))
    doy=$((doe - (365 * yoe + yoe / 4 - yoe / 100)))
    mp=$(((5 * doy + 2) / 153))
    month=$((mp < 10 ? mp + 3 : mp - 9))
    printf '%04d%02d%02d\n' "$((era * 400 + yoe + (month <= 2)))" \
        "$month" "$((doy - (153 * mp + 2) / 5 + 1))"
)

# Howard Hinnant's days_from_civil, for a valid YYYYMMDD date. The leading 1
# keeps shell arithmetic from reading a zero-padded field as octal.
epoch_day() (
    year=$((1${1%????} - 10000))
    month_day=$((1${1#????} - 10000))
    month=$((month_day / 100))
    day=$((month_day % 100))
    year=$((year - (month <= 2)))
    era=$((year / 400))
    yoe=$((year - era * 400))
    doy=$(((153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1))
    echo $((era * 146097 + yoe * 365 + yoe / 4 - yoe / 100 + doy - 719468))
)

die_decreasing() {
    die "committer dates go backwards (found $(utc_date "$1") after $(utc_date "$2") in history)"
}

die_unprovable() {
    die "local history cannot prove the target date cohort" \
        "$EXIT_INCOMPLETE_HISTORY"
}

# Without exclusions or ordering options, rev-list streams its walk and skips
# each commit older than --since without queueing its parents, so the only
# older commits it reads are those that bound the walk. Do not add a
# ^exclusion or an ordering option: either switches git to a limited walk,
# which hides a same-date commit that is also behind an older one. The
# commit-graph lets git walk past commits whose objects are missing, so every
# commit is read from its object instead. --since=@<epoch> +0000 is parsed
# exactly; git before 2.43.1 reads --max-age with atoi, which overflows after
# January 2038.
date_walk() (
    since=$1
    shift
    git -c core.commitGraph=false rev-list --timestamp --parents \
        --since="@$since +0000" "$@" -- 2>/dev/null
)

boundary_oids() {
    printf '%s\n' "$1" | awk '$2 ~ /^-/ { print substr($2, 2) }'
}

# The walk skips a commit as older by git's parse of its header, which reads
# a malformed commit's date (one with no author line, say) as 0 or a partial
# number. A commit whose date the result depends on, the target or one the
# walk skipped, must read the same through %ct, from its committer line.
check_dates() (
    [ -n "$1" ] || exit 0
    listing=$(printf '%s\n' "$1" | git -c core.commitGraph=false rev-list \
        --no-walk --stdin --timestamp --format='date %ct' -- 2>/dev/null) ||
        die_unprovable
    bad=$(printf '%s\n' "$listing" | awk '
        $2 == "commit" && oid == "" {
            stamp = $1 ""
            oid = $3
            next
        }
        oid != "" && $1 == "date" && NF == 2 && $2 "" == stamp {
            oid = ""
            next
        }
        {
            print (oid == "" ? "unknown" : oid)
            failed = 1
            exit
        }
        END { if (!failed && oid != "") print oid }
    ')
    [ -z "$bad" ] || die "malformed committer date in commit $bad"
)

# Each member in $4 (oldest first) is on the first-parent chain of the next,
# so each cohort contains the preceding ones: the visited set carries over
# and counts each commit once. Walk $1 must start from the newest member.
count_cohorts() (
    # Git lists a shallow cut as parentless, like a root.
    cuts=$(printf '%s\n' "$1" | awk 'NF == 2 && $2 !~ /^-/ { print $2 }' |
        while IFS= read -r oid; do
            is_genuine_root "$oid" || printf 'cut %s\n' "$oid"
        done)
    result=$({
        printf '%s\n' "$4" | sed 's/^/member /'
        printf '%s\n' "$1"
        printf '%s\n' "$cuts"
    } | awk -v next_midnight="$2" -v target_n="$3" '
        function add_cohort(oid, qn, i, cur, n, p, j, unprovable) {
            if (!(oid in stamp)) {
                print "missing"
                exit
            }
            qn = 1
            queue[1] = oid
            seen[oid] = 1
            for (i = 1; i <= qn; i++) {
                cur = queue[i]
                # A parent missing from the walk is one git skipped as older.
                if (!(cur in stamp)) continue
                if (stamp[cur] + 0 >= next_midnight + 0) {
                    print "decreasing", stamp[cur]
                    exit
                }
                count++
                if (cur in cut) {
                    unprovable = 1
                    continue
                }
                n = split(parents[cur], p, " ")
                for (j = 1; j <= n; j++) {
                    if (p[j] in seen) continue
                    seen[p[j]] = 1
                    queue[++qn] = p[j]
                }
            }
            # Report a shallow cut only once the cohort is known to contain
            # no newer commit, which takes precedence.
            if (unprovable) {
                print "unprovable"
                exit
            }
        }
        $1 == "member" { member[++members] = $2; next }
        $1 == "cut" { cut[$2] = 1; next }
        NF >= 2 && $2 !~ /^-/ {
            stamp[$2] = $1 ""
            for (i = 3; i <= NF; i++) parents[$2] = parents[$2] " " $i
        }
        END {
            for (m = 1; m <= members; m++) {
                add_cohort(member[m])
                if (target_n == "") continue
                if (count == target_n + 0) {
                    print "found", member[m]
                    exit
                }
                if (count > target_n + 0) {
                    print "notfound"
                    exit
                }
            }
            print "count", count
        }
    ') || exit $?
    read -r state value <<EOF
$result
EOF
    case "$state" in
    count | found | notfound) printf '%s\n' "$result" ;;
    decreasing) die_decreasing "$value" "$(($2 - 86400))" ;;
    *) die_unprovable ;;
    esac
)

compute_version_core() (
    start=$(date_walk 0 --no-walk "$1") || die_unprovable
    start=${start%% *}
    date=$(utc_date "$start")
    case "$date" in
    [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) ;;
    *) die "committer date out of range: $start" ;;
    esac
    start=$((start - start % 86400))

    walk=$(date_walk "$start" --boundary "$1") || die_unprovable
    check_dates "$1
$(boundary_oids "$walk")" || exit $?
    result=$(count_cohorts "$walk" "$((start + 86400))" "" "$1") || exit $?
    printf '%s.%s\n' "$date" "${result#count }"
)

find_version_commit() (
    day=$(epoch_day "$1")
    next_midnight=$(((day + 1) * 86400))
    # Git cannot store a commit date before 1970; walk the whole chain.
    start=$((day < 0 ? 0 : day * 86400))

    # Delimit the target date's block on the first-parent chain and prove its
    # older boundary: git read the first parent it skipped, or the chain ends
    # at the last commit listed. The commits git lists before failing on a
    # missing object still prove that dates go backwards.
    block=$({ date_walk "$start" --first-parent "$3" || echo failed; } |
        awk -v next_midnight="$next_midnight" '
            $1 == "failed" {
                print "failed"
                done = 1
                exit
            }
            NR > 1 && int($1 / 86400) > int(newer / 86400) {
                print "decreasing", $1, newer
                done = 1
                exit
            }
            {
                newer = $1 ""
                root = NF == 2 ? $2 : "-"
                skipped = NF > 2 ? $3 : "-"
                if ($1 + 0 >= next_midnight + 0) next
                member[++count] = $2
            }
            END {
                if (done) exit
                if (NR == 0) {
                    print "empty"
                    exit
                }
                print "chain", root, skipped, count + 0
                for (i = count; i >= 1; i--) print member[i]
            }
        ')
    read -r state newer older <<EOF
$block
EOF
    case "$state" in
    decreasing) die_decreasing "$newer" "$older" ;;
    failed) die_unprovable ;;
    empty) die "version not found: $POSITIONAL" ;;
    esac
    read -r _ root skipped total <<EOF
$block
EOF
    [ "$root" = - ] || is_genuine_root "$root" || die_unprovable
    if [ "$total" -eq 0 ]; then
        [ "$skipped" = - ] || check_dates "$skipped" || exit $?
        die "version not found: $POSITIONAL"
    fi
    members=$(printf '%s\n' "$block" | sed 1d)

    # A missing object fails git's whole walk, but cannot change versions
    # whose cohorts do not reach it. Each member's walk contains the walks of
    # older members, so failures are monotonic along the block: binary search,
    # starting from the newest member, finds the newest member whose walk
    # succeeds.
    known=0
    failed=$((total + 1))
    mid=$total
    while [ $((failed - known)) -gt 1 ]; do
        if probe=$(date_walk "$start" --boundary \
            "$(printf '%s\n' "$members" | sed -n "${mid}p")"); then
            known=$mid
            walk=$probe
        else
            failed=$mid
        fi
        mid=$(((known + failed) / 2))
    done
    [ "$known" -gt 0 ] || die_unprovable
    check_dates "$(boundary_oids "$walk")" || exit $?

    result=$(count_cohorts "$walk" "$next_midnight" "$2" \
        "$(printf '%s\n' "$members" | sed "${known}q")") || exit $?
    read -r state value <<EOF
$result
EOF
    case "$state" in
    found) printf '%s\n' "$value" ;;
    notfound) die "version not found: $POSITIONAL" ;;
    *)
        [ "$known" -eq "$total" ] || die_unprovable
        die "version not found: $POSITIONAL"
        ;;
    esac
)

# Cache the selected branch tip once so every calculation in this invocation
# uses the same local view even if another process updates a ref concurrently.
# A remote-tracking ref can name an annotated tag, so keep the commit it peels
# to.
DEFAULT_BRANCH_TIP=$(resolve_branch_tip "$DEFAULT_BRANCH") ||
    die "cannot resolve default branch: $DEFAULT_BRANCH"
DEFAULT_BRANCH_TIP=$(git rev-parse --verify \
    "$DEFAULT_BRANCH_TIP^{commit}" 2>/dev/null) ||
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
# than falling through to revision parsing. Keep in lockstep with valid_date
# in action/publish.sh.
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
    # flow on into git rev-list/git merge-base as an option. --verify forces a
    # single resolved revision and rejects anything that is not one.
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
if $OFF_BRANCH; then
    IS_DIRTY=true
elif ! $TARGET_SET; then
    # A plain command substitution used only as a test's operand is never
    # checked by `set -e`; capture it as its own statement first so a failure
    # here dies instead of silently reading as an empty, non-bare-matching
    # string and skipping the workspace check below.
    IS_BARE_REPOSITORY=$(git rev-parse --is-bare-repository) ||
        die "cannot determine whether repository is bare"
    if [ "$IS_BARE_REPOSITORY" = "false" ]; then
        WORKTREE_STATUS=$(git status --porcelain 2>/dev/null) ||
            die "local history cannot prove workspace state" \
                "$EXIT_INCOMPLETE_HISTORY"
        [ -z "$WORKTREE_STATUS" ] || IS_DIRTY=true
    fi
fi

if $IS_DIRTY && { $NO_DIRTY || ! $DIRTY_SET; }; then
    if $OFF_BRANCH; then
        die "off the default branch ($DEFAULT_BRANCH)" "$EXIT_DIRTY"
    else
        die "workspace is dirty" "$EXIT_DIRTY"
    fi
fi

# --- Compute version ---

if VERSION_CORE=$(compute_version_core "$REV"); then
    :
else
    exit $?
fi

# --- Format output ---

VERSION="${PREFIX}${VERSION_CORE}"

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
