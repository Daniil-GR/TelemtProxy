#!/usr/bin/env bash
# Standalone Telemt MTProto/FakeTLS installer (no WEB, Nginx or Certbot).
# Ubuntu 24.04; fixed user: hello; fixed FakeTLS SNI: www.booking.com.
set -Eeuo pipefail

PORT=443
MASK_DOMAIN="www.booking.com"
TEMP_INSTALLER=""
cleanup() {
  if [[ -n "$TEMP_INSTALLER" ]]; then rm -f "$TEMP_INSTALLER"; fi
}
on_error() {
  local code=$?
  echo "[ERROR] Installation failed (line $1, exit code $code)." >&2
  exit "$code"
}
trap cleanup EXIT
trap 'on_error "$LINENO"' ERR

if [[ "$EUID" -ne 0 ]]; then
  echo 'Run as root: sudo bash deploy-mtproto.sh [proxy.example.org]' >&2
  exit 1
fi
if [[ "${1:-}" == '--help' || "${1:-}" == '-h' ]]; then
  echo 'Usage: sudo bash deploy-mtproto.sh [public-proxy-domain]'
  echo 'Installs MTProto only: TCP 443, user hello, FakeTLS www.booking.com.'
  exit 0
fi

DOMAIN="${1:-}"
if [[ -z "$DOMAIN" ]]; then
  if [[ ! -r /dev/tty ]]; then
    echo 'Specify a domain as the first argument when no terminal is available.' >&2
    exit 1
  fi
  read -r -p 'Введите домен для MTProto-ссылки (например, lt.example.org): ' DOMAIN </dev/tty
fi
DOMAIN="${DOMAIN,,}"
if [[ ! "$DOMAIN" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ||
      "$DOMAIN" != *.* || "$DOMAIN" == *..* || ${#DOMAIN} -gt 253 ]]; then
  echo 'Invalid domain. Example: lt.example.org' >&2
  exit 1
fi
if [[ ! -f /etc/os-release ]]; then
  echo 'Supported OS: Ubuntu 24.04 only.' >&2
  exit 1
fi
. /etc/os-release
if [[ "$ID" != ubuntu || "$VERSION_ID" != '24.04' ]]; then
  echo 'Supported OS: Ubuntu 24.04 only.' >&2
  exit 1
fi
if [[ -e /etc/telemt/telemt.toml || -e /opt/mtpr-simple/main.sh ]]; then
  echo 'Existing Telemt/MEKOPR detected. This installer is for a fresh VPS.' >&2
  exit 1
fi
for program in curl python3 ss ip getent; do
  command -v "$program" >/dev/null 2>&1 || {
    echo "Missing $program. Install it before proceeding." >&2
    exit 1
  }
done
if ss -lntH | awk -v port="$PORT" '$4 ~ (":" port "$") {found=1} END {exit !found}'; then
  echo "TCP port $PORT is occupied. The installer will not replace another service." >&2
  exit 1
fi

echo '[1/5] Checking domain resolution...'
PUBLIC_IP="$(curl -4 -fsS --connect-timeout 5 --max-time 12 https://api.ipify.org)"
DNS_IPS="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u || true)"
if [[ -z "$DNS_IPS" ]]; then
  echo "No DNS A record for $DOMAIN. Create the record before installing." >&2
  exit 1
fi
MATCHED=0
while IFS= read -r candidate; do
  if [[ "$candidate" == "$PUBLIC_IP" ]] || ip -o -4 addr show | awk -v ip="$candidate" '$4 ~ ("^" ip "/") {found=1} END {exit !found}'; then
    MATCHED=1
    break
  fi
done <<< "$DNS_IPS"
if (( MATCHED == 0 )); then
  echo "DNS for $DOMAIN resolves to: $DNS_IPS" >&2
  echo "Neither matches outgoing public IP $PUBLIC_IP nor a local interface address." >&2
  echo 'Check Floating IP assignment and DNS before installing.' >&2
  exit 1
fi
echo "[OK] $DOMAIN resolves to this VPS (including assigned Floating IPs)."

echo '[2/5] Installing Telemt (latest stable) and MEKOPR SYN FIX v3...'
SECRET="$(python3 -c 'import secrets; print(secrets.token_hex(16))')"
TEMP_INSTALLER="$(mktemp)"
curl -fsSL --retry 3 --max-time 30 \
  https://raw.githubusercontent.com/Mekotofeuka/MTPROTO_FIX_By_MEKO/main/install.sh \
  -o "$TEMP_INSTALLER"
# Upstream may print temporary proxy links. The final configuration below replaces them.
bash "$TEMP_INSTALLER" -telemt -domain "$MASK_DOMAIN" -port "$PORT" \
  -version latest -fix -fix-type v3
rm -f "$TEMP_INSTALLER"
TEMP_INSTALLER=""

echo '[3/5] Writing the minimal MTProto-only configuration...'
[[ -f /etc/telemt/telemt.toml ]] || {
  echo 'Telemt config not found after upstream installer.' >&2
  exit 1
}
cp -a /etc/telemt/telemt.toml "/etc/telemt/telemt.toml.bak.$(date +%s)"
cat > /etc/telemt/telemt.toml <<EOF
[general]
use_middle_proxy = true
ad_tag = ""

[general.modes]
classic = false
secure = false
tls = true

[general.links]
show = ["hello"]
public_host = "$DOMAIN"
public_port = $PORT

[server]
port = $PORT

[server.api]
enabled = true
listen = "127.0.0.1:9091"
whitelist = ["127.0.0.1/32"]

[[server.listeners]]
ip = "0.0.0.0"
port = $PORT

[censorship]
tls_domain = "$MASK_DOMAIN"
mask = true
tls_emulation = true
tls_front_dir = "tlsfront"

[access.users]
hello = "$SECRET"
EOF
chown root:telemt /etc/telemt/telemt.toml
chmod 640 /etc/telemt/telemt.toml
python3 - "$DOMAIN" "$SECRET" <<'PY'
import sys, tomllib
with open('/etc/telemt/telemt.toml', 'rb') as fp:
    config = tomllib.load(fp)
assert config['general']['links']['public_host'] == sys.argv[1]
assert config['general']['modes']['tls'] is True
assert config['general']['modes']['secure'] is False
assert config['censorship']['tls_domain'] == 'www.booking.com'
assert config['access']['users'] == {'hello': sys.argv[2]}
assert config['server']['port'] == 443
assert 'web' not in config
print('[OK] Minimal FakeTLS configuration validated.')
PY

if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
  ufw allow "$PORT/tcp"
fi

echo '[4/5] Restarting Telemt and waiting for TCP 443...'
if ! systemctl restart telemt; then
  systemctl status telemt -n 30 --no-pager >&2 || true
  journalctl -u telemt -n 60 --no-pager >&2 || true
  exit 1
fi
READY=0
DEADLINE=$((SECONDS + 30))
while (( SECONDS < DEADLINE )); do
  if systemctl is-active --quiet telemt &&
     ss -lntp | awk '$4 ~ /:443$/ && /telemt/ {found=1} END {exit !found}'; then
    READY=1
    break
  fi
  sleep 1
done
if (( READY == 0 )); then
  echo '[ERROR] Telemt did not open port 443 within 30 seconds.' >&2
  systemctl status telemt -n 30 --no-pager >&2 || true
  journalctl -u telemt -n 60 --no-pager >&2 || true
  exit 1
fi
echo '[OK] Telemt service active and TCP 443 is listening.'

echo '[5/5] Generating domain-based Telegram link...'
MASK_HEX="$(printf '%s' "$MASK_DOMAIN" | od -An -tx1 | tr -d ' \n')"
LINK="tg://proxy?server=$DOMAIN&port=$PORT&secret=ee$SECRET$MASK_HEX"
umask 077
printf '%s\n' "$LINK" > /root/telemt-mtproto-link.txt
cat <<EOF

================== READY: MTPROTO ONLY ==================
Domain:       $DOMAIN
Port:         $PORT/TCP
User:         hello
FakeTLS SNI:  $MASK_DOMAIN
Telemt:       $(telemt --version 2>/dev/null | head -1 || true)
Telegram:     $LINK

Stored link:  /root/telemt-mtproto-link.txt
Config:       /etc/telemt/telemt.toml
MEKOPR:       mekopr
=========================================================
Note: this is MTProto (tg://proxy), not WEB (tg://webproxy).
No Nginx, Certbot or WEB listener was configured.
For sponsored channels, set ad_tag in [general] after @MTProxybot registration.
EOF
