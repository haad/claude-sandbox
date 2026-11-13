# syntax=docker/dockerfile:1
FROM node:22-bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
      git ca-certificates curl ripgrep iptables gosu \
    && rm -rf /var/lib/apt/lists/* \
    && update-alternatives --set iptables /usr/sbin/iptables-legacy

RUN npm install -g @anthropic-ai/claude-code

# /work is a host bind mount owned by a foreign uid; inside the sandbox that is fine
RUN git config --system safe.directory '*' && git config --system core.fileMode false

COPY <<'EOF' /usr/local/bin/init-firewall.sh
#!/bin/bash
# Egress allowlist. Runs as root, then execs the real command as 'node'.
set -euo pipefail

ALLOWED_HOSTS="${ALLOWED_HOSTS:-api.anthropic.com}"

# GitHub's DNS rotates a single A record per query, so IP pinning fails. Use the
# published web/api/git CIDRs instead. Fetched BEFORE lockdown, on the trusted path.
github_cidrs=""
case " $ALLOWED_HOSTS " in *github.com*|*githubusercontent.com*)
  github_cidrs=$(curl -fsS --max-time 10 https://api.github.com/meta \
    | node -e 'const m=JSON.parse(require("fs").readFileSync(0,"utf8"));
               console.log([...m.web,...m.api,...m.git].filter(c=>!c.includes(":")).join("\n"))') \
    || { echo "firewall: cannot fetch GitHub IP ranges" >&2; exit 1; }
  echo "firewall: $(echo "$github_cidrs" | wc -l) GitHub CIDRs" >&2;;
esac

iptables -F; iptables -X
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

iptables -A INPUT  -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A INPUT  -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# DNS: only to the configured resolvers
for ns in $(awk '/^nameserver/{print $2}' /etc/resolv.conf); do
  iptables -A OUTPUT -p udp -d "$ns" --dport 53 -j ACCEPT
  iptables -A OUTPUT -p tcp -d "$ns" --dport 53 -j ACCEPT
done

# HTTPS: only to the allowlisted hosts. GitHub hosts use the prefetched CIDRs,
# anything else is resolved several times and the answers unioned.
for host in $ALLOWED_HOSTS; do
  case "$host" in
    github.com|api.github.com|codeload.github.com|*.githubusercontent.com)
      if [ -n "$github_cidrs" ]; then
        for cidr in $github_cidrs; do
          iptables -A OUTPUT -p tcp -d "$cidr" --dport 443 -j ACCEPT
        done
        github_cidrs=""   # add once
      fi;;
    *)
      ips=$(for _ in 1 2 3 4 5; do getent ahostsv4 "$host" | awk '{print $1}'; done | sort -u)
      [ -n "$ips" ] || { echo "firewall: cannot resolve $host" >&2; exit 1; }
      for ip in $ips; do
        iptables -A OUTPUT -p tcp -d "$ip" --dport 443 -j ACCEPT
      done;;
  esac
done

iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

# self-test: a host outside the allowlist must be blocked, the first allowed host reachable
canary=example.com
case " $ALLOWED_HOSTS " in *" $canary "*) canary=cloudflare.com;; esac
if curl -s --max-time 5 "https://$canary" >/dev/null 2>&1; then
  echo "firewall: FAILED, $canary reachable" >&2; exit 1
fi
first=${ALLOWED_HOSTS%% *}
if ! curl -s --max-time 10 -o /dev/null "https://$first/"; then
  echo "firewall: FAILED, $first unreachable" >&2; exit 1
fi
echo "firewall: ok (egress limited to: $ALLOWED_HOSTS)" >&2

# writable home for claude state when rootfs is read-only
mkdir -p /home/node/.claude && chown -R node:node /home/node

exec gosu node "$@"
EOF

COPY <<'EOF' /usr/local/bin/sbx-clone-inner
#!/bin/bash
# Runs INSIDE the sandbox. Clones a GitHub repo into /out with every PR head
# and the PR metadata. No host git ever touches the remote.
#   sbx-clone-inner owner/repo
set -euo pipefail
slug="${1:?owner/repo}"
export GIT_LFS_SKIP_SMUDGE=1 GIT_TERMINAL_PROMPT=0

echo "clone: https://github.com/$slug.git -> /out" >&2
git clone --no-recurse-submodules "https://github.com/$slug.git" /out/repo
cd /out/repo
git fetch origin '+refs/pull/*/head:refs/remotes/origin/pr/*' 2>&1 | tail -1 >&2
echo "clone: $(git branch -r | grep -c 'origin/pr/') PR heads as origin/pr/N" >&2

# PR metadata via REST, unauthenticated unless GITHUB_TOKEN is set (60 req/h without)
meta=/out/pr-meta; mkdir -p "$meta"
auth=(); [ -n "${GITHUB_TOKEN:-}" ] && auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
fetch_pages() { # name url-without-page   (max 30 pages = 3000 items)
  local name=$1 url=$2 page=1 body
  while [ $page -le 30 ]; do
    body=$(curl -fsS --max-time 30 "${auth[@]}" -H 'Accept: application/vnd.github+json' \
            "$url&per_page=100&page=$page" 2>/dev/null) || { echo "clone: $name page $page failed (rate limit?)" >&2; break; }
    # GitHub returns an empty page as "[\n\n]"
    [ "$(printf '%s' "$body" | tr -d '[:space:]')" = "[]" ] && break
    printf '%s\n' "$body" > "$meta/$name.$page.json"
    page=$((page+1))
  done
  echo "clone: $name: $((page-1)) page(s)" >&2
}
fetch_pages pulls           "https://api.github.com/repos/$slug/pulls?state=all"
fetch_pages review-comments "https://api.github.com/repos/$slug/pulls/comments?"
fetch_pages issue-comments  "https://api.github.com/repos/$slug/issues/comments?"
echo "clone: done" >&2
EOF
RUN chmod 755 /usr/local/bin/init-firewall.sh /usr/local/bin/sbx-clone-inner

ENV CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
WORKDIR /work

# root only to install the firewall; the script drops to 'node' (uid 1000) before exec
ENTRYPOINT ["/usr/local/bin/init-firewall.sh"]
CMD ["claude", "--dangerously-skip-permissions"]
