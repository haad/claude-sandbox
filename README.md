# claude-sandbox

Run Claude Code against untrusted code inside an Apple `container` VM, with
the assumption that the code, and Claude under prompt injection from that
code, is hostile. Containment does the work, not Claude's judgment.

Tested on macOS 26 with `container` 1.1.0 (Homebrew).

## Threat model

| Risk | Control |
|---|---|
| Exfiltrate the API key or source over the network | In-guest iptables allowlist: DNS plus TCP 443 to `api.anthropic.com` only. Host gateway and other containers are blocked. |
| Untrusted code disables the firewall | Rules are installed as root at start, then the process drops to `node` with no capabilities. |
| Code tampers with files you later read or push | Source is bind-mounted read-only at `/work`. Claude writes to a separate `/out`. |
| Clone-time attacks on host git (git-lfs smudge, submodule CVEs, pack parser bugs) | The clone runs inside a VM with egress to GitHub only. Host git never talks to the remote. |
| Sandbox output attacks the host when read (symlink to `~/.ssh`, executables, `.claude`/`.git` hooks) | After every run the host deletes symlinks and special files, strips exec bits, sets the Gatekeeper quarantine flag, renames dot entries to `_dot_*` and makes the tree read-only. Verified. |
| Persistence between runs | Read-only rootfs, `/tmp` and home on tmpfs, `--rm`. Every run is a clean slate. |
| Stolen key has a wide blast radius | Dedicated API key in its own Console workspace with a hard spend cap, stored in macOS Keychain, never on the command line. |
| Accidentally mounting your home or all your projects | `sbx-run` refuses `/`, `/Users`, `/Volumes`, `$HOME`, system dirs, paths shallower than `/a/b/c/repo`, and any dir containing `.ssh`, `.aws`, `.gnupg` or `.kube`. |
| Resource abuse | CPU and memory caps (default 4 / 4g). |

Apple `container` runs each container in its own lightweight VM, so the
kernel-escape surface is far smaller than Docker on Linux. What is left is
what the code can do with the resources you hand it, and the controls above
limit exactly that.

## Files

The repo layout is the install layout. `install.sh` copies `bin/` and `lib/`
to `~/.claude-sandbox` (or a prefix you give it); re-run it to update.

| File | Role |
|---|---|
| `bin/sbx-run` | Runs a session: mount guards, Keychain key, per-run out dir, post-run hardening of `/out`. |
| `bin/sbx-clone` | Clones a GitHub repo, all PR heads and PR metadata inside a VM, then hardens the result on the host. |
| `lib/lib.sh` | Shared: `SBX_ROOT` paths, runtime checks and `sbx_harden_dir`, the host-side defang routine. Never follows symlinks. |
| `lib/sandbox.zsh` | Thin zsh functions over the scripts plus directory completion. |
| `lib/Dockerfile` | `node:22-bookworm-slim` + Claude Code + `iptables-legacy` + `gosu`. Firewall and in-VM clone script are embedded as heredocs, so this is the only build input. |
| `install.sh` | Copies `bin/` and `lib/` to the prefix and prints the `.zshrc` lines. |
| `hooks/pre-commit` | gitleaks secret scan plus a credential-file blocklist. Tracked, enabled via `core.hooksPath`. |

## Setup

```bash
# 1. install to ~/.claude-sandbox
./install.sh

# 2. shell integration. SBX_ROOT is the untrusted zone on the host, default ~/sandbox
cat >> ~/.zshrc <<'EOF'
export SBX_ROOT=/Volumes/Devel/sandbox
source ~/.claude-sandbox/lib/sandbox.zsh
EOF
exec zsh

# 3. build the image. The builder needs a DNS server if your host resolver is
#    local-only (127.0.0.1, Tailscale); sbx-build starts it with one.
sbx-build

# 4. store a dedicated, spend-capped API key in Keychain (item "claude-sandbox")
sbx-key

# 5. developing the sandbox itself: enable the pre-commit secret scan in this clone
brew install gitleaks
git config core.hooksPath hooks
```

Uninstall: `rm -rf ~/.claude-sandbox` and remove the two lines from `~/.zshrc`.
The image stays until `container image rm claude-sandbox`.

## Use

```bash
sbx-clone owner/repo          # inside a VM: clone, every PR head as origin/pr/N, PR metadata. -> $SBX_ROOT/src/<repo>
sbx $SBX_ROOT/src/repo        # Claude Code in the sandbox: /work/repo (read-only) and /work/pr-meta
sbx-shell $SBX_ROOT/src/repo  # same sandbox, bash instead of claude
sbx-out                       # list output dirs, newest first
sbx-build                     # rebuild after editing the Dockerfile
```

Each run gets its own output dir, `$SBX_ROOT/out/<name>-<timestamp>`. Tell
Claude to write findings to `/out`. If it needs to build or run tests, it can
copy `/work/repo` to `/tmp` inside the VM, which is tmpfs and vanishes on exit.

### What crosses the VM boundary, and how

The host is a byte store. It never runs git, a package manager, an editor
with plugins or Claude Code against anything a sandbox produced.

- **Clone** happens in a throwaway container with `ALLOWED_HOSTS="github.com
  api.github.com"` and no API key. GitHub's DNS rotates per query, so the
  firewall uses GitHub's published `web`/`api`/`git` CIDRs, fetched from
  `api.github.com/meta` before lockdown. git-lfs smudge is disabled, submodules
  are not recursed. PR metadata comes from the REST API, unauthenticated
  (60 requests/hour) unless `GITHUB_TOKEN` is set.
- **After the clone and after every run**, `sbx_harden_dir` makes the written
  tree inert for host tools: symlinks and non-regular files are deleted (a
  sandbox can plant `report.md -> ~/.ssh/id_ed25519`, verified), exec bits are
  stripped, every file gets `com.apple.quarantine`, the tree is `chmod -R a-w`.
  For out dirs it additionally renames dot entries (`.claude`, `.git`,
  `.envrc`, `.vscode`) to `_dot_*` so nothing auto-loads them.
- **Nothing fires on `cd`.** Shell hooks like mise or direnv only act on
  trusted config, but check `mise settings python.uv_venv_auto` if you keep
  it on. Do not `cd` into sandbox trees with a git-aware prompt if you want
  zero host parsing; use `sbx-shell` instead.

Treat everything under `$SBX_ROOT` as an untrusted zone. Read them, never
execute from them, never open them in Claude Code or an IDE on the host.

### What persists between sessions

Inside the VM nothing: read-only rootfs, tmpfs for `/tmp`, `/run` and home,
`--rm`. Claude has no memory, no trusted-folder flag, no settings carry-over.
Shared across sessions by design: the image, the API key (rotate it; a key
leaked in one session is valid in every later one until you do), the
read-only source tree, and the out dirs. Everything else is per run.

### Knobs

| Variable | Default | Effect |
|---|---|---|
| `ALLOWED_HOSTS` | `api.anthropic.com` | Space-separated hosts allowed on 443. Each one widens the exfil surface. |
| `SBX_ROOT` | `~/sandbox` | The untrusted zone. Clones go to `$SBX_ROOT/src`, run output to `$SBX_ROOT/out`. Keep it away from your own projects. |
| `SBX_SRC_ROOT`, `SBX_OUT_ROOT` | derived | Override either half independently. |
| `GITHUB_TOKEN` | unset | Passed into the clone container only. Use a fine-grained read-only token or none. |
| `SBX_CPUS`, `SBX_MEM` | `4`, `4g` | VM resources. |
| `SANDBOX_ANTHROPIC_KEY` | Keychain | Overrides the Keychain lookup, for CI. |

Example: `ALLOWED_HOSTS="api.anthropic.com github.com" sbx repo`

## Pre-commit checks

`hooks/pre-commit` refuses a commit when:

- `gitleaks` finds a secret pattern in the staged diff (API keys, tokens,
  private keys, connection strings, and the rest of its default ruleset);
- a staged file looks like a credential by name: `.env*`, `*.pem`, `*.key`,
  `*.p12`, `*.pfx`, `id_rsa*`, `id_ed25519*`, `*.kubeconfig`, `credentials`,
  `.netrc`, `.npmrc`, `.pypirc`;
- `gitleaks` is not installed. It fails closed rather than committing unchecked.

For a documented placeholder, add a `gitleaks:allow` comment on that line.

The hook overrides `color.diff`, `diff.mnemonicprefix` and `diff.external`
for its own `git diff` call. gitleaks parses raw diff output and a global
`color.diff=always` or mnemonic prefixes make it silently scan zero bytes
and report "no leaks". Verify a scanner actually scanned something before
trusting a clean result:

```bash
GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=color.diff GIT_CONFIG_VALUE_0=never \
GIT_CONFIG_KEY_1=diff.mnemonicprefix GIT_CONFIG_VALUE_1=false \
gitleaks git . --redact -v          # look at "scanned ~N bytes", not just "no leaks"
```

## Caveats

- **DNS.** The sandbox uses `--dns 1.1.1.1` because the vmnet gateway on a
  host with a local resolver refuses port 53. That makes DNS a low-bandwidth
  covert channel. For truly hostile samples, run on a `container network
  create --internal` network and put an allowlisting HTTPS proxy on the host
  with `HTTPS_PROXY` set in the container. Untested here.
- **Allowlist is resolved once at start.** Non-GitHub hosts are resolved five
  times and the answers unioned. If an edge IP rotates mid-session, API calls
  fail closed. Restart the container.
- **No disk quota on `/out`.** A hostile session can fill the disk. If that
  matters, put `SBX_ROOT` on a fixed-size sparse bundle:
  `hdiutil create -size 8g -type SPARSEBUNDLE -fs APFS -volname Sandbox ~/sandbox.sparsebundle`
  and point `SBX_ROOT` at `/Volumes/Sandbox`.
- **`--dangerously-skip-permissions` is deliberate.** Permission prompts are a
  weak defence against prompt injection and make unattended analysis useless.
  The container is the control.
- **Do not add `--cap-drop ALL`.** iptables fails at init even with
  `CAP_NET_ADMIN` re-added. Default caps plus `CAP_NET_ADMIN` work, and all
  caps are gone after the drop to `node` anyway.
- **TTY.** `sbx-run` passes `-it` only when stdin and stdout are terminals.
  `container` returns `ENOTSUP` if asked for a TTY without one.

## Verifying the sandbox

```bash
sbx-shell repo
# inside:
id                                        # uid=1000(node), CapEff 0
touch /work/x                             # Read-only file system
touch /usr/x                              # Read-only file system
iptables -L                               # Permission denied
curl -m5 https://github.com               # blocked
curl -m3 http://192.168.64.1              # blocked (host gateway)
curl -m10 -o /dev/null -w '%{http_code}\n' https://api.anthropic.com/   # 404, reachable
```
