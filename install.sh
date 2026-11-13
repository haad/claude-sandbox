#!/bin/bash
# Install the sandbox as a package:   ./install.sh [prefix]    (default ~/.claude-sandbox)
# Re-run to update. Uninstall: rm -rf ~/.claude-sandbox and drop the two lines from ~/.zshrc.
set -euo pipefail
src="$(cd "$(dirname "$0")" && pwd)"
prefix="${1:-$HOME/.claude-sandbox}"

install -d -m 755 "$prefix/bin" "$prefix/lib"
install -m 755 "$src/bin/sbx-run" "$src/bin/sbx-clone" "$prefix/bin/"
install -m 644 "$src/lib/lib.sh" "$src/lib/sandbox.zsh" "$src/lib/Dockerfile" "$prefix/lib/"

echo "installed to $prefix"
echo
echo "add to ~/.zshrc:"
echo "  export SBX_ROOT=/Volumes/Devel/sandbox      # untrusted zone, default ~/sandbox"
echo "  source $prefix/lib/sandbox.zsh"
echo
if ! container image inspect claude-sandbox >/dev/null 2>&1; then
  echo "then build the image once:  sbx-build"
fi
