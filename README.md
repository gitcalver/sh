# gitcalver.sh

A portable POSIX shell implementation of [GitCalVer](https://gitcalver.org),
which derives calendar-based version numbers from git history.

Each commit on the default branch gets a unique, strictly increasing version of
the form `YYYYMMDD.N`, where `N` is the number of commits on that UTC date.

See the [GitCalVer specification](https://gitcalver.org) for full details.

## Installation

The only dependency is git (v2.15.0+).

Copy `gitcalver.sh` into your project or somewhere on your `PATH`:

```sh
curl -fsSL https://raw.githubusercontent.com/gitcalver/sh/main/gitcalver.sh -o gitcalver.sh
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

### Version prefix

Use `--prefix` to prepend a string to the version number, e.g.:

| Use case | Command                      | Example output     |
|----------|------------------------------|--------------------|
| Default  | `gitcalver`                  | `20260411.3`       |
| SemVer   | `gitcalver --prefix "0."`    | `0.20260411.3`     |
| Go       | `gitcalver --prefix "v0."`   | `v0.20260411.3`    |

### Dirty workspace

By default, gitcalver exits with status 2 if the workspace has uncommitted
changes. Use `--dirty STRING` to produce a version instead; the output will
include the given string and a short commit hash
(e.g. `--dirty "-dirty"` produces `20260411.3-dirty.abc1234`).

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

When `--prefix` is set, the prefix is required on the input version for reverse lookup; bare versions without the prefix are rejected.

Dirty versions cannot be reversed.

### Options

| Option              | Description                                    |
|---------------------|------------------------------------------------|
| `--prefix PREFIX`   | Literal string prepended to version            |
| `--dirty STRING`    | Enable dirty versions; append STRING.HASH      |
| `--no-dirty`        | Refuse dirty versions (overrides `--dirty`)    |
| `--no-dirty-hash`   | Suppress .HASH suffix (requires `--dirty`)     |
| `--branch BRANCH`   | Base branch name (e.g. `main`); overrides auto-detection. This is the branch versions are minted on, not the branch you are working on. |
| `--short`           | Output short commit hash (reverse lookup mode) |
| `--help`            | Show help                                      |

## GitHub Actions

```yaml
- uses: gitcalver/sh@main
  id: version
  with:
    prefix: 'v'
```

Outputs: `version`, `date`, `count`, `dirty`, `hash`.

### Tagging

Set `tag: true` to create and push a lightweight git tag:

```yaml
permissions:
  contents: write

steps:
  - uses: actions/checkout@v6
    with:
      fetch-depth: 0
  - uses: gitcalver/sh@main
    with:
      prefix: 'v'
      tag: 'true'
```

The tag name is the full version string (including any prefix). Dirty versions
are never tagged. If the tag already exists at HEAD (e.g. on a workflow re-run),
the step succeeds without creating a duplicate.

### Exit codes

| Code | Meaning                                |
|------|----------------------------------------|
| 0    | Success                                |
| 1    | Error (not a git repo, no commits, non-monotonic dates) |
| 2    | Dirty workspace or off default branch (without `--dirty`) |
| 3    | Cannot trace to default branch         |
