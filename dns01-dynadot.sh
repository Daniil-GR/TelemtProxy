#!/usr/bin/env bash
# Execute ONLY on the trusted certificate manager; never on public proxy nodes.
set -Eeuo pipefail
umask 077
usage() {
 cat <<'HELP'
Usage: sudo bash dns01-dynadot.sh setup|issue|renew --email EMAIL [--staging]
setup installs dependencies, prompts for missing Dynadot credentials (hidden),
issues *.vetka.rest, and enables HTTPS delivery :9444 plus renewal timers.
Set a manager DNS name such as certs.vetka.rest to this manager in advance.
No NS/A/CNAME records are changed. Restricted API keys must be created in Dynadot.
issue/renew use root-owned /etc/telemtproxy/dynadot.env (mode 600).
--staging uses a separate ACME directory and NEVER publishes staging TLS.
Manager node codes: python3 /usr/local/lib/telemtproxy/wildcard.py manager-add-node NAME
Status: python3 /usr/local/lib/telemtproxy/wildcard.py status
HELP
}
[[ ${1:-} != --help && ${1:-} != -h && $# -gt 0 ]] || { usage; exit 0; }
[[ $EUID == 0 ]] || { echo 'Run as root.' >&2; exit 1; }
ACTION=$1; shift
[[ $ACTION == setup || $ACTION == issue || $ACTION == renew ]] || { usage >&2; exit 1; }
EMAIL=''; STAGING=0
while (( $# )); do
 case $1 in
 --email) [[ $# -ge 2 && -n $2 && $2 != --* ]] || { echo 'Missing email' >&2; exit 1; }; EMAIL=$2; shift 2;;
 --staging) STAGING=1; shift;;
 *) echo "Unknown argument: $1" >&2; exit 1;;
 esac
done
[[ $EMAIL =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || { echo 'Valid --email required' >&2; exit 1; }
install -d -m 700 /etc/telemtproxy /var/lib/telemtproxy
exec 9>/var/lib/telemtproxy/dynadot.lock
flock -n 9 || { echo 'Another DNS-01 operation is running.' >&2; exit 1; }
if [[ $ACTION == setup ]]; then
 export DEBIAN_FRONTEND=noninteractive
 apt-get update -qq
 apt-get install -y -qq ca-certificates curl openssl python3 dnsutils util-linux
 install -d -m 755 /usr/local/lib/telemtproxy
 # Use the reviewed helper shipped alongside this file, not an unverified remote script.
 SOURCE_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
 [[ -s $SOURCE_DIR/wildcard.py ]] || { echo 'Download the repository (wildcard.py must accompany this script).' >&2; exit 1; }
 if [[ $SOURCE_DIR/wildcard.py != /usr/local/lib/telemtproxy/wildcard.py ]]; then
  install -m 644 "$SOURCE_DIR/wildcard.py" /usr/local/lib/telemtproxy/wildcard.py
 fi
 if [[ $SOURCE_DIR/dns01-dynadot.sh != /usr/local/lib/telemtproxy/dns01-dynadot.sh ]]; then
  install -m 700 "$SOURCE_DIR/dns01-dynadot.sh" /usr/local/lib/telemtproxy/dns01-dynadot.sh
 fi
 if [[ ! -e /etc/telemtproxy/dynadot.env ]]; then
  read -r -s -p 'Dynadot API key (hidden): ' DYNADOT_API_KEY </dev/tty; echo
  read -r -s -p 'Dynadot API secret (hidden): ' DYNADOT_API_SECRET </dev/tty; echo
  [[ -n $DYNADOT_API_KEY && -n $DYNADOT_API_SECRET ]] || { echo 'Both credentials required' >&2; exit 1; }
  printf 'DYNADOT_API_KEY=%q\nDYNADOT_API_SECRET=%q\n' "$DYNADOT_API_KEY" "$DYNADOT_API_SECRET" >/etc/telemtproxy/dynadot.env
  unset DYNADOT_API_KEY DYNADOT_API_SECRET
 fi
fi
command -v python3 >/dev/null && command -v openssl >/dev/null && command -v dig >/dev/null || { echo 'Missing dependencies: use setup first.' >&2; exit 1; }
HELPER=/usr/local/lib/telemtproxy/wildcard.py
[[ -f $HELPER ]] || { echo 'Install manager using setup first.' >&2; exit 1; }
if ! command -v lego >/dev/null; then
 # Pinned release with the upstream SHA256 manifest checked before extraction.
 python3 - <<'PY'
import hashlib,io,json,os,platform,tarfile,urllib.request
from pathlib import Path
version='5.6.0'
arch={'x86_64':'amd64','aarch64':'arm64'}.get(platform.machine())
if not arch:raise SystemExit('Unsupported lego architecture')
base=f'https://github.com/go-acme/lego/releases/download/v{version}/'
name=f'lego_v{version}_linux_{arch}.tar.gz'
checks=urllib.request.urlopen(base+f'lego_{version}_checksums.txt',timeout=60).read().decode()
expected=next(line.split()[0] for line in checks.splitlines() if line.split()[-1].lstrip('*')==name)
data=urllib.request.urlopen(base+name,timeout=120).read()
if hashlib.sha256(data).hexdigest()!=expected:raise SystemExit('lego checksum mismatch')
with tarfile.open(fileobj=io.BytesIO(data)) as tf:
 m=tf.getmember('lego')
 if not m.isfile():raise SystemExit('Invalid lego archive')
 tmp=Path('/usr/local/bin/lego.new');tmp.write_bytes(tf.extractfile(m).read());tmp.chmod(0o755);os.replace(tmp,'/usr/local/bin/lego')
PY
fi
# v5.6 includes the Dynadot request-body fix; older installed binaries fail closed.
lego --version | python3 -c 'import re,sys;s=re.search(r"version (\d+)\.(\d+)\.(\d+)",sys.stdin.read());sys.exit(0 if s and tuple(map(int,s.groups())) >= (5,6,0) else "lego >=5.6.0 required; update the installed binary")'
python3 - <<'PY'
import os,stat
p='/etc/telemtproxy/dynadot.env';s=os.lstat(p)
assert stat.S_ISREG(s.st_mode) and s.st_uid==0 and not s.st_mode&0o077, 'Dynadot credentials must be root-owned regular file, mode 600'
PY
set -a
# shellcheck disable=SC1091
source /etc/telemtproxy/dynadot.env
set +a
[[ -n ${DYNADOT_API_KEY:-} && -n ${DYNADOT_API_SECRET:-} ]] || { echo 'Both Dynadot credentials required' >&2; exit 1; }
unset LEGO_DEBUG DYNADOT_DEBUG
export DYNADOT_PROPAGATION_TIMEOUT=600 DYNADOT_POLLING_INTERVAL=10
NS=$(dig +short NS vetka.rest)
[[ -n $NS ]] || { echo 'No authoritative nameservers found' >&2; exit 1; }
while read -r ns; do
 [[ $ns == *.dyna-ns.net. ]] || { echo 'Unexpected authority; refusing DNS writes (no NS changes performed)' >&2; exit 1; }
 dig +time=5 +tries=1 +norecurse @"$ns" vetka.rest SOA | grep -q 'flags:.*aa' || { echo 'Authority check failed' >&2; exit 1; }
done <<<"$NS"
STORAGE=/var/lib/telemtproxy/lego-vetka
SERVER=https://acme-v02.api.letsencrypt.org/directory
if (( STAGING )); then STORAGE+=-staging; SERVER=https://acme-staging-v02.api.letsencrypt.org/directory; fi
install -d -m 700 "$STORAGE"
CRT=$STORAGE/certificates/_.vetka.rest.crt
KEY=$STORAGE/certificates/_.vetka.rest.key
if [[ $ACTION == issue && -e $CRT ]]; then echo 'Existing certificate: use renew instead.' >&2; exit 1; fi
ACME_ACTION=run
if [[ -e $CRT ]]; then ACME_ACTION=renew; fi
if [[ $ACTION == renew && ! -s $CRT ]]; then echo 'No certificate; use issue/setup first.' >&2; exit 1; fi
# lego Present appends TXT; CleanUp removes only matching TXT value. Never replace the zone.
# Retain restricted diagnostic logs locally; never forward provider bodies into journal/CI.
LOG=$STORAGE/last-operation.log
SNAPSHOT=$STORAGE/txt-before.json
# A previous unresolved challenge must not become the baseline of the next run.
if [[ -f $SNAPSHOT ]]; then
python3 - "$SNAPSHOT" <<'DNS_CLEANUP'
import json,subprocess,sys,time
from pathlib import Path
before=json.loads(Path(sys.argv[1]).read_text())
for attempt in range(6):
 after={ns:sorted(subprocess.check_output(['dig','+short','+time=5','+tries=1','@'+ns,'TXT','_acme-challenge.vetka.rest'],text=True).strip().splitlines()) for ns in before}
 if after==before:break
 if attempt==5:raise SystemExit('TXT cleanup differs from snapshot; TLS not published. Inspect DNS; no unknown records were deleted.')
 time.sleep(10)
DNS_CLEANUP
 rm -f "$SNAPSHOT"
fi
python3 - "$SNAPSHOT" $NS <<'DNS_SNAPSHOT'
import json,subprocess,sys
from pathlib import Path
result={}
for ns in sys.argv[2:]:
 def dig(kind):return subprocess.check_output(['dig','+short','+time=5','+tries=1','@'+ns,kind,'_acme-challenge.vetka.rest'],text=True).strip()
 if dig('CNAME') or dig('NS'):raise SystemExit('ACME challenge delegation detected; refusing writes')
 result[ns]=sorted(dig('TXT').splitlines())
Path(sys.argv[1]).write_text(json.dumps(result))
DNS_SNAPSHOT
set +e
python3 - "$STORAGE" "$SERVER" "$EMAIL" "$ACME_ACTION" "$LOG" <<'ACME_RUN'
import os,subprocess,sys
storage,server,email,action,log=sys.argv[1:]
args=['lego','run','--path',storage,'--server',server,'--email',email,'--accept-tos','--dns','dynadot','--domains','*.vetka.rest','--renew-days','30']
env={k:v for k,v in os.environ.items() if not k.startswith('LEGO_')}
try:
 r=subprocess.run(args,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=1800,env=env)
 text=r.stdout.decode(errors='replace')
 for key in ('DYNADOT_API_KEY','DYNADOT_API_SECRET'):
  if os.environ.get(key):text=text.replace(os.environ[key],'[REDACTED]')
 with open(log,'w') as f:f.write(text)
 sys.exit(r.returncode)
except subprocess.TimeoutExpired:
 with open(log,'w') as f:f.write('ACME operation timed out; check TXT cleanup before retry.')
 sys.exit(1)
ACME_RUN
STATUS=$?
set -e
chmod -R go-rwx "$STORAGE"
unset DYNADOT_API_KEY DYNADOT_API_SECRET
python3 - "$SNAPSHOT" <<'DNS_CLEANUP'
import json,subprocess,sys,time
from pathlib import Path
before=json.loads(Path(sys.argv[1]).read_text())
for attempt in range(6):
 after={ns:sorted(subprocess.check_output(['dig','+short','+time=5','+tries=1','@'+ns,'TXT','_acme-challenge.vetka.rest'],text=True).strip().splitlines()) for ns in before}
 if after==before:break
 if attempt==5:raise SystemExit('TXT cleanup differs from snapshot; TLS not published. Inspect DNS; no unknown records were deleted.')
 time.sleep(10)
DNS_CLEANUP
rm -f "$SNAPSHOT"
if (( STATUS != 0 )); then echo "DNS-01 failed; current TLS retained. Root-only diagnostics: $LOG" >&2; exit 1; fi
[[ -s $CRT && -s $KEY ]] || { echo 'lego produced no certificate/key' >&2; exit 1; }
if (( STAGING )); then
 openssl x509 -in "$CRT" -noout -ext subjectAltName | python3 -c 'import re,sys;sys.exit(0 if re.findall(r"DNS:([^,\s]+)",sys.stdin.read())==["*.vetka.rest"] else 1)'
 echo 'Staging issuance finished. Staging TLS is not activated or distributed.'; exit 0
fi
python3 - "$CRT" "$KEY" "$HELPER" <<'PY'
import importlib.util,sys
from pathlib import Path
spec=importlib.util.spec_from_file_location('wildcard',sys.argv[3]);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
m.activate({'certificate':Path(sys.argv[1]).read_text(),'private_key':Path(sys.argv[2]).read_text()},m.STATE/'wildcard-manager',reload=False)
PY
if [[ $ACTION == setup ]]; then
 python3 - "$EMAIL" "$HELPER" <<'PY'
import importlib.util,sys
spec=importlib.util.spec_from_file_location('wildcard',sys.argv[2]);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
m.service('telemtproxy-wildcard-manager',f'/usr/bin/python3 {sys.argv[2]} manager-serve')
m.service('telemtproxy-wildcard-issuer',f'/usr/bin/bash /usr/local/lib/telemtproxy/dns01-dynadot.sh renew --email {sys.argv[1]}',True)
PY
else
 systemctl try-restart telemtproxy-wildcard-manager.service
fi
echo 'Production wildcard ready; no individual proxy hostname was sent to ACME.'
