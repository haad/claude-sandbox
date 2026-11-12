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
| Persistence between runs | Read-only rootfs, `/tmp` and home on tmpfs, `--rm`. Every run is a clean slate. |
| Stolen key has a wide blast radius | Dedicated API key in its own Console workspace with a hard spend cap, stored in macOS Keychain, never on the command line. |
| Accidentally mounting your home or all your projects | `run.sh` refuses `/`, `/Users`, `/Volumes`, `$HOME`, system dirs, paths shallower than `/a/b/c/repo`, and any dir containing `.ssh`, `.aws`, `.gnupg` or `.kube`. |
| Resource abuse | CPU and memory caps (default 4 / 4g). |

Apple `container` runs each container in its own lightweight VM, so the
kernel-escape surface is far smaller than Docker on Linux. What is left is
what the code can do with the resources you hand it, and the controls above
limit exactly that.

## Files

| File | Role |
|---|---|
| `Dockerfile` | `node:22-bookworm-slim` + Claude Code + `iptables-legacy` + `gosu`. The firewall entrypoint is embedded as a heredoc, so this is the only build input. |
| `run.sh` | The single runner. All hardening lives here. Works from any shell or script. |
| `sandbox.zsh` | Thin zsh functions over `run.sh` plus directory completion. |
| `hooks/pre-commit` | gitleaks secret scan plus a credential-file blocklist. Tracked, enabled via `core.hooksPath`. |

## Setup

```bash
# 1. builder needs a DNS server if your host resolver is local-only (127.0.0.1, Tailscale)
container builder start --dns 1.1.1.1 --cpus 4 --memory 4g
container build -t claude-sandbox .

# 2. shell integration
echo 'source /Volumes/Devel/apple/claude-sandbox/sandbox.zsh' >> ~/.zshrc && exec zsh

# 3. store a dedicated, spend-capped API key in Keychain (item "claude-sandbox")
sbx-key

# 4. enable the pre-commit secret scan for this clone
brew install gitleaks
git config core.hooksPath hooks
```

## Use

```bash
sbx-clone owner/repo          # clone, fetch every PR head as origin/pr/N, dump PR metadata to .pr-meta/
sbx repo                      # Claude Code in the sandbox, repo read-only at /work
sbx-shell repo                # same sandbox, bash instead of claude
sbx-out                       # list output dirs, newest first
sbx-build                     # rebuild after editing the Dockerfile
```

Each run gets its own output dir, `~/sandbox/out/<repo>-<timestamp>`. Tell
Claude to write findings to `/out`. If it needs to build or run tests, it can
copy `/work` to `/tmp` inside the VM, which is tmpfs and vanishes on exit.

Treat `out/` as untrusted too. A compromised session could plant a file with
instructions aimed at your next Claude session, or a script you would be
tempted to run.

### Knobs

| Variable | Default | Effect |
|---|---|---|
| `ALLOWED_HOSTS` | `api.anthropic.com` | Space-separated hosts allowed on 443. Each one widens the exfil surface. |
| `SBX_OUT_ROOT` | `~/sandbox/out` | Where per-run output dirs are created. |
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
- **Allowlist is resolved once at start.** If Anthropic's edge IPs rotate
  mid-session, API calls fail closed. Restart the container.
- **`--dangerously-skip-permissions` is deliberate.** Permission prompts are a
  weak defence against prompt injection and make unattended analysis useless.
  The container is the control.
- **Do not add `--cap-drop ALL`.** iptables fails at init even with
  `CAP_NET_ADMIN` re-added. Default caps plus `CAP_NET_ADMIN` work, and all
  caps are gone after the drop to `node` anyway.
- **TTY.** `run.sh` passes `-it` only when stdin and stdout are terminals.
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
