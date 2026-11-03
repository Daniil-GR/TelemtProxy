#!/usr/bin/env bash
# Standalone Telemt MTProto/FakeTLS installer (no WEB, Nginx or Certbot).
# Ubuntu 24.04; fixed user: hello; fixed FakeTLS SNI: www.booking.com.
set -Eeuo pipefail

PORT=443
MASK_DOMAIN="www.booking.com"
TEMP_INSTALLER=""
TEMP_EDGE_HELPER=""
TEMP_EDGE_CIDRS=""
EDGE_MODE=0
EDGE_OWNED_INSTALL=0
cleanup() {
  local status=$?
  if (( status != 0 && EDGE_MODE == 1 && EDGE_OWNED_INSTALL == 1 )); then
    systemctl disable --now telemt-gcore-refresh.timer >/dev/null 2>&1 || true
    systemctl stop telemt >/dev/null 2>&1 || true
    echo '[ERROR] Fresh Edge Telemt stopped after installation failure; SSH and routing are unchanged.' >&2
  fi
  if [[ -n "$TEMP_INSTALLER" ]]; then rm -f "$TEMP_INSTALLER"; fi
  if [[ -n "$TEMP_EDGE_HELPER" ]]; then rm -f "$TEMP_EDGE_HELPER"; fi
  if [[ -n "$TEMP_EDGE_CIDRS" ]]; then rm -f "$TEMP_EDGE_CIDRS"; fi
}
on_error() {
  local code=$?
  echo "[ERROR] Installation failed (line $1, exit code $code)." >&2
  exit "$code"
}
trap cleanup EXIT
trap 'on_error "$LINENO"' ERR

usage() {
  cat <<'USAGE'
Usage: sudo bash deploy-mtproto.sh [DOMAIN] [OPTIONS]

Options:
  --edge-proxy          MTProto for Gcore Edge Proxy (TCP 443, PROXY protocol v1/v2)
  --domain FQDN         Domain for public tg://proxy link (or positional DOMAIN)
  --hello HEX           Reuse existing hello secret (exactly 32 HEX characters)
  --hello-secret HEX    Same as --hello
  --ad-tag HEX          Sponsor tag from @MTProxybot (exactly 32 HEX characters)
  -h, --help            Show this message

Missing credentials are requested securely on a terminal.
Empty hello input generates a new secret; empty ad_tag leaves it disabled.
Command-line secrets may be visible in shell history and process listings.
USAGE
}

DOMAIN=""
SECRET=""
AD_TAG=""
HELLO_FLAG_SET=0
AD_TAG_FLAG_SET=0

while (($# > 0)); do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --edge-proxy)
      EDGE_MODE=1
      shift
      ;;
    --domain|--hello|--hello-secret|--ad-tag)
      option="$1"
      if (($# < 2)); then
        echo "Missing value for $option" >&2
        exit 1
      fi
      value="$2"
      case "$option" in
        --domain)
          if [[ -n "$DOMAIN" ]]; then echo 'Domain specified more than once.' >&2; exit 1; fi
          DOMAIN="$value"
          ;;
        --hello|--hello-secret)
          if ((HELLO_FLAG_SET)); then echo 'hello secret specified more than once.' >&2; exit 1; fi
          if [[ -z "$value" ]]; then echo 'Empty hello flag is invalid; omit it for generation.' >&2; exit 1; fi
          SECRET="$value"
          HELLO_FLAG_SET=1
          ;;
        --ad-tag)
          if ((AD_TAG_FLAG_SET)); then echo 'ad_tag specified more than once.' >&2; exit 1; fi
          if [[ -z "$value" ]]; then echo 'Empty ad_tag flag is invalid; omit it for no tag.' >&2; exit 1; fi
          AD_TAG="$value"
          AD_TAG_FLAG_SET=1
          ;;
      esac
      shift 2
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      if [[ -n "$DOMAIN" ]]; then
        echo 'Domain specified more than once.' >&2
        exit 1
      fi
      DOMAIN="$1"
      shift
      ;;
  esac
done

if [[ "$EUID" -ne 0 ]]; then
  echo 'Run as root: sudo bash deploy-mtproto.sh [proxy.example.org]' >&2
  exit 1
fi

if [[ -z "$DOMAIN" ]]; then
  if [[ ! -r /dev/tty ]]; then
    echo 'Specify a domain via --domain FQDN or positional argument.' >&2
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

if (( EDGE_MODE == 1 )); then
  echo '[1/5] Preparing Gcore Edge mode (public DNS may point to Edge IP or be absent)...'
  for path in /etc/telemt/gcore-edge-cidrs.json /usr/local/lib/telemtproxy/gcore-edge.py /etc/systemd/system/telemt-gcore-firewall.service; do
    [[ ! -e "$path" ]] || { echo "Existing Edge setup: $path. Use a fresh VPS." >&2; exit 1; }
  done
  TEMP_EDGE_HELPER="$(mktemp)"
  TEMP_EDGE_CIDRS="$(mktemp)"
  curl -fsSL --retry 3 --max-time 30 https://raw.githubusercontent.com/Daniil-GR/TelemtProxy/main/gcore-edge.py -o "$TEMP_EDGE_HELPER"
  EXPECTED_EDGE_SHA256="e278c2418af4a04baa86925387c22751981084d27477219439415fe167fa8034"
  [[ "$(sha256sum "$TEMP_EDGE_HELPER" | awk '{print $1}')" == "$EXPECTED_EDGE_SHA256" ]] || {
    echo 'Edge helper checksum mismatch. Download the current installer again.' >&2; exit 1;
  }
  python3 "$TEMP_EDGE_HELPER" fetch > "$TEMP_EDGE_CIDRS"
  PUBLIC_IP="$(curl -4 -fsS --connect-timeout 5 --max-time 12 https://api.ipify.org)"
  python3 - "$PUBLIC_IP" <<'IP_CHECK'
import ipaddress, sys
ip = ipaddress.ip_address(sys.argv[1])
assert ip.version == 4 and ip.is_global
IP_CHECK
  echo '[OK] Official Gcore network list validated. No API token required.'
else
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

fi

echo '[2/5] Selecting hello secret and sponsor ad_tag...'
# Provided CLI values take priority. Read only missing credentials from the
# terminal, and never echo them. Avoid putting reusable secrets on the CLI
# when shell history/process-list exposure is a concern.
if { : </dev/tty; } 2>/dev/null; then
  if ((HELLO_FLAG_SET == 0)); then
    if ! read -r -s -p 'Секрет hello (32 HEX, Enter = создать новый): ' SECRET </dev/tty; then
      echo 'Failed to read hello secret.' >&2
      exit 1
    fi
    printf '\n'
  fi
  if ((AD_TAG_FLAG_SET == 0)); then
    if ! read -r -s -p 'ad_tag (32 HEX, Enter = без тега): ' AD_TAG </dev/tty; then
      echo 'Failed to read ad_tag.' >&2
      exit 1
    fi
    printf '\n'
  fi
else
  if ((HELLO_FLAG_SET == 0)); then
    echo '[INFO] No terminal or --hello flag: generating a new secret.'
  fi
  if ((AD_TAG_FLAG_SET == 0)); then
    echo '[INFO] No terminal or --ad-tag flag: leaving sponsor tag empty.'
  fi
fi
if [[ -z "$SECRET" ]]; then
  SECRET="$(python3 -c 'import secrets; print(secrets.token_hex(16))')"
  echo '[OK] Generated a new hello secret.'
else
  if [[ ! "$SECRET" =~ ^[[:xdigit:]]{32}$ ]]; then
    echo '[ERROR] hello secret must contain exactly 32 hexadecimal characters (without dd/ee).' >&2
    exit 1
  fi
  SECRET="${SECRET,,}"
  echo '[OK] Reusing the supplied hello secret.'
fi
if [[ -n "$AD_TAG" ]]; then
  if [[ ! "$AD_TAG" =~ ^[[:xdigit:]]{32}$ ]]; then
    echo '[ERROR] ad_tag must contain exactly 32 hexadecimal characters.' >&2
    exit 1
  fi
  AD_TAG="${AD_TAG,,}"
  echo '[OK] Reusing the supplied ad_tag.'
else
  echo '[INFO] No sponsor ad_tag selected.'
fi

if (( EDGE_MODE == 1 )); then
  echo '[2/5] Installing Telemt for Gcore (without direct-client SYN FIX)...'
  FIX_ARGS=(-no-fix)
  command -v apt-get >/dev/null || { echo 'apt-get is required.' >&2; exit 1; }
  DEBIAN_FRONTEND=noninteractive apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y iptables ipset
else
  echo '[2/5] Installing Telemt (latest stable) and MEKOPR SYN FIX v3...'
  FIX_ARGS=(-fix -fix-type v3)
fi
TEMP_INSTALLER="$(mktemp)"
curl -fsSL --retry 3 --max-time 30 \
  https://raw.githubusercontent.com/Mekotofeuka/MTPROTO_FIX_By_MEKO/main/install.sh \
  -o "$TEMP_INSTALLER"
# Upstream may print temporary proxy links. The final configuration below replaces them.
if (( EDGE_MODE == 1 )); then EDGE_OWNED_INSTALL=1; fi
bash "$TEMP_INSTALLER" -telemt -domain "$MASK_DOMAIN" -port "$PORT" \
  -version latest "${FIX_ARGS[@]}"
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
ad_tag = "$AD_TAG"

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
python3 - "$DOMAIN" <<'PY'
import re, sys, tomllib
with open('/etc/telemt/telemt.toml', 'rb') as fp:
    config = tomllib.load(fp)
assert config['general']['links']['public_host'] == sys.argv[1]
assert config['general']['modes']['tls'] is True
assert config['general']['modes']['secure'] is False
assert config['censorship']['tls_domain'] == 'www.booking.com'
assert list(config['access']['users']) == ['hello']
assert re.fullmatch(r'[0-9a-f]{32}', config['access']['users']['hello'])
assert config['general']['ad_tag'] == '' or re.fullmatch(r'[0-9a-f]{32}', config['general']['ad_tag'])
assert config['server']['port'] == 443
assert 'web' not in config
print('[OK] Minimal FakeTLS configuration and credentials validated.')
PY

if (( EDGE_MODE == 1 )); then
  python3 "$TEMP_EDGE_HELPER" install --cidrs-file "$TEMP_EDGE_CIDRS"
fi

if (( EDGE_MODE == 0 )) && command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
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

if (( EDGE_MODE == 1 )); then
  echo '[OK] Gcore Edge configuration ready. Full Telegram data transfer must be checked through an active Gcore mapping.'
fi

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
Sponsor ad_tag: ${AD_TAG:-not set}
To preserve the same public Telegram link after an IPv4 change,
reuse the previous hello secret and domain (and keep port/SNI unchanged).
EOF

if (( EDGE_MODE == 1 )); then
  cat <<EOF

================== MTPROTO ДЛЯ EDGE PROXY ==================
Origin VPS: $PUBLIC_IP:443 (TCP)
В Gcore: Generic TCP Server, порт 443/TCP, PROXY protocol V1 (или V2).
После активации укажите выданный Edge IP в A-записи $DOMAIN.
Прямые подключения к VPS:443 запрещены, разрешены только адреса Gcore.
Собственный TLS-сертификат, Nginx и HTTP CDN здесь не нужны.
Сети Gcore обновляются каждые 10 минут; при изменении выполняется
короткий перезапуск Telemt с откатом конфигурации при ошибке.
Журнал: journalctl -u telemt-gcore-refresh.service -u telemt-gcore-firewall.service
Проверка: systemctl status telemt telemt-gcore-refresh.timer
Готовность порта не подтверждает передачу данных: проверьте сообщения
и фотографии в Telegram через Edge IP после настройки Gcore и DNS.
============================================================
EOF
fi
