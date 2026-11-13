#!/bin/bash
# Clone a GitHub repo, all PR heads and PR metadata, entirely inside a sandbox VM.
# Host git never touches the remote. Result is read-only and quarantined on the host.
#
#   clone.sh <owner/repo | https://github.com/owner/repo> [dest-dir]
#
# Env: SBX_ROOT      default ~/sandbox (clone goes to $SBX_ROOT/src/<repo>)
#      GITHUB_TOKEN  optional, raises API rate limit
set -euo pipefail
cd "$(dirname "$0")" && . ./lib.sh

repo="${1:?usage: clone.sh <owner/repo> [dest]}"
slug="${repo#https://github.com/}"; slug="${slug%.git}"; slug="${slug%/}"
case "$slug" in */*) ;; *) echo "clone.sh: need owner/repo" >&2; exit 1;; esac
case "$slug" in *://*|*..*|*/*/*) echo "clone.sh: bad slug '$slug'" >&2; exit 1;; esac

dest="${2:-$SBX_SRC_ROOT/${slug##*/}}"
[ -e "$dest" ] && { echo "clone.sh: '$dest' already exists" >&2; exit 1; }
sbx_require_runtime
mkdir -p "$dest"; dest="$(cd "$dest" && pwd -P)"

echo "sandbox: cloning $slug inside a VM -> $dest" >&2
rc=0
container run $(sbx_tty) --rm \
  --dns 1.1.1.1 \
  --cap-add CAP_NET_ADMIN \
  --read-only --tmpfs /tmp --tmpfs /run --tmpfs /home/node \
  -v "$dest:/out" \
  --cpus 2 --memory 2g \
  -e ALLOWED_HOSTS="github.com api.github.com" \
  ${GITHUB_TOKEN:+-e GITHUB_TOKEN} \
  "$IMAGE" sbx-clone-inner "$slug" || rc=$?

sbx_harden_dir "$dest"
[ $rc -eq 0 ] || { echo "clone.sh: clone failed (exit $rc); '$dest' left read-only for inspection" >&2; exit $rc; }
echo "sandbox: repo at $dest/repo (read-only, quarantined), PR metadata in $dest/pr-meta" >&2
echo "next: sbx $dest        (repo at /work/repo, metadata at /work/pr-meta)" >&2
