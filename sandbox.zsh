# Claude sandbox helpers. Source from ~/.zshrc:
#   source /Volumes/Devel/apple/claude-sandbox/sandbox.zsh

SBX_DIR="${0:A:h}"

# sbx <repo-dir> [claude args]   run Claude Code in the sandbox against a repo
sbx() { "$SBX_DIR/run.sh" "$@"; }

# sbx-shell <repo-dir>           same sandbox, plain bash instead of claude
sbx-shell() { "$SBX_DIR/run.sh" "${1:?repo dir}" bash; }

# sbx-build                      rebuild the image after editing the Dockerfile
sbx-build() {
  container builder status >/dev/null 2>&1 || container builder start --dns 1.1.1.1 --cpus 4 --memory 4g
  container build -t claude-sandbox "$SBX_DIR"
}

# sbx-key                        store a dedicated, spend-capped API key in Keychain
sbx-key() {
  local key
  read -rs "key?Sandbox Anthropic API key (not echoed): "; echo
  [[ -n "$key" ]] || { echo "empty, aborting" >&2; return 1; }
  security add-generic-password -a "$USER" -s claude-sandbox -w "$key" -U \
    && echo "stored in Keychain as 'claude-sandbox'"
}

# sbx-clone <owner/repo|url> [dest]   clone + all PR heads + PR metadata
sbx-clone() {
  local repo="${1:?owner/repo or https url}" dest="${2:-}" slug
  slug="${repo#https://github.com/}"; slug="${slug%.git}"; slug="${slug%/}"
  [[ "$slug" == */* && "$slug" != *://* ]] || { echo "need owner/repo or https://github.com/owner/repo" >&2; return 1; }
  dest="${dest:-${slug##*/}}"
  [[ -e "$dest" ]] && { echo "'$dest' already exists" >&2; return 1; }

  git clone --no-recurse-submodules "https://github.com/$slug.git" "$dest" || return 1
  git -C "$dest" fetch origin '+refs/pull/*/head:refs/remotes/origin/pr/*'
  echo "PR heads fetched: $(git -C "$dest" branch -r | grep -c 'origin/pr/')"

  if command -v gh >/dev/null; then
    mkdir -p "$dest/.pr-meta"
    gh pr list -R "$slug" --state all --limit 1000 \
      --json number,title,author,state,createdAt,headRefName,headRepository,body,url \
      > "$dest/.pr-meta/pulls.json"
    gh api --paginate "repos/$slug/pulls/comments"  > "$dest/.pr-meta/review-comments.json"
    gh api --paginate "repos/$slug/issues/comments" > "$dest/.pr-meta/issue-comments.json"
    echo "PR metadata in $dest/.pr-meta/"
  else
    echo "gh not installed, skipped PR metadata" >&2
  fi
  echo "next: sbx $dest"
}

# sbx-out                        list run outputs, newest first
sbx-out() { ls -1t "${SBX_OUT_ROOT:-$HOME/sandbox/out}"; }

# sbx-clean                      remove stopped sandbox containers (normally none, --rm)
sbx-clean() { container ls -a 2>/dev/null | awk '$2 ~ /claude-sandbox/ && $5 != "running" {print $1}' | xargs -r container rm; }

if (( $+functions[compdef] )); then compdef '_files -/' sbx sbx-shell; fi
