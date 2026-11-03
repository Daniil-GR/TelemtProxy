#!/usr/bin/env python3
"""Dedicated fresh-VPS Gcore Edge integration; never changes SSH or routing."""

import argparse
import copy
import fcntl
import ipaddress
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import tomllib
import urllib.request

URL = "https://api.gcore.com/cdn/public-net-list"
CONFIG = Path("/etc/telemt/telemt.toml")
CACHE = Path("/etc/telemt/gcore-edge-cidrs.json")
HELPER = Path("/usr/local/lib/telemtproxy/gcore-edge.py")
CHAIN = "TM_GCORE_EDGE"
IPSET = "tm_gcore_edge"


def networks(data):
    values = data["addresses"] if isinstance(data, dict) else data
    if not isinstance(values, list) or not 1 <= len(values) <= 16384:
        raise ValueError("Empty or oversized Gcore network list")
    result = set()
    for value in values:
        net = ipaddress.ip_network(value, strict=True)
        if (
            net.version != 4
            or net.prefixlen < 8
            or not net.network_address.is_global
            or not net.broadcast_address.is_global
            or net.is_multicast
        ):
            raise ValueError("Unsafe network in Gcore IPv4 list")
        result.add(str(net))
    return sorted(result)


def fetch():
    # HTTPS verification stays enabled. No account token is needed.
    with urllib.request.urlopen(URL, timeout=20) as response:
        data = response.read(2_000_001)
        if len(data) > 2_000_000:
            raise ValueError("Oversized Gcore response")
    return networks(json.loads(data))


def patch_config(text, cidrs):
    original = tomllib.loads(text)
    if original.get("server", {}).get("port") != 443 or "web" in original:
        raise ValueError("Expected standalone MTProto on port 443")
    expected = copy.deepcopy(original)
    fields = {
        "proxy_protocol": True,
        "proxy_protocol_trusted_cidrs": networks(cidrs),
        "proxy_protocol_header_timeout_ms": 3000,
    }
    if "max_connections" not in original["server"]:
        fields["max_connections"] = 16384
    expected["server"].update(fields)
    blocks = list(re.finditer(r"(?ms)^\[server\][ \t]*\n(.*?)(?=^\[|\Z)", text))
    if len(blocks) != 1:
        raise ValueError("Ambiguous server section")
    block = blocks[0]
    body = block[1]
    for name, value in fields.items():
        # This installer writes one-line keys; refuse unknown multiline layouts.
        matches = list(re.finditer(r"(?m)^" + name + r"[ \t]*=.*$", body))
        if len(matches) > 1:
            raise ValueError("Duplicate managed setting")
        line = name + " = " + json.dumps(value)
        if matches:
            m = matches[0]
            body = body[: m.start()] + line + body[m.end() :]
        else:
            body += line + "\n"
    updated = text[: block.start(1)] + body + text[block.end(1) :]
    if tomllib.loads(updated) != expected:
        raise ValueError("Unexpected config changes; refusing to apply")
    return updated


def atomic(path, data, mode=0o600):
    path.parent.mkdir(parents=True, exist_ok=True)
    previous = path.stat() if path.exists() else None
    descriptor, name = tempfile.mkstemp(prefix="." + path.name, dir=path.parent)
    try:
        with os.fdopen(descriptor, "w") as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
            os.fchmod(output.fileno(), previous.st_mode & 0o777 if previous else mode)
            if previous:
                os.fchown(output.fileno(), previous.st_uid, previous.st_gid)
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def run(*args, **kwargs):
    return subprocess.run(args, check=True, capture_output=True, text=True, **kwargs)


def firewall(cidrs):
    cidrs = networks(cidrs)
    # Swap complete sets atomically; never flush the host firewall.
    staging = IPSET + "_next"
    run(
        "ipset",
        "create",
        IPSET,
        "hash:net",
        "family",
        "inet",
        "maxelem",
        "32768",
        "-exist",
    )
    run(
        "ipset",
        "create",
        staging,
        "hash:net",
        "family",
        "inet",
        "maxelem",
        "32768",
        "-exist",
    )
    run("ipset", "flush", staging)
    run(
        "ipset",
        "restore",
        input="".join("add " + staging + " " + net + "\n" for net in cidrs),
    )
    run("ipset", "swap", staging, IPSET)
    run("ipset", "destroy", staging)

    def exists(*args):
        return (
            subprocess.run(
                ("iptables", "-w", "10", *args), capture_output=True
            ).returncode
            == 0
        )

    if not exists("-S", CHAIN):
        run("iptables", "-w", "10", "-N", CHAIN)
    rules = [("-m", "set", "--match-set", IPSET, "src", "-j", "ACCEPT"), ("-j", "DROP")]
    for rule in rules:
        if not exists("-C", CHAIN, *rule):
            run("iptables", "-w", "10", "-A", CHAIN, *rule)
    jump = ("-p", "tcp", "--dport", "443", "-j", CHAIN)
    if not exists("-C", "INPUT", *jump):
        run("iptables", "-w", "10", "-I", "INPUT", "1", *jump)


def units():
    return {
        "/etc/systemd/system/telemt-gcore-firewall.service": """[Unit]
Description=Gcore Edge allowlist for Telemt TCP 443
Before=telemt.service
After=network-pre.target
[Service]
Type=oneshot
ExecStart=/usr/bin/python3 /usr/local/lib/telemtproxy/gcore-edge.py firewall
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
""",
        "/etc/systemd/system/telemt.service.d/gcore-edge.conf": """[Unit]
Requires=telemt-gcore-firewall.service
After=telemt-gcore-firewall.service
""",
        "/etc/systemd/system/telemt-gcore-refresh.service": """[Unit]
Description=Refresh official Gcore Edge networks
After=network-online.target telemt.service
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/bin/python3 /usr/local/lib/telemtproxy/gcore-edge.py refresh
TimeoutStartSec=120
""",
        "/etc/systemd/system/telemt-gcore-refresh.timer": """[Unit]
Description=Update Gcore Edge networks every ten minutes
[Timer]
OnBootSec=3min
OnUnitActiveSec=10min
Persistent=true
[Install]
WantedBy=timers.target
""",
    }


def install(cidrs):
    text = CONFIG.read_text()
    updated = patch_config(text, cidrs)
    for path in [CACHE, HELPER, *map(Path, units())]:
        if path.exists():
            raise ValueError("Existing Edge integration; use refresh instead")
    # Keep a local private rollback copy, without copying any old server profile.
    backup = CONFIG.with_name("telemt.toml.before-gcore")
    if backup.exists():
        raise ValueError("Backup already exists")
    atomic(backup, text)
    atomic(HELPER, Path(__file__).read_text(), 0o700)
    atomic(CACHE, json.dumps(networks(cidrs)))
    atomic(CONFIG, updated)
    for path, content in units().items():
        atomic(Path(path), content, 0o644)
    run("systemctl", "daemon-reload")
    run("systemctl", "enable", "--now", "telemt-gcore-firewall.service")
    run("systemctl", "enable", "--now", "telemt-gcore-refresh.timer")


def refresh():
    old = networks(json.loads(CACHE.read_text()))
    new = fetch()
    if old == new:
        print("Gcore networks unchanged; no restart")
        return
    before = CONFIG.read_text()
    updated = patch_config(before, new)
    try:
        atomic(CONFIG, updated)
        firewall(new)
        run("systemctl", "restart", "telemt")
        run("systemctl", "is-active", "--quiet", "telemt")
        atomic(CACHE, json.dumps(new))
    except Exception:
        atomic(CONFIG, before)
        firewall(old)
        run("systemctl", "restart", "telemt")
        raise
    print("Gcore networks updated; Telemt restarted, config rollback available")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["fetch", "install", "firewall", "refresh"])
    parser.add_argument("--cidrs-file", type=Path)
    args = parser.parse_args()
    if args.action == "fetch":
        print(json.dumps(fetch()))
        return
    if os.geteuid() != 0:
        parser.error("Run as root")
    with open("/run/lock/telemt-gcore-edge.lock", "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if args.action == "install":
            if not args.cidrs_file:
                parser.error("install requires --cidrs-file")
            install(networks(json.loads(args.cidrs_file.read_text())))
        elif args.action == "firewall":
            firewall(networks(json.loads(CACHE.read_text())))
        else:
            refresh()


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        # Do not print config, commands or exception details containing credentials.
        print(
            "Gcore Edge setup failed: "
            + type(error).__name__
            + ". Inspect systemd journal and the local config before retrying.",
            file=sys.stderr,
        )
        sys.exit(1)
