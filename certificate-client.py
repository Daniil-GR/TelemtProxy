#!/usr/bin/env python3
"""Domain-scoped TLS certificate client for TelemtProxy (stdlib only)."""

import argparse
import fcntl
import getpass
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import ssl
import stat
import subprocess
import sys
import tempfile
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit, urlencode
from urllib.request import build_opener, HTTPSHandler, HTTPRedirectHandler, Request

BASE = Path("/etc/telemtproxy")
STATE = Path("/var/lib/telemtproxy")
CONFIG = BASE / "certificate-client.json"
ROOT = STATE / "certificate-client"
MAX_BUNDLE = 100_000


class Refused(Exception):
    pass


def run(args, **kw):
    r = subprocess.run(args, text=True, capture_output=True, timeout=60, **kw)
    if r.returncode:
        # Do not expose private input or provider responses in ordinary logs.
        raise Refused("Command failed: " + Path(args[0]).name)
    return r.stdout


def private_file(path):
    path = Path(path)
    s = path.lstat()
    if not stat.S_ISREG(s.st_mode) or s.st_uid != 0 or s.st_mode & 0o077:
        raise Refused("Expected root-owned private regular file: " + str(path))
    return path


def atomic(path, data, mode=0o600):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if path.is_symlink():
        raise Refused("Refusing to replace a symlink: " + str(path))
    fd, tmp = tempfile.mkstemp(dir=path.parent)
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "wb") as f:
            f.write(data if isinstance(data, bytes) else data.encode())
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def validate(cert, key, domain, trust=None):
    """Reject extra SANs, untrusted/expired certificates and mismatched keys."""
    cert, key = Path(cert), private_file(key)
    san = run(["openssl", "x509", "-in", str(cert), "-noout", "-ext", "subjectAltName"])
    names = "".join(san.splitlines()[1:]).strip()
    if names != "DNS:" + domain:
        raise Refused("Certificate must contain exactly the requested DNS name")
    run(["openssl", "x509", "-in", str(cert), "-noout", "-checkend", "86400"])
    with tempfile.TemporaryDirectory() as d:
        leaf = Path(d) / "leaf.pem"
        run(["openssl", "x509", "-in", str(cert), "-out", str(leaf)])
        args = ["openssl", "verify", "-purpose", "sslserver", "-untrusted", str(cert)]
        if trust:
            args += ["-CAfile", str(trust)]
        run(args + ["-verify_hostname", domain, str(leaf)])
        cp = run(["openssl", "x509", "-in", str(cert), "-pubkey", "-noout"])
        kp = run(["openssl", "pkey", "-in", str(key), "-passin", "pass:", "-pubout"])
        if cp.strip() != kp.strip():
            raise Refused("Certificate/private key mismatch")
    return hashlib.sha256(cert.read_bytes() + key.read_bytes()).hexdigest()


def activate(bundle, root, domain, reload=True, trust=None):
    """A single symlink switches certificate and key together; rollback on test/reload failure."""
    root = Path(root)
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    if set(bundle) != {"certificate", "private_key"} or any(
        not isinstance(v, str) for v in bundle.values()
    ):
        raise Refused("Invalid certificate bundle")
    staging = Path(tempfile.mkdtemp(prefix=".candidate-", dir=root))
    try:
        atomic(staging / "fullchain.pem", bundle["certificate"])
        atomic(staging / "privkey.pem", bundle["private_key"])
        digest = validate(staging / "fullchain.pem", staging / "privkey.pem", domain, trust)
        generation = root / digest
        current = root / "current"
        if current.exists() and not current.is_symlink():
            raise Refused("current must be a managed symlink")
        previous = os.readlink(current) if current.is_symlink() else None
        if previous == digest:
            return False
        if not generation.exists():
            os.rename(staging, generation)
        replacement = root / ".next"
        replacement.unlink(missing_ok=True)
        replacement.symlink_to(digest)
        os.replace(replacement, current)
        try:
            if reload:
                run(["nginx", "-t"])
                run(["systemctl", "reload", "nginx"])
        except Exception:
            if previous:
                replacement.symlink_to(previous)
                os.replace(replacement, current)
                # A failed reload may have partially applied: reload restored known-good files.
                run(["nginx", "-t"])
                run(["systemctl", "reload", "nginx"])
            else:
                current.unlink()
            raise
        # Retain one previous generation for recovery, remove other old private keys.
        for p in root.iterdir():
            if (
                p.is_dir()
                and not p.is_symlink()
                and re.fullmatch("[a-f0-9]{64}", p.name)
                and p.name not in {digest, previous}
            ):
                shutil.rmtree(p)
        return True
    finally:
        if staging.exists():
            shutil.rmtree(staging)


def url(value):
    p = urlsplit(value)
    if (
        p.scheme != "https"
        or not p.hostname
        or p.username
        or p.password
        or p.query
        or p.fragment
        or p.path not in ("", "/")
    ):
        raise Refused(
            "Manager must be an HTTPS origin without credentials, path or query"
        )
    return value.rstrip("/")


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, *args):
        raise Refused("Manager redirects are forbidden")


def download(config):
    origin = url(config["manager"])
    private_file(CONFIG)
    opener = build_opener(
        NoRedirect(), HTTPSHandler(context=ssl.create_default_context())
    )
    request = Request(
        origin + "/v1/certificate?" + urlencode({"domain": config["domain"]}),
        headers={"Authorization": "Bearer " + config["token"], "Accept": "application/json", "Cache-Control": "no-store"},
    )
    for attempt in range(3):
        try:
            with opener.open(request, timeout=30) as response:
                data = response.read(MAX_BUNDLE + 1)
                if len(data) > MAX_BUNDLE:
                    raise Refused("Certificate bundle too large")
                return json.loads(data)
        except HTTPError as exc:
            if exc.code not in (429, 500, 502, 503, 504):
                raise Refused("Manager rejected authentication or request") from None
        except (URLError, TimeoutError):
            pass
        if attempt < 2:
            time.sleep(2**attempt)
    raise Refused("Manager unavailable after three attempts; existing TLS retained")


def service(name, command, daily=False):
    # Install only when explicitly invoked on a target machine, never during import/tests.
    unit = Path("/etc/systemd/system")
    command = command.replace("%", "%%")
    atomic(
        unit / (name + ".service"),
        f"""[Unit]
Description=TelemtProxy certificate {name}
Wants=network-online.target
After=network-online.target
[Service]
Type={"oneshot" if daily else "simple"}
ExecStart={command}
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full
ReadWritePaths=/var/lib/telemtproxy
Restart={"no" if daily else "on-failure"}
RestartSec=15
[Install]
WantedBy=multi-user.target
""",
        0o644,
    )
    if daily:
        atomic(
            unit / (name + ".timer"),
            """[Unit]
Description=TelemtProxy automatic certificate check
[Timer]
OnActiveSec=5min
OnUnitActiveSec=6h
RandomizedDelaySec=15min
Persistent=true
[Install]
WantedBy=timers.target
""",
            0o644,
        )
    run(["systemctl", "daemon-reload"])
    run(["systemctl", "enable", "--now", name + (".timer" if daily else ".service")])


def domain_name(value):
    if len(value) > 253 or "." not in value or any(
        not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", part)
        for part in value.split(".")
    ):
        raise Refused("Expected a valid DNS hostname")
    return value


def config_read():
    c = json.loads(private_file(CONFIG).read_text())
    domain_name(c["domain"])
    url(c["manager"])
    return c


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    p = sub.add_parser("setup")
    p.add_argument("--manager", required=True)
    p.add_argument("--domain", required=True)
    sub.add_parser("enable")
    sub.add_parser("renew")
    sub.add_parser("status")
    args = parser.parse_args()
    if os.geteuid() != 0:
        raise Refused("Run as root")
    BASE.mkdir(parents=True, exist_ok=True, mode=0o700)
    STATE.mkdir(parents=True, exist_ok=True, mode=0o700)
    with open(STATE / "certificate-operation.lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if args.action == "setup":
            domain = domain_name(args.domain.lower())
            manager = url(args.manager)
            if CONFIG.exists():
                c = config_read()
                if (c["domain"], c["manager"]) != (domain, manager):
                    raise Refused("Existing certificate client belongs to another domain/manager")
                activate(download(c), ROOT, domain, reload=False)
                print("Managed certificate ready.")
                return
            token = os.environ.pop("TELEMTPROXY_CERT_TOKEN", "") or getpass.getpass(
                "Certificate access key (hidden): "
            )
            if not re.fullmatch(r"[A-Za-z0-9_-]{43}", token):
                raise Refused("Invalid certificate access key")
            c = {"domain": domain, "manager": manager, "token": token}
            atomic(CONFIG, json.dumps(c))
            try:
                activate(download(c), ROOT, domain, reload=False)
            except Exception:
                CONFIG.unlink(missing_ok=True)
                raise
            print("Managed certificate ready.")
        elif args.action == "enable":
            c = config_read()
            validate(ROOT / "current/fullchain.pem", ROOT / "current/privkey.pem", c["domain"])
            run(["nginx", "-t"])
            service("telemtproxy-certificate-client",
                    "/usr/bin/python3 /usr/local/lib/telemtproxy/certificate-client.py renew",
                    True)
            print("Automatic certificate refresh enabled.")
        elif args.action == "renew":
            c = config_read()
            changed = activate(download(c), ROOT, c["domain"])
            print("TLS updated" if changed else "TLS unchanged")
        elif args.action == "status":
            c = config_read()
            print("Domain:", c["domain"])
            validate(ROOT / "current/fullchain.pem", ROOT / "current/privkey.pem", c["domain"])
            print(run(["openssl", "x509", "-in", str(ROOT / "current/fullchain.pem"),
                       "-noout", "-enddate", "-fingerprint", "-sha256"]).strip())


if __name__ == "__main__":
    try:
        main()
    except (Refused, OSError, ValueError, KeyError, subprocess.TimeoutExpired) as exc:
        # Never print HTTP response bodies, credentials, or private key material.
        print("Certificate client failed:", str(exc) if isinstance(exc, Refused) else type(exc).__name__,
              file=sys.stderr)
        sys.exit(1)
