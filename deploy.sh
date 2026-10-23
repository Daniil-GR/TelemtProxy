#!/usr/bin/env bash
# Telemt latest stable release + MEKOPR + Nginx/Let's Encrypt + unique runner site
# Fix: WEB-proxy menu S shows link until Enter, avoids automatic screen clear.
# Usage: curl -fsSLo /tmp/deploy-webproxy.sh https://raw.githubusercontent.com/Daniil-GR/TelemtProxy/main/deploy.sh && sudo bash /tmp/deploy-webproxy.sh
# Alternative: sudo bash deploy.sh web.example.org (skips domain prompt)
# IMPORTANT: download to a file before running: this self-contained installer reads its appended assets from $0.
set -Eeuo pipefail
trap 'echo "[ERROR] line $LINENO: deployment interrupted; inspect output above" >&2' ERR
# Stop a package-started Nginx on early failure; do not stop configured HTTPS.
INSTALLER_NGINX_CLEANUP=0
installer_cleanup_on_exit() {
  local status=$?
  if (( status != 0 && INSTALLER_NGINX_CLEANUP == 1 )); then
    echo '[INFO] Stopping Nginx started by this installer after failure.' >&2
    systemctl stop nginx >/dev/null 2>&1 || true
  fi
}
trap installer_cleanup_on_exit EXIT

if [[ "${EUID}" -ne 0 ]]; then echo 'Run as root: sudo bash deploy.sh' >&2; exit 1; fi
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  echo 'Usage: sudo bash deploy.sh [domain.example.org]'
  echo 'If no domain is supplied, the installer prompts for a domain.'
  exit 0
fi
DOMAIN="${1:-}"
if [[ -z "$DOMAIN" ]]; then
  if [[ ! -r /dev/tty ]]; then
    echo 'No terminal available. Pass the domain as the first argument.' >&2
    exit 1
  fi
  read -r -p 'Введите домен WEB-прокси (например, web.example.org): ' DOMAIN </dev/tty || true
fi
DOMAIN="${DOMAIN,,}"
if [[ ! "$DOMAIN" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ || "$DOMAIN" != *.* || "$DOMAIN" == *..* ]]; then
  echo 'Invalid domain. Example: web.example.org' >&2
  exit 1
fi
if [[ ! -f /etc/os-release ]]; then echo 'This installer requires Ubuntu 24.04.' >&2; exit 1; fi
. /etc/os-release
if [[ "${ID:-}" != ubuntu || "${VERSION_ID:-}" != 24.04 ]]; then echo 'Supported OS: Ubuntu 24.04 only.' >&2; exit 1; fi
if [[ -f /etc/telemt/telemt.toml || -e /opt/mtpr-simple/main.sh ]]; then
 echo 'Existing Telemt/MEKOPR installation detected. This installer is for a fresh VPS and will not overwrite it.' >&2
 exit 1
fi
# Check public DNS before installing packages. Python 3 is shipped with Ubuntu.
for cmd in curl python3 getent ss; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Preflight requires $cmd on Ubuntu 24.04." >&2; exit 1; }
done
echo '[0/8] Checking public IP and DNS before installing packages...'
PUBLIC_IP="$(curl -4 -fsS --connect-timeout 5 --max-time 12 https://api.ipify.org)"
if [[ ! "$PUBLIC_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  echo 'Cannot obtain public IPv4.' >&2
  exit 1
fi
DNS_IPS="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u || true)"
if ! grep -Fxq "$PUBLIC_IP" <<< "$DNS_IPS"; then
  echo "DNS A record for $DOMAIN must point to this VPS ($PUBLIC_IP), currently: ${DNS_IPS:-<none>}" >&2
  exit 1
fi
echo "[OK] Domain $DOMAIN resolves to this VPS $PUBLIC_IP"

# DNS queries over UDP without relying on the not-yet-installed dig utility.
python3 - "$DOMAIN" "$PUBLIC_IP" <<'PY'
import secrets
import socket
import struct
import sys

domain, expected_ip = sys.argv[1:]
query_name = b''.join(bytes([len(label)]) + label.encode('ascii') for label in domain.split('.')) + b'\x00'

def skip_name(packet, pos):
    for _ in range(128):
        if pos >= len(packet):
            raise ValueError('Truncated DNS name')
        length = packet[pos]
        if length & 0xc0 == 0xc0:
            if pos + 1 >= len(packet):
                raise ValueError('Truncated DNS pointer')
            return pos + 2
        if length & 0xc0:
            raise ValueError('Invalid DNS label')
        pos += 1
        if length == 0:
            return pos
        pos += length
    raise ValueError('Invalid DNS name')

def resolve_public(resolver):
    request_id = secrets.randbelow(65536)
    question = struct.pack('!HHHHHH', request_id, 0x0100, 1, 0, 0, 0) + query_name + struct.pack('!HH', 1, 1)
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.settimeout(3)
        sock.sendto(question, (resolver, 53))
        reply, source = sock.recvfrom(4096)
    if source[0] != resolver or len(reply) < 12:
        raise ValueError('Invalid DNS reply')
    rid, flags, questions, answers, _, _ = struct.unpack_from('!HHHHHH', reply)
    if rid != request_id or not flags & 0x8000 or flags & 0x000f:
        raise ValueError('DNS error or mismatched response')
    pos = 12
    for _ in range(questions):
        pos = skip_name(reply, pos) + 4
    addresses = []
    for _ in range(answers):
        pos = skip_name(reply, pos)
        qtype, qclass, _ttl, size = struct.unpack_from('!HHIH', reply, pos)
        pos += 10
        if pos + size > len(reply):
            raise ValueError('Truncated DNS answer')
        if qtype == 1 and qclass == 1 and size == 4:
            addresses.append(socket.inet_ntoa(reply[pos:pos + 4]))
        pos += size
    return addresses

failed = False
for resolver in ('1.1.1.1', '8.8.8.8'):
    try:
        addresses = resolve_public(resolver)
    except (OSError, ValueError, struct.error) as exc:
        addresses = []
        print(f'Public DNS @{resolver} for {domain}: error ({exc}); expected {expected_ip}.', file=sys.stderr)
        failed = True
        continue
    if expected_ip not in addresses:
        print(f'Public DNS @{resolver} for {domain}: {", ".join(addresses) or "<none>"}; expected {expected_ip}.', file=sys.stderr)
        failed = True
    else:
        print(f'[OK] Public DNS @{resolver}: {expected_ip}')
if failed:
    sys.exit('Correct the public DNS A record and rerun; no packages have been installed by this attempt.')
PY

# Permit a retry only if port 80 belongs to an untouched Ubuntu Nginx default.
port_occupied() {
  local port="$1"
  ss -lntH | awk -v p="$port" '$4 ~ (":" p "$") {found=1} END {exit !found}'
}
is_untouched_ubuntu_nginx() {
  command -v dpkg >/dev/null 2>&1 || return 1
  command -v nginx >/dev/null 2>&1 || return 1
  systemctl is-active --quiet nginx || return 1
  [[ -L /etc/nginx/sites-enabled/default ]] || return 1
  [[ "$(readlink -f /etc/nginx/sites-enabled/default)" == '/etc/nginx/sites-available/default' ]] || return 1
  [[ -z "$(find /etc/nginx/sites-enabled -mindepth 1 -maxdepth 1 ! -name default -print -quit)" ]] || return 1
  [[ ! -d /etc/nginx/conf.d || -z "$(find /etc/nginx/conf.d -maxdepth 1 -type f -name '*.conf' -print -quit)" ]] || return 1
  dpkg --verify nginx-common >/dev/null 2>&1 || return 1
  ss -lntp | awk '$4 ~ /:80$/ && $0 !~ /users:\(\("nginx"/ {bad=1} END {exit bad}'
}
if port_occupied 80; then
  if is_untouched_ubuntu_nginx && ! port_occupied 443; then
    echo '[INFO] Stopping stock Ubuntu Nginx left by a previous interrupted installation.'
    systemctl stop nginx
  else
    echo 'TCP port 80 is occupied by an unknown or modified service; it will not be stopped.' >&2
    exit 1
  fi
fi
for p in 80 443 9443 18080; do
  if port_occupied "$p"; then
    echo "TCP port $p is occupied. Do not run this installer on a non-fresh server." >&2
    exit 1
  fi
done

echo '[1/8] Installing basic dependencies...'
INSTALLER_NGINX_CLEANUP=1
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ca-certificates curl openssl python3 nginx certbot iproute2 dnsutils
# Apt may automatically start Nginx: release :80 for Certbot and safe retries.
if systemctl is-active --quiet nginx; then
  echo '[INFO] Stopping Nginx auto-started by the Ubuntu package.'
  systemctl stop nginx
fi

# Open only required TCP ports if UFW is already active; never enable or reset it.
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
  ufw allow 80/tcp
  ufw allow 443/tcp
  ufw allow 9443/tcp
fi

SECRET="$(openssl rand -hex 16)"
if [[ ${#SECRET} -ne 32 ]]; then echo 'Secret generation failed.' >&2; exit 1; fi

echo '[2/8] Installing latest stable Telemt release and MEKOPR (without upstream Nginx wizard)...'
INSTALL_SCRIPT="$(mktemp)"
curl -fsSL --retry 3 https://raw.githubusercontent.com/Mekotofeuka/MTPROTO_FIX_By_MEKO/main/install.sh -o "$INSTALL_SCRIPT"
# MEKOPR manages Telemt and SYN FIX on 9443. We configure Nginx separately,
# because MEKOPR's install.sh has been observed to ignore failed nginx restarts.
bash "$INSTALL_SCRIPT" \
  -telemt -domain "$DOMAIN" -port 9443 -version latest \
  -web -web-host "$DOMAIN" -web-user hello -web-secret "$SECRET" \
  -fix -fix-type v3
rm -f "$INSTALL_SCRIPT"

echo "[2b/8] Fixing MEKOPR WEB-link menu (S option)..."
python3 - <<'PY'
from pathlib import Path
import re, shutil, subprocess, sys
p = Path('/opt/mtpr-simple/proxys/telemt1.sh')
if not p.is_file():
    sys.exit('[ERROR] Меню MEKOPR не найдено: ' + str(p))
s = p.read_text(encoding='utf-8')
pattern = re.compile(r'(?m)^([ \t]*)s\|S\)\s*_web_show_link\s+"\$cfg"\s*\|\|\s*true\s*;;[ \t]*$')
found = list(pattern.finditer(s))
if len(found) != 1:
    if re.search(r'(?m)^[ \t]*s\|S\)[^\n]*_web_show_link[^\n]*(?:read -r|read -p)', s) or ('Нажмите Enter для возврата в меню' in s and re.search(r'(?m)^[ \t]*s\|S\)', s)):
        print('[OK] Пункт S уже исправлен.')
        sys.exit(0)
    sys.exit(f'[ERROR] Ожидалась одна строка меню s|S, найдено {len(found)}. Исходник MEKOPR изменился, безопасная автозамена не выполнена.')
m = found[0]
indent = m.group(1)
new_case = '\n'.join((
    indent + 's|S)',
    indent + '    _web_show_link "$cfg" || true',
    indent + '    printf "\\n"',
    indent + '    read -r -p "  Нажмите Enter для возврата в меню..." </dev/tty || true',
    indent + '    ;;',
))
out = s[:m.start()] + new_case + s[m.end():]
backup = p.with_name(p.name + '.bak-before-web-link-fix')
if not backup.exists():
    shutil.copy2(p, backup)
p.write_text(out, encoding='utf-8')
checked = subprocess.run(['bash', '-n', str(p)], capture_output=True, text=True)
if checked.returncode:
    shutil.copy2(backup, p)
    sys.exit('[ERROR] Проверка синтаксиса не пройдена. Исходный файл восстановлен:\n' + checked.stderr)
print('[OK] Пункт S исправлен. Ссылка останется на экране до Enter.')
print('[INFO] Резервная копия:', backup)
PY


[[ -x /usr/local/bin/telemt || -n "$(command -v telemt || :)" ]] || { echo 'Telemt binary missing.' >&2; exit 1; }
echo "[OK] Installed Telemt release: $(telemt --version 2>/dev/null | head -1 || true)"

echo '[3/8] Writing a validated, clean Telemt configuration...'
mkdir -p /etc/telemt /var/lib/telemt/public
if [[ -f /etc/telemt/telemt.toml ]]; then
 cp -a /etc/telemt/telemt.toml "/etc/telemt/telemt.toml.bak.$(date +%s)"
fi
cat > /etc/telemt/telemt.toml <<EOF
[general]
use_middle_proxy = true
ad_tag = ""

[general.modes]
classic = true
secure = true
tls = true

[general.links]
show = ["hello"]
public_host = "$PUBLIC_IP"
public_port = 9443

[server]
port = 9443

[server.api]
enabled = true
listen = "127.0.0.1:9091"
whitelist = ["127.0.0.1/32"]

[censorship]
tls_domain = "$DOMAIN"

[access.users]
hello = "$SECRET"

[[server.listeners]]
ip = "0.0.0.0"
port = 9443

[[server.listeners]]
ip = "127.0.0.1"
port = 18080
transport = "web"
proxy_protocol = false
web_client_ip_source = "x_forwarded_for"
web_trusted_proxy_cidrs = ["127.0.0.1/32"]

[web]
enabled = true
carrier = "https-lanes"

[[web.vhosts]]
host = "$DOMAIN"
public_addr = "$PUBLIC_IP:443"

[web.vhosts.decoy]
mode = "static_directory"
directory = "/var/lib/telemt/public"
index = "index.html"

[[web.vhosts.profiles]]
user = "hello"
secret_mode = "dd"
EOF
chown root:telemt /etc/telemt/telemt.toml
chmod 640 /etc/telemt/telemt.toml
python3 - <<'PY'
import tomllib
with open('/etc/telemt/telemt.toml','rb') as f:
    c=tomllib.load(f)
assert c['web']['enabled'] and c['web']['vhosts'][0]['profiles'][0]['secret_mode']=='dd'
print('[OK] TOML valid')
PY

echo '[4/8] Generating per-server unique runner site...'
SITE_ZIP="$(mktemp --suffix=.zip)"
# The zip archive is appended to the installer as base64, so no site download is needed.
awk '/^__RUNNER_SITE_ZIP_PAYLOAD__$/ {emit=1;next} emit {print}' "${BASH_SOURCE[0]}" | base64 -d > "$SITE_ZIP"
python3 - "$SITE_ZIP" /var/lib/telemt/public <<'PY'
import colorsys, pathlib, random, re, secrets, shutil, sys, tempfile, zipfile
zip_path = pathlib.Path(sys.argv[1]); public = pathlib.Path(sys.argv[2])
with zipfile.ZipFile(zip_path) as z:
    needed=('index.html','style.css','game.js','favicon.svg')
    if not all(n in z.namelist() for n in needed): raise ValueError('Missing site file')
    src={n:z.read(n).decode('utf-8') for n in needed}

rng = random.SystemRandom()
version=secrets.token_hex(7)
html=src['index.html']; css=src['style.css']; js=src['game.js']; svg=src['favicon.svg']
title=rng.choice(('Сайт временно обновляется','Пока мы настраиваем страницу','Небольшой перерыв','Скоро снова онлайн'))
subtitle=rng.choice(('А пока — перепрыгни кактусы!','Попробуй перепрыгнуть все кактусы.','Небольшая игра, пока страница обновляется.'))
html=html.replace('<title>Сайт временно обновляется</title>',f'<title>{title}</title>')
html=html.replace('content="Сайт временно обновляется. А пока — перепрыгни кактусы!"',f'content="{subtitle}"')
# CSS/JS/favicon filenames stay stable; unique cache busting is in the HTML only.
for fn in ('style.css','game.js','favicon.svg'):
    html=html.replace('"/'+fn+'"','"/'+fn+'?v='+version+'"')

# Slight, stable per-install palette change without altering gameplay or layout.
def hue_shift(code, degrees):
    r,g,b=(int(code[i:i+2],16)/255 for i in (1,3,5))
    h,l,s=colorsys.rgb_to_hls(r,g,b)
    r,g,b=colorsys.hls_to_rgb((h+degrees/360)%1,l,s)
    return '#'+''.join(f'{round(v*255):02x}' for v in (r,g,b))
shift=rng.uniform(-10,10)
for color in ('#a7c69b','#aab8a8','#a7d2aa','#253e2b','#263b2b'):
    css=css.replace(color,hue_shift(color,shift))
css+='\n/* asset revision '+secrets.token_hex(12)+' */\n'
js+='\n/* scene revision '+secrets.token_hex(12)+' */\n'
svg=svg.replace('fill="#0a0c0b"',f'fill="{hue_shift("#0a0c0b",shift)}"')
svg=svg.replace('<svg ', '<svg data-r="'+secrets.token_hex(5)+'" ',1)
svg+='\n<!-- '+secrets.token_hex(12)+' -->\n'
html+='\n<!-- '+secrets.token_hex(12)+' -->\n'

# Stage files, then replace; Telemt snapshots them on its subsequent restart.
public.mkdir(parents=True,exist_ok=True)
for name,content in {'index.html':html,'style.css':css,'game.js':js,'favicon.svg':svg}.items():
    (public/name).write_text(content,encoding='utf-8')
    (public/name).chmod(0o644)
print('[OK] Unique site deployed: version',version)
print('[OK] Asset size:',sum((public/n).stat().st_size for n in needed),'bytes')
PY
rm -f "$SITE_ZIP"

echo '[5/8] Obtaining TLS certificate (port 80 must be reachable from Internet)...'
systemctl stop nginx || true
if ss -lntH | awk '$4 ~ /:80$/ {f=1} END {exit !f}'; then
    echo 'Port 80 is still occupied; certbot standalone needs port 80.' >&2; exit 1
fi
certbot certonly --standalone --preferred-challenges http -d "$DOMAIN" \
  --non-interactive --agree-tos --register-unsafely-without-email \
  --keep-until-expiring

if [[ ! -s "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" || ! -s "/etc/letsencrypt/live/$DOMAIN/privkey.pem" ]]; then
 echo 'TLS certificate not found.' >&2; exit 1
fi

echo '[6/8] Configuring Nginx with HTTP/2 and localhost Telemt upstream...'
cat >/etc/nginx/sites-available/default <<EOF
map \$http_upgrade \$telemt_connection_upgrade {
    default upgrade;
    ''      '';
}
upstream telemt_web {
    server 127.0.0.1:18080;
    keepalive 64;
}
server {
    listen 443 ssl http2;
    server_name $DOMAIN;
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    client_max_body_size 2m;
    access_log off;
    location / {
        proxy_pass http://telemt_web;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$telemt_connection_upgrade;
        proxy_connect_timeout 5s;
        proxy_send_timeout 65s;
        proxy_read_timeout 65s;
        proxy_request_buffering off;
        proxy_buffering off;
        proxy_next_upstream off;
    }
}
EOF
# Drop old default HTTP listener if present (we only serve HTTPS here).
nginx -t
systemctl reset-failed nginx || true
systemctl enable --now nginx
systemctl is-active --quiet nginx || { echo 'Nginx failed to start.' >&2; exit 1; }
# Our HTTPS site is configured; preserve it even if a later check fails.
INSTALLER_NGINX_CLEANUP=0

echo '[7/8] Restarting Telemt to load the static-directory snapshot...'
systemctl enable telemt
if ! systemctl restart telemt; then
  echo '[ERROR] Failed to restart Telemt.' >&2
  systemctl status telemt --no-pager --full -n 25 >&2 || true
  journalctl -u telemt -n 60 --no-pager >&2 || true
  exit 1
fi

echo '[7/8] Waiting up to 30 seconds for Telemt WEB HTTP readiness...'
telemt_web_ready=0
telemt_web_deadline=$((SECONDS + 30))
while (( SECONDS < telemt_web_deadline )); do
  if telemt_web_body="$(curl -4 -fsS --noproxy '*' --connect-timeout 1 --max-time 3 \
      -H "Host: $DOMAIN" -H 'X-Forwarded-For: 127.0.0.1' \
      'http://127.0.0.1:18080/' 2>/dev/null)" \
      && [[ "$telemt_web_body" == *'game.js?v='* && "$telemt_web_body" == *'<title>'* ]]; then
    telemt_web_ready=1
    break
  fi
  sleep 1
done

if (( telemt_web_ready != 1 )); then
  echo '[ERROR] Telemt WEB endpoint did not return HTTP 200 with the expected site within 30 seconds.' >&2
  echo '[DIAG] Telemt service status:' >&2
  systemctl status telemt --no-pager --full -n 25 >&2 || true
  echo '[DIAG] Recent Telemt journal:' >&2
  journalctl -u telemt -n 60 --no-pager >&2 || true
  echo '[DIAG] Local listeners:' >&2
  ss -lntp | grep -E ':(443|9443|18080)\b' >&2 || true
  exit 1
fi

echo '[OK] Telemt WEB listener is ready: direct HTTP 200 with expected site.'
ss -lntp | grep -E ':(443|9443|18080)\b' || true

echo '[8/8] HTTP + certificate + asset checks...'
if ! ROOT="$(curl -4 -fsS --noproxy '*' --connect-timeout 5 --max-time 15 \
    --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/")"; then
  echo '[ERROR] Local HTTPS request through Nginx failed.' >&2
  tail -n 30 /var/log/nginx/error.log >&2 || true
  journalctl -u telemt -n 60 --no-pager >&2 || true
  exit 1
fi
if [[ "$ROOT" != *'game.js?v='* || "$ROOT" != *'<title>'* ]]; then
 echo 'Unexpected WEB response: website not loaded.' >&2; exit 1
fi
curl -4 -fsS --noproxy '*' --connect-timeout 5 --max-time 15 --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/game.js" -o /dev/null
curl -4 -fsS --noproxy '*' --connect-timeout 5 --max-time 15 --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/style.css" -o /dev/null
cat <<EOF

====================== READY ======================
Web:          https://$DOMAIN/
WEB proxy:    tg://webproxy?server=$DOMAIN&secret=dd$SECRET
MTProto:      tg://proxy?server=$PUBLIC_IP&port=9443&secret=dd$SECRET
Config:       /etc/telemt/telemt.toml
MEKOPR:       mekopr
===================================================

Save WEB proxy secret securely. Do not publish it in logs or screenshots.
EOF
exit 0
__RUNNER_SITE_ZIP_PAYLOAD__
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
AAAAQh4AAAAA
