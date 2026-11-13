# Claude sandbox helpers. Source from ~/.zshrc:
#   export SBX_ROOT=/Volumes/Devel/sandbox      # optional, default ~/sandbox
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

# sbx-clone <owner/repo|url> [dest]   clone + all PR heads + PR metadata, inside a VM
sbx-clone() { "$SBX_DIR/clone.sh" "$@"; }

# sbx-out                        list run outputs, newest first
sbx-out() { ls -1t "${SBX_OUT_ROOT:-${SBX_ROOT:-$HOME/sandbox}/out}"; }

# sbx-clean                      remove stopped sandbox containers (normally none, --rm)
sbx-clean() { container ls -a 2>/dev/null | awk '$2 ~ /claude-sandbox/ && $5 != "running" {print $1}' | xargs -r container rm; }

if (( $+functions[compdef] )); then compdef '_files -/' sbx sbx-shell; fi
