#!/usr/bin/env bash
set -euo pipefail

usage() { echo "usage: $0 [commit|push|pr-ready]" >&2; }

if (( $# > 1 )); then
  usage
  exit 2
fi

mode="${1:-commit}"
case "$mode" in
  commit|push|pr-ready) ;;
  *)
    usage
    exit 2
    ;;
esac

# pr-ready is a synonym for push: the safety gate does not select lint/test/build lanes.
[[ "$mode" == "pr-ready" ]] && mode="push"

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

tmp_root=""

finalize() {
  local original_exit_code=$?
  set +e
  trap - EXIT HUP INT TERM
  if [[ -n "${tmp_root:-}" ]]; then
    rm -rf -- "$tmp_root"
  fi
  exit "$original_exit_code"
}

trap finalize EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

log() { printf '\n==> %s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

require_tool() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required tool '$1'. Install it before committing or pushing."
}

ensure_tmp_root() {
  if [[ -z "$tmp_root" ]]; then
    tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/rpce-preflight.XXXXXX")"
  fi
}

scan_staged_index_blobs() {
  local files snapshot
  ensure_tmp_root
  files="$tmp_root/staged-files.z"
  snapshot="$tmp_root/staged-index"
  git diff --cached --name-only --diff-filter=d -z -- > "$files"
  if [[ ! -s "$files" ]]; then
    echo "No non-deleted staged index blobs to scan."
    return
  fi
  mkdir -p "$snapshot"
  git checkout-index --stdin -z --prefix="$snapshot/" < "$files"
  gitleaks dir --no-banner --redact "$snapshot"
}

# Untracked local investigation reports stay unignored for RepoPrompt tooling and
# must not block push. Tracked edits there, and untracked files anywhere else, still fail.
worktree_status_is_exempt() {
  local status_entry="$1"
  [[ "$status_entry" == '?? docs/investigations/'* ]]
}

require_clean_worktree() {
  local status_file entry unexpected=0
  ensure_tmp_root
  status_file="$tmp_root/status.z"
  git status --porcelain=v1 -z --untracked-files=all > "$status_file"
  while IFS= read -r -d '' entry; do
    [[ -n "$entry" ]] || continue
    if worktree_status_is_exempt "$entry"; then
      printf 'note: ignoring untracked local investigation artifact: %s\n' "${entry#?? }" >&2
      continue
    fi
    unexpected=1
  done < "$status_file"
  if (( unexpected )); then
    git status --short
    fail "working tree is not clean; commit, stash, or discard changes before pushing"
  fi
}

resolve_outgoing_base() {
  current_branch="$(git symbolic-ref --quiet --short HEAD)" \
    || fail "push mode requires a current branch; detached HEAD is not supported"
  if upstream_ref="$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)" \
    && git rev-parse --verify --quiet "${upstream_ref}^{commit}" >/dev/null; then
    base_ref="$upstream_ref"
    base_reason="configured upstream"
  elif [[ "$current_branch" != "main" ]] \
    && git rev-parse --verify --quiet 'refs/remotes/origin/main^{commit}' >/dev/null; then
    base_ref="refs/remotes/origin/main"
    base_reason="origin/main fallback for a current branch without configured upstream"
  else
    fail "cannot determine outgoing base for '$current_branch'; configure its upstream or fetch origin/main for a non-main topic branch"
  fi
  range_spec="$base_ref..HEAD"
}

push_success() {
  cat <<'EOF'

Safety preflight passed.
This gate is whitespace, secrets, and guardrails only.
Run focused checks yourself when the change needs them: make dev-test, make dev-lint, make xcode-generator-test.
Push mode validated only the current branch against the computed range above.
EOF
}

require_tool git
require_tool gitleaks

log "Check whitespace"
git diff --check
git diff --cached --check

log "Scan staged index blobs for secrets"
scan_staged_index_blobs

log "Run repository guardrails"
make guardrails

if [[ "$mode" == "commit" ]]; then
  cat <<'EOF'

Commit preflight passed.
Before committing, review `git status --short`, `git diff --cached --stat`, and `git diff --cached`.
Rerun commit preflight after any staging change. Use `push` mode before pushing committed work.
EOF
  exit 0
fi

log "Require a clean working tree before push"
require_clean_worktree

resolve_outgoing_base
log "Review current-branch outgoing range"
printf 'Current branch: %s\nComparison base (%s): %s\nComputed outgoing range: %s\n' \
  "$current_branch" "$base_reason" "$base_ref" "$range_spec"
git log --oneline "$range_spec"

outgoing_count="$(git rev-list --count "$range_spec")"
if [[ "$outgoing_count" == "0" ]]; then
  echo "No outgoing commits in $range_spec."
  push_success
  exit 0
fi

log "Scan outgoing commit range for secrets"
gitleaks git --no-banner --redact --log-opts="$range_spec" .
push_success
