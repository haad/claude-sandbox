#!/bin/bash
# Run Claude Code in a hardened Apple container against an untrusted repo.
#
#   run.sh <untrusted-repo-dir> [claude args | bash]
#
# Key:   macOS Keychain item "claude-sandbox" (see sbx-key in sandbox.zsh),
#        or SANDBOX_ANTHROPIC_KEY in the environment.
# Env:   SBX_OUT_ROOT   host dir for per-run output   (default ~/sandbox/out)
#        ALLOWED_HOSTS  extra egress, space separated  (default api.anthropic.com)
#        SBX_CPUS / SBX_MEM                           (default 4 / 4g)
set -euo pipefail

IMAGE=claude-sandbox
SRC="${1:?usage: run.sh <untrusted-repo-dir> [claude args]}"; shift || true

# --- guards -----------------------------------------------------------------
[ -d "$SRC" ] || { echo "run.sh: '$SRC' is not a directory" >&2; exit 1; }
SRC="$(cd "$SRC" && pwd -P)"
case "$SRC" in
  /|/Users|/Volumes|/Volumes/*/|"$HOME"|/System*|/private*|/etc*|/var*)
    echo "run.sh: refusing to mount '$SRC' into an untrusted sandbox" >&2; exit 1;;
esac
case "$HOME/" in "$SRC"/*)
    echo "run.sh: '$SRC' contains your home directory, refusing" >&2; exit 1;;
esac
if [ "$(echo "$SRC" | tr -cd / | wc -c)" -lt 4 ]; then
  echo "run.sh: '$SRC' is too shallow (need at least /a/b/c/repo), refusing" >&2; exit 1
fi
for f in .ssh .aws .gnupg .kube; do
  [ -e "$SRC/$f" ] && { echo "run.sh: '$SRC/$f' exists in the source dir, refusing" >&2; exit 1; }
done

container system status >/dev/null 2>&1 || { echo "run.sh: 'container system start' first" >&2; exit 1; }
container image inspect "$IMAGE" >/dev/null 2>&1 || { echo "run.sh: image '$IMAGE' missing, run sbx-build" >&2; exit 1; }

# --- key: keychain first, env override, never on the command line -------------
if [ -z "${SANDBOX_ANTHROPIC_KEY:-}" ]; then
  SANDBOX_ANTHROPIC_KEY="$(security find-generic-password -s claude-sandbox -w 2>/dev/null || true)"
fi
[ -n "$SANDBOX_ANTHROPIC_KEY" ] || { echo "run.sh: no API key. Run 'sbx-key' to store one in Keychain." >&2; exit 1; }
export ANTHROPIC_API_KEY="$SANDBOX_ANTHROPIC_KEY"
unset SANDBOX_ANTHROPIC_KEY

# --- per-run output dir -------------------------------------------------------
OUT_ROOT="${SBX_OUT_ROOT:-$HOME/sandbox/out}"
OUT="$OUT_ROOT/$(basename "$SRC")-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
echo "sandbox: src=$SRC (ro)  out=$OUT  egress=${ALLOWED_HOSTS:-api.anthropic.com}" >&2

TTY=(); [ -t 0 ] && [ -t 1 ] && TTY=(-it)
exec container run ${TTY[@]+"${TTY[@]}"} --rm \
  --dns 1.1.1.1 \
  --cap-add CAP_NET_ADMIN \
  --read-only --tmpfs /tmp --tmpfs /run --tmpfs /home/node \
  --mount "type=bind,source=$SRC,target=/work,readonly" \
  -v "$OUT:/out" \
  --cpus "${SBX_CPUS:-4}" --memory "${SBX_MEM:-4g}" \
  -e ANTHROPIC_API_KEY \
  ${ALLOWED_HOSTS:+-e ALLOWED_HOSTS="$ALLOWED_HOSTS"} \
  "$IMAGE" "$@"
