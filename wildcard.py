#!/usr/bin/env python3
"""Private wildcard delivery and transactional Nginx TLS updates (stdlib only)."""

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
from urllib.parse import urlsplit
from urllib.request import build_opener, HTTPSHandler, HTTPRedirectHandler, Request

BASE = Path("/etc/telemtproxy")
STATE = Path("/var/lib/telemtproxy")
WILDCARD = "*.vetka.rest"
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


def validate(cert, key, trust=None):
    """Reject extra SANs, untrusted/expired certificates and mismatched keys."""
    cert, key = Path(cert), private_file(key)
    san = run(["openssl", "x509", "-in", str(cert), "-noout", "-ext", "subjectAltName"])
    names = "".join(san.splitlines()[1:]).strip()
    if names != "DNS:" + WILDCARD:
        raise Refused(
            "Certificate must contain exactly DNS:*.vetka.rest; no other SANs"
        )
    run(["openssl", "x509", "-in", str(cert), "-noout", "-checkend", "86400"])
    with tempfile.TemporaryDirectory() as d:
        leaf = Path(d) / "leaf.pem"
        run(["openssl", "x509", "-in", str(cert), "-out", str(leaf)])
        args = ["openssl", "verify", "-purpose", "sslserver", "-untrusted", str(cert)]
        if trust:
            args += ["-CAfile", str(trust)]
        run(args + [str(leaf)])
        cp = run(["openssl", "x509", "-in", str(cert), "-pubkey", "-noout"])
        kp = run(["openssl", "pkey", "-in", str(key), "-passin", "pass:", "-pubout"])
        if cp.strip() != kp.strip():
            raise Refused("Certificate/private key mismatch")
    return hashlib.sha256(cert.read_bytes() + key.read_bytes()).hexdigest()


def activate(bundle, root, reload=True, trust=None):
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
        digest = validate(staging / "fullchain.pem", staging / "privkey.pem", trust)
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
    private_file(BASE / "wildcard-client.json")
    opener = build_opener(
        NoRedirect(), HTTPSHandler(context=ssl.create_default_context())
    )
    request = Request(
        origin + "/v1/certificate",
        headers={"Authorization": "Bearer " + config["token"]},
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
Description=TelemtProxy wildcard {name}
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
Description=TelemtProxy automatic wildcard check
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


def registry():
    p = BASE / "wildcard-nodes.json"
    return json.loads(private_file(p).read_text()) if p.exists() else {}


def bundle():
    root = (STATE / "wildcard-manager/current").resolve()
    validate(root / "fullchain.pem", root / "privkey.pem")
    return {
        "certificate": (root / "fullchain.pem").read_text(),
        "private_key": (root / "privkey.pem").read_text(),
    }


def authorized(header, nodes):
    candidate = hashlib.sha256(header.removeprefix("Bearer ").encode()).hexdigest()
    return header.startswith("Bearer ") and any(
        hmac.compare_digest(candidate, v) for v in nodes.values()
    )


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass  # Never log tokens, keys, paths, provider bodies.

    def setup(self):
        super().setup()
        self.connection.settimeout(10)

    def do_GET(self):
        if self.path != "/v1/certificate":
            self.send_error(404)
            return
        if not authorized(self.headers.get("Authorization", ""), registry()):
            self.send_error(403)
            return
        try:
            data = json.dumps(bundle()).encode()
        except Exception:
            self.send_error(503)
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    p = sub.add_parser("client-setup")
    p.add_argument("--manager", required=True)
    p.add_argument("--domain", required=True)
    sub.add_parser("client-renew")
    sub.add_parser("client-enable")
    sub.add_parser("status")
    p = sub.add_parser("manager-serve")
    p.add_argument("--bind", default="0.0.0.0")
    p.add_argument("--port", type=int, default=9444)
    p = sub.add_parser("manager-add-node")
    p.add_argument("name")
    p = sub.add_parser("manager-revoke-node")
    p.add_argument("name")
    args = parser.parse_args()
    if os.geteuid() != 0:
        raise Refused("Run as root")
    BASE.mkdir(parents=True, exist_ok=True, mode=0o700)
    STATE.mkdir(parents=True, exist_ok=True, mode=0o700)
    with open(STATE / "wildcard-operation.lock", "a") as lock:
        if args.action != "manager-serve":
            fcntl.flock(lock, fcntl.LOCK_EX)
        if args.action == "client-setup":
            if not re.fullmatch(
                r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.vetka\.rest", args.domain
            ):
                raise Refused("Only one-label subdomains of vetka.rest are supported")
            config = BASE / "wildcard-client.json"
            if config.exists():
                raise Refused("Client already configured; use client-renew")
            token = getpass.getpass("Certificate delivery code (hidden): ")
            if not re.fullmatch(r"[A-Za-z0-9_-]{43}", token):
                raise Refused("Invalid delivery code")
            data = {"manager": url(args.manager), "token": token}
            atomic(config, json.dumps(data))
            try:
                activate(download(data), STATE / "wildcard-client", reload=False)
            except Exception:
                config.unlink()
                raise
            print("Wildcard certificate ready; enable timer after Nginx is configured.")
        elif args.action == "client-enable":
            private_file(BASE / "wildcard-client.json")
            root = STATE / "wildcard-client/current"
            validate(root / "fullchain.pem", root / "privkey.pem")
            run(["nginx", "-t"])
            executable = Path(__file__).resolve()
            service(
                "telemtproxy-wildcard-client",
                f"/usr/bin/python3 {executable} client-renew",
                True,
            )
            print("Automatic client renewal enabled.")
        elif args.action == "client-renew":
            config = json.loads(private_file(BASE / "wildcard-client.json").read_text())
            changed = activate(download(config), STATE / "wildcard-client")
            print("TLS updated" if changed else "TLS unchanged")
        elif args.action == "status":
            for role in ("manager", "client"):
                root = STATE / f"wildcard-{role}/current"
                if root.exists():
                    validate(root / "fullchain.pem", root / "privkey.pem")
                    print(
                        role,
                        run(
                            [
                                "openssl",
                                "x509",
                                "-in",
                                str(root / "fullchain.pem"),
                                "-noout",
                                "-enddate",
                                "-fingerprint",
                                "-sha256",
                            ]
                        ).strip(),
                    )
        elif args.action in ("manager-add-node", "manager-revoke-node"):
            if not re.fullmatch(r"[a-zA-Z0-9_-]{1,64}", args.name):
                raise Refused("Invalid node label")
            nodes = registry()
            if args.action == "manager-add-node":
                if args.name in nodes:
                    raise Refused("Node exists; revoke before replacing")
                token = secrets.token_urlsafe(32)
                nodes[args.name] = hashlib.sha256(token.encode()).hexdigest()
            else:
                if args.name not in nodes:
                    raise Refused("Unknown node")
                del nodes[args.name]
            atomic(BASE / "wildcard-nodes.json", json.dumps(nodes))
            if args.action == "manager-add-node":
                print(
                    "Save this private delivery code; it will not be shown again:\n"
                    + token
                )
        elif args.action == "manager-serve":
            root = STATE / "wildcard-manager/current"
            validate(root / "fullchain.pem", root / "privkey.pem")
            ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            ctx.minimum_version = ssl.TLSVersion.TLSv1_2
            ctx.load_cert_chain(root / "fullchain.pem", root / "privkey.pem")
            server = HTTPServer((args.bind, args.port), Handler)
            # TLS handshakes happen in the request loop with a timeout, not in accept().
            original = server.get_request

            def connection():
                sock, addr = original()
                sock.settimeout(10)
                try:
                    return ctx.wrap_socket(sock, server_side=True), addr
                except Exception:
                    sock.close()
                    raise OSError("TLS handshake refused") from None

            server.get_request = connection
            server.serve_forever()


if __name__ == "__main__":
    try:
        main()
    except (Refused, OSError, ValueError, subprocess.SubprocessError):
        # Exceptions can contain request credentials; only Refused messages are deliberately safe.
        error = sys.exc_info()[1]
        print(
            "ERROR: "
            + (
                str(error)
                if isinstance(error, Refused)
                else "Operation failed; existing configuration retained"
            ),
            file=sys.stderr,
        )
        sys.exit(1)
