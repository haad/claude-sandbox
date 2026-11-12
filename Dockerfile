# syntax=docker/dockerfile:1
FROM node:22-bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
      git ca-certificates curl ripgrep iptables gosu \
    && rm -rf /var/lib/apt/lists/* \
    && update-alternatives --set iptables /usr/sbin/iptables-legacy

RUN npm install -g @anthropic-ai/claude-code

COPY <<'EOF' /usr/local/bin/init-firewall.sh
#!/bin/bash
# Egress allowlist. Runs as root, then execs the real command as 'node'.
set -euo pipefail

ALLOWED_HOSTS="${ALLOWED_HOSTS:-api.anthropic.com}"

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

# HTTPS: only to the resolved IPs of the allowlisted hosts
for host in $ALLOWED_HOSTS; do
  ips=$(getent ahostsv4 "$host" | awk '{print $1}' | sort -u)
  [ -n "$ips" ] || { echo "firewall: cannot resolve $host" >&2; exit 1; }
  for ip in $ips; do
    iptables -A OUTPUT -p tcp -d "$ip" --dport 443 -j ACCEPT
  done
done

iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

# self-test: the allowlist must hold and the API must be reachable
if curl -s --max-time 5 https://github.com >/dev/null 2>&1; then
  echo "firewall: FAILED, github.com reachable" >&2; exit 1
fi
if ! curl -s --max-time 10 -o /dev/null https://api.anthropic.com/; then
  echo "firewall: FAILED, api.anthropic.com unreachable" >&2; exit 1
fi
echo "firewall: ok (egress limited to: $ALLOWED_HOSTS)" >&2

# writable home for claude state when rootfs is read-only
mkdir -p /home/node/.claude && chown -R node:node /home/node

exec gosu node "$@"
EOF
RUN chmod 755 /usr/local/bin/init-firewall.sh

ENV CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
WORKDIR /work

# root only to install the firewall; the script drops to 'node' (uid 1000) before exec
ENTRYPOINT ["/usr/local/bin/init-firewall.sh"]
CMD ["claude", "--dangerously-skip-permissions"]
