#!/usr/bin/env bash
# Publishes a scrubbed snapshot of committed HEAD to the public repo (timharris707/faceidunlock), the
# ModelDeck pattern: this repo stays private; the mirror gets one "Sync" commit per release, with no
# history, no personal email and none of the internal notes listed in STRIPPED_PATHS.
#
# Usage: scripts/sync-mirror.sh [--check-only] [--push] MIRROR_DIR MESSAGE
#   MIRROR_DIR  a clone of the public repo (git clone https://github.com/timharris707/faceidunlock)
#   MESSAGE     usually "release X.Y.Z"
# FID_SCRUB_PATTERNS names the private-terms file (default scripts/mirror-scrub-patterns.txt): one extended
# regular expression per line, matched case-insensitively; any match stops the sync.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
fail() { echo "sync-mirror.sh: ERROR: $*" >&2; exit 1; }

CHECK_ONLY=0 PUSH=0 POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check-only) CHECK_ONLY=1 ;;
    --push) PUSH=1 ;;
    -*) fail "unknown argument: $1" ;;
    *) POSITIONAL+=("$1") ;;
  esac
  shift
done
[[ ${#POSITIONAL[@]} -eq 2 ]] || fail "usage: $0 [--check-only] [--push] MIRROR_DIR MESSAGE"
[[ "$CHECK_ONLY" == 0 || "$PUSH" == 0 ]] || fail "--push cannot be combined with --check-only"
MIRROR_DIR="${POSITIONAL[0]}" MESSAGE="${POSITIONAL[1]}"
PATTERN_FILE="${FID_SCRUB_PATTERNS:-$REPO_ROOT/scripts/mirror-scrub-patterns.txt}"
[[ -r "$PATTERN_FILE" ]] || fail "scrub-pattern file is not readable: $PATTERN_FILE"

DIRTY="$(git -C "$REPO_ROOT" status --porcelain)"
[[ -z "$DIRTY" ]] || { echo "sync-mirror.sh: ERROR: source tree is dirty; commit these first:" >&2; echo "$DIRTY" >&2; exit 1; }

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/faceidunlock-mirror.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT
SNAPSHOT="$WORK_DIR/snapshot" ACTIVE_PATTERNS="$WORK_DIR/patterns"
mkdir -p "$SNAPSHOT"
echo "==> archiving committed HEAD ($(git -C "$REPO_ROOT" rev-parse --short HEAD))"
git -C "$REPO_ROOT" archive HEAD | tar -x -C "$SNAPSHOT"

# Internal working material: agent instructions, design logs, research, review and verification notes,
# positioning, the internal work-item template, the website source and this script's private-terms file.
# Kept: docs/images (README pictures), docs/design/icon (icon build), and the two model notes plus the
# evidence file that the code and tests point to.
STRIPPED_PATHS=(
  ".claude"
  "CLAUDE.md"
  "AGENTS.md"
  ".github/ISSUE_TEMPLATE/work-item.md"
  "docs/agents"
  "docs/positioning.md"
  "docs/research"
  "docs/design/2026-10-overhaul-plan.md"
  "docs/design/guided-enrollment.md"
  "docs/verification/2026-10-29-live-failure-review.md"
  "docs/verification/app-smoke.md"
  "docs/verification/automatic-fill.md"
  "docs/verification/continuous-enrollment.md"
  "docs/verification/prompt-compatibility.md"
  "docs/verification/review.md"
  "site"
  "scripts/mirror-scrub-patterns.txt"
)
for path in "${STRIPPED_PATHS[@]}"; do rm -rf -- "${SNAPSHOT:?}/$path"; done

# Tripwire: code or a test that loads a stripped file would break in the public repo.
for path in "${STRIPPED_PATHS[@]}"; do
  if grep -rlF --include='*.swift' "appendingPathComponent(\"$path" "$SNAPSHOT" >/dev/null 2>&1; then
    fail "a surviving Swift file loads stripped path $path"
  fi
done

awk 'NF && $0 !~ /^[[:space:]]*#/' "$PATTERN_FILE" > "$ACTIVE_PATTERNS"
scrub_gate() {
  local matches status=0
  matches="$(git -C "$1" grep --cached -a -i -l -E -f "$ACTIVE_PATTERNS" -- . 2>/dev/null)" || status=$?
  [[ "$status" -le 1 ]] || fail "scrub grep failed; check the patterns in $PATTERN_FILE"
  if [[ -n "$matches" ]]; then
    echo "sync-mirror.sh: ERROR: private terms found in these files:" >&2
    echo "$matches" >&2
    exit 1
  fi
}
# Stage the snapshot in its own repository so the gate sees exactly what would be committed.
git -C "$SNAPSHOT" init -q && git -C "$SNAPSHOT" add -A
scrub_gate "$SNAPSHOT"
echo "==> scrub gate passed ($(git -C "$SNAPSHOT" ls-files | wc -l | tr -d ' ') files)"
if [[ "$CHECK_ONLY" == 1 ]]; then echo "==> check only; mirror not touched"; exit 0; fi

MIRROR_DIR="$(git -C "$MIRROR_DIR" rev-parse --show-toplevel 2>/dev/null)" || fail "not a git working tree: $MIRROR_DIR"
[[ "$MIRROR_DIR" != "$REPO_ROOT" ]] || fail "the mirror must not be this checkout"
[[ -z "$(git -C "$MIRROR_DIR" status --porcelain)" ]] || fail "mirror clone is dirty"
echo "==> syncing snapshot into $MIRROR_DIR"
rsync -a --delete --exclude=.git/ "$SNAPSHOT/" "$MIRROR_DIR/"
git -C "$MIRROR_DIR" add -A
scrub_gate "$MIRROR_DIR"
if git -C "$MIRROR_DIR" diff --cached --quiet; then
  echo "==> mirror already matches; no commit"
else
  GIT_AUTHOR_NAME="Face ID Unlock Mirror Sync" GIT_AUTHOR_EMAIL="mirror-sync@example.invalid" \
    GIT_COMMITTER_NAME="Face ID Unlock Mirror Sync" GIT_COMMITTER_EMAIL="mirror-sync@example.invalid" \
    git -C "$MIRROR_DIR" -c commit.gpgsign=false commit -q -m "Sync: $MESSAGE"
  echo "==> committed: $(git -C "$MIRROR_DIR" log --oneline -1)"
fi
if [[ "$PUSH" == 1 ]]; then git -C "$MIRROR_DIR" push -q origin HEAD; echo "==> pushed"; else echo "==> not pushed (pass --push)"; fi
