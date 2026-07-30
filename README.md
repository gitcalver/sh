# gitcalver.sh

A portable POSIX shell implementation of [GitCalVer](https://gitcalver.org),
which derives calendar-based version numbers from git history.

Each commit on the default branch's first-parent chain gets a unique, strictly
increasing version of the form `YYYYMMDD.N`. `N` is the size of the commit's
**date cohort**: the commits reachable from it through any parent, visiting
each one once, where a same-UTC-date commit is counted and its parents
explored, and a strictly older commit is visited only to learn its date, not
explored past. A merge therefore counts the same-date commits it brings in
through its non-first parents too, not just the commits on the first-parent
chain itself.

Because commits are versioned by date cohort rather than position in a run,
the sequence of `N` values for a given date can be **sparse**: not every
integer between the lowest and highest cohort size for a date necessarily
belongs to a commit. Reverse lookup returns an exact match or fails; it never
rounds to the nearest existing version.

See the [GitCalVer specification](https://gitcalver.org) for full details.

## Installation

The only dependency is git (v2.15.0+).

Copy `gitcalver.sh` into your project or somewhere on your `PATH`:

```sh
curl -fsSLO https://github.com/gitcalver/sh/releases/latest/download/gitcalver.sh
chmod +x gitcalver.sh
```

## Usage

```
gitcalver [OPTIONS] [REVISION | VERSION]
```

With no arguments, outputs the version for HEAD:

```sh
$ ./gitcalver.sh
20260411.3
```

When no target is supplied, gitcalver also checks the workspace for uncommitted
changes. An explicit revision—including `HEAD`—describes only that commit and
ignores workspace state. Bare repositories are supported.

### Version prefix

Use `--prefix` to prepend a single-line literal string to the version number,
e.g.:

| Use case | Command                      | Example output     |
|----------|------------------------------|--------------------|
| Default  | `gitcalver`                  | `20260411.3`       |
| SemVer   | `gitcalver --prefix "0."`    | `0.20260411.3`     |
| Go       | `gitcalver --prefix "v0."`   | `v0.20260411.3`    |

### Dirty workspace

By default, gitcalver exits with status 2 if the workspace has uncommitted
changes. Use `--dirty STRING` to produce a version instead; the output will
include the given string and a short commit hash
(e.g. `--dirty "-dirty"` produces `20260411.3-dirty.abc1234`). The hash is
always the first seven lowercase characters of the target object ID, regardless
of Git abbreviation settings or other objects in the repository.

Use `--no-dirty-hash` with `--dirty` to suppress the hash suffix.
Use `--no-dirty` to explicitly refuse dirty versions (overrides `--dirty`).

Dirty versions are a convenience and are not necessarily unique.

### Reverse lookup

Pass a version number instead of a revision to get the corresponding commit hash:

```sh
$ ./gitcalver.sh 20260411.3
a1b2c3d4e5f6...

$ ./gitcalver.sh --short --prefix "0." 0.20260411.3
a1b2c3d
```

Reverse lookup outputs the full object ID by default; `--short` outputs its
first seven characters. An exact version-shaped input takes precedence over a
same-named Git ref.

Because the sequence is sparse, a version that falls in a gap is not rounded
to a neighboring commit: gitcalver reports "version not found" and exits 1.

When `--prefix` is set, the prefix is required on the input version for reverse
lookup; bare versions without the prefix are rejected.

Dirty versions cannot be reversed.

### Incomplete histories

Version calculation never fetches. A commit's date cohort is provable from
local objects alone when every same-date path from it either reaches a real
root or runs into an older-dated commit, without needing to look past that
older commit — an older-dated boundary needs no further proof regardless of
whether it is itself a shallow or partial-clone cut, since the walk never
explores past it. A same-date commit that appears to have no parent must be
distinguished as a real root or a shallow cut; if local history cannot make
that distinction, or a commit needed to prove the cohort is missing entirely,
gitcalver exits with status 4. Deepen or fetch the repository explicitly
before retrying.

Missing trees and blobs do not affect calculation. Replacement refs are
ignored, and repositories with a legacy `info/grafts` file are rejected because
those mechanisms rewrite commit ancestry.

### Options

| Option              | Description                                    |
|---------------------|------------------------------------------------|
| `--prefix PREFIX`   | Literal string prepended to version            |
| `--dirty STRING`    | Enable dirty versions; append STRING.HASH      |
| `--no-dirty`        | Refuse dirty versions (overrides `--dirty`)    |
| `--no-dirty-hash`   | Suppress .HASH suffix (requires `--dirty`)     |
| `--branch BRANCH`   | Base branch name (e.g. `main`); overrides auto-detection. This is the branch versions are minted on, not the branch you are working on. |
| `--remote REMOTE`   | Remote used for cached branch detection (default: `origin`); never fetches |
| `--short`           | Output first seven object-ID characters in reverse mode |
| `--version`         | Show version information                       |
| `--help`            | Show help                                      |

## GitHub Actions

```yaml
- uses: gitcalver/sh@main
  id: version
  with:
    prefix: 'v'
```

The `remote` input selects the cached remote used for branch detection; version
calculation does not fetch it. Outputs are `version`, `date`, `count`, `dirty`,
`hash`, and `tag`. The `tag` output is `tag-prefix` followed by `version`, which
lets a package version such as `0.20260411.3` use a tag such as
`v0.20260411.3`.

### Tagging

Set `tag: true` to create and push a lightweight git tag:

```yaml
permissions:
  contents: write

concurrency: release

steps:
  - uses: actions/checkout@v6
    with:
      fetch-depth: 0
  - uses: gitcalver/sh@main
    id: version
    with:
      prefix: '0.'
      tag-prefix: 'v'
      tag: 'true'
```

Publication refreshes the selected branch and the matching tags from `remote`,
then requires HEAD to be its current tip. The numerically greatest matching
tag's target must remain reachable from HEAD through any parent, with a
committer date no later than HEAD's own, and its date segment must match its
commit. The new lightweight tag is claimed without force; a matching tag at
HEAD makes a workflow retry succeed idempotently, while any mismatch fails.

### Exit codes

| Code | Meaning                                                           |
|------|-------------------------------------------------------------------|
| 0    | Success                                                           |
| 1    | Invalid input, repository state, version date, or commit history   |
| 2    | Dirty workspace or off-chain target refused without `--dirty`      |
| 3    | Target cannot be traced to the selected branch                     |
| 4    | Local history cannot prove membership, anchor, or the target's date cohort |
