import contextlib
import importlib.util
import io
import json
from pathlib import Path
import socket
import struct
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("cdn_domain", ROOT / "cdn-domain.py")
cdn = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cdn)

CONFIG = """# retained comment
[general]
ad_tag = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
[access.users]
hello = "0123456789abcdef0123456789abcdef"
[web]
enabled = true
carrier = "https-lanes"
[[web.vhosts]]
host = "proxy.example.org"
public_addr = "203.0.113.1:443"
[web.vhosts.decoy]
mode = "static_directory"
directory = "/var/lib/telemt/public"
[[web.vhosts.profiles]]
user = "hello"
secret_mode = "dd"
max_sessions = 8
[unrelated]
value = "keep"
"""
NGINX = """upstream telemt_web { server 127.0.0.1:18080; }
server {
    server_name proxy.example.org;
    ssl_certificate /secure/fullchain.pem;
    ssl_certificate_key /secure/privkey.pem;
    location / {
        proxy_pass http://telemt_web;
        proxy_set_header Host $host;
    }
}
"""


class DomainTests(unittest.TestCase):
    def prepare(self, config=CONFIG, nginx=NGINX):
        return cdn.prepare(config, nginx, "proxy.example.org", "test.example.org")

    def test_add_and_idempotence_preserve_all_existing_settings(self):
        config, nginx = self.prepare()
        parsed = cdn.tomllib.loads(config)
        original = cdn.tomllib.loads(CONFIG)
        self.assertEqual(parsed["web"]["vhosts"][0], original["web"]["vhosts"][0])
        alias = parsed["web"]["vhosts"].pop()
        self.assertEqual(alias.pop("host"), "test.example.org")
        expected = dict(original["web"]["vhosts"][0])
        expected.pop("host")
        self.assertEqual(alias, expected)
        self.assertEqual(parsed, original)
        self.assertIn("# retained comment", config)
        self.assertIn("server_name proxy.example.org test.example.org;", nginx)
        self.assertEqual(self.prepare(config, nginx), (config, nginx))

    def test_conflicting_existing_alias_is_never_overwritten(self):
        config, nginx = self.prepare()
        config = config.replace(
            'host = "test.example.org"',
            'host = "test.example.org"\nbase_path = "different"',
        )
        with self.assertRaises(cdn.Refused):
            self.prepare(config, nginx)

    def test_rejects_shared_nginx_or_canonical_host_rewrite(self):
        for nginx in [
            NGINX.replace(
                "proxy.example.org;", "proxy.example.org unrelated.example.org;"
            ),
            NGINX.replace("Host $host;", "Host proxy.example.org;"),
        ]:
            with self.assertRaises(cdn.Refused):
                self.prepare(nginx=nginx)

    def test_rejects_shell_or_nginx_injection(self):
        for name in [
            "x;evil.example.org",
            "$(touch /tmp/x)",
            "a..example.org",
            "*.example.org",
            "x/evil.example.org",
        ]:
            with self.assertRaises(cdn.Refused):
                cdn.domain(name)

    def test_preserves_multiple_vhost_order(self):
        first, nginx = self.prepare()
        # Add a third vhost from the second group, preserving all earlier groups.
        second, _ = cdn.prepare(first, nginx, "proxy.example.org", "third.example.org")
        self.assertEqual(
            [v["host"] for v in cdn.tomllib.loads(second)["web"]["vhosts"]],
            ["proxy.example.org", "third.example.org", "test.example.org"],
        )

    def test_apply_is_atomic_and_idempotent(self):
        self.exercise_apply(False)

    def test_failed_reload_rolls_back_both_files(self):
        self.exercise_apply(True)

    def exercise_apply(self, fail):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            config, nginx = root / "telemt.toml", root / "nginx.conf"
            config.write_text(CONFIG)
            nginx.write_text(NGINX)
            config.chmod(0o640)
            nginx.chmod(0o644)
            outputs = self.prepare()
            calls = []

            def run(*args):
                calls.append(args)
                if (
                    fail
                    and args == ("systemctl", "reload", "nginx")
                    and calls.count(args) == 1
                ):
                    raise cdn.Refused("fixture failure")

            out = io.StringIO()
            with (
                patch.object(cdn, "run", side_effect=run),
                patch.object(cdn, "ready"),
                contextlib.redirect_stdout(out),
            ):
                if fail:
                    with self.assertRaises(cdn.Refused):
                        cdn.apply(config, nginx, outputs, root / "backups")
                else:
                    cdn.apply(config, nginx, outputs, root / "backups")
                    count = len(calls)
                    cdn.apply(config, nginx, outputs, root / "backups")
                    self.assertEqual(count, len(calls))
            self.assertEqual(
                (config.read_text(), nginx.read_text()),
                (CONFIG, NGINX) if fail else outputs,
            )
            self.assertEqual(config.stat().st_mode & 0o777, 0o640)
            self.assertNotIn("0123456789abcdef", out.getvalue())
            folder = next((root / "backups").iterdir())
            self.assertEqual(folder.stat().st_mode & 0o777, 0o700)
            self.assertEqual((folder / "telemt.toml").stat().st_mode & 0o777, 0o600)
            self.assertEqual((folder / "telemt.toml").read_text(), CONFIG)
            self.assertEqual(
                json.loads((folder / "operation.json").read_text())["stage"],
                "ROLLED_BACK" if fail else "APPLIED",
            )


class DNSPreflightTests(unittest.TestCase):
    def execute(self, mode, answer):
        source = (ROOT / "deploy.sh").read_text()
        marker = 'python3 - "$DOMAIN" "$PUBLIC_IP" "$CDN_MODE" <<\'PY\'\n'
        code = source.split(marker, 1)[1].split("\nPY\n", 1)[0]

        class FakeSocket:
            def __init__(self, *args):
                pass

            def __enter__(self):
                return self

            def __exit__(self, *args):
                pass

            def settimeout(self, timeout):
                pass

            def sendto(self, query, target):
                self.query, self.target = query, target

            def recvfrom(self, size):
                header = self.query[:2] + struct.pack("!HHHHH", 0x8180, 1, 1, 0, 0)
                rr = (
                    b"\xc0\x0c"
                    + struct.pack("!HHIH", 1, 1, 300, 4)
                    + socket.inet_aton(answer)
                )
                return header + self.query[12:] + rr, self.target

        with (
            patch("sys.argv", ["-", "proxy.example.org", "8.8.4.4", mode]),
            patch("socket.socket", FakeSocket),
            contextlib.redirect_stdout(io.StringIO()),
            contextlib.redirect_stderr(io.StringIO()),
        ):
            exec(compile(code, "dns-preflight", "exec"), {})

    def test_direct_accepts_origin_ip(self):
        self.execute("0", "8.8.4.4")

    def test_direct_rejects_cdn_ip(self):
        with self.assertRaises(SystemExit):
            self.execute("0", "9.9.9.9")

    def test_cdn_accepts_public_edge_ip(self):
        self.execute("1", "9.9.9.9")

    def test_cdn_rejects_private_dns(self):
        with self.assertRaises(SystemExit):
            self.execute("1", "127.0.0.1")


if __name__ == "__main__":
    unittest.main()
