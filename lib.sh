# Shared by run.sh and clone.sh. Host-side handling of directories a sandbox wrote to.
# Rule: the host stores bytes, it never interprets them. Nothing here follows symlinks.

IMAGE=claude-sandbox
QUARANTINE='0081;00000000;claude-sandbox;'

sbx_require_runtime() {
  container system status >/dev/null 2>&1 || { echo "sandbox: 'container system start' first" >&2; exit 1; }
  container image inspect "$IMAGE" >/dev/null 2>&1 || { echo "sandbox: image '$IMAGE' missing, run sbx-build" >&2; exit 1; }
}

# -it only when attached to a terminal; container returns ENOTSUP otherwise
sbx_tty() { [ -t 0 ] && [ -t 1 ] && echo "-it" || true; }

# Make a sandbox-written tree inert for host tools:
#   - remove symlinks and anything that is not a regular file or directory
#   - strip exec bits, add Gatekeeper quarantine, make read-only
#   - with "defang": rename dot entries (.claude, .git, .envrc, .vscode ...) to _dot_<name>
#     so nothing auto-loads them. Not for cloned repos, where .git must stay.
sbx_harden_dir() {
  local dir=$1 mode=${2:-}
  [ -d "$dir" ] || return 0
  local n_links
  n_links=$(find "$dir" -mindepth 1 \( -type l -o \( ! -type f ! -type d \) \) -print -delete | wc -l | tr -d ' ')
  [ "$n_links" -gt 0 ] && echo "sandbox: removed $n_links symlink/special entries from $dir" >&2
  if [ "$mode" = defang ]; then
    find "$dir" -mindepth 1 -depth -name '.*' -print0 | while IFS= read -r -d '' p; do
      mv "$p" "$(dirname "$p")/_dot_$(basename "$p" | cut -c2-)"
    done
  fi
  chmod -R u+w "$dir"                      # xattr needs write permission (git packs are 0444)
  find "$dir" -type f -exec chmod a-x {} +
  find "$dir" -type f -exec xattr -w com.apple.quarantine "$QUARANTINE" {} + || echo "sandbox: warning, quarantine xattr failed on some files" >&2
  chmod -R a-w "$dir"
}
