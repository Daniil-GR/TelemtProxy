import base64
import hashlib
import importlib.util
import json
import shutil
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import zlib

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("wildcard", ROOT / "wildcard.py")
w = importlib.util.module_from_spec(spec)
spec.loader.exec_module(w)


class CertificateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.root = Path(cls.tmp.name)

        def cmd(*args):
            subprocess.run(
                args, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
            )

        cls.cmd = staticmethod(cmd)
        cmd(
            "openssl",
            "req",
            "-x509",
            "-newkey",
            "rsa:2048",
            "-nodes",
            "-keyout",
            str(cls.root / "ca.key"),
            "-out",
            str(cls.root / "ca.pem"),
            "-subj",
            "/CN=Test CA",
            "-days",
            "3",
            "-addext",
            "basicConstraints=critical,CA:TRUE",
        )
        for name, san in [
            ("valid", "DNS:*.vetka.rest"),
            ("other", "DNS:*.vetka.rest"),
            ("exact", "DNS:*.vetka.rest,DNS:lt.vetka.rest"),
            ("apex", "DNS:*.vetka.rest,DNS:vetka.rest"),
            ("ip", "DNS:*.vetka.rest,IP:192.0.2.1"),
        ]:
            key = cls.root / (name + ".key")
            csr = cls.root / (name + ".csr")
            cert = cls.root / (name + ".pem")
            ext = cls.root / (name + ".ext")
            cmd(
                "openssl",
                "req",
                "-new",
                "-newkey",
                "rsa:2048",
                "-nodes",
                "-keyout",
                str(key),
                "-out",
                str(csr),
                "-subj",
                "/CN=*.vetka.rest",
            )
            key.chmod(0o600)
            ext.write_text(
                "subjectAltName="
                + san
                + "\nextendedKeyUsage=serverAuth\nbasicConstraints=CA:FALSE\n"
            )
            cmd(
                "openssl",
                "x509",
                "-req",
                "-in",
                str(csr),
                "-CA",
                str(cls.root / "ca.pem"),
                "-CAkey",
                str(cls.root / "ca.key"),
                "-CAcreateserial",
                "-out",
                str(cert),
                "-days",
                "2",
                "-extfile",
                str(ext),
            )

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def bundle(self, name="valid"):
        return {
            "certificate": (self.root / (name + ".pem")).read_text(),
            "private_key": (self.root / (name + ".key")).read_text(),
        }

    def test_exact_wildcard_only_key_and_trust(self):
        w.validate(
            self.root / "valid.pem", self.root / "valid.key", self.root / "ca.pem"
        )
        for name in ("exact", "apex", "ip"):
            with self.assertRaises(w.Refused):
                w.validate(
                    self.root / (name + ".pem"),
                    self.root / (name + ".key"),
                    self.root / "ca.pem",
                )
        with self.assertRaises(w.Refused):
            w.validate(
                self.root / "valid.pem", self.root / "other.key", self.root / "ca.pem"
            )
        with self.assertRaises(w.Refused):
            w.validate(self.root / "valid.pem", self.root / "valid.key")

    def test_expired_certificate_is_rejected(self):
        cert = self.root / "expired.pem"
        self.cmd(
            "openssl",
            "x509",
            "-req",
            "-in",
            str(self.root / "valid.csr"),
            "-CA",
            str(self.root / "ca.pem"),
            "-CAkey",
            str(self.root / "ca.key"),
            "-CAcreateserial",
            "-out",
            str(cert),
            "-days",
            "0",
            "-extfile",
            str(self.root / "valid.ext"),
        )
        with self.assertRaises(w.Refused):
            w.validate(cert, self.root / "valid.key", self.root / "ca.pem")

    def test_permissions_and_symlink(self):
        p = self.root / "copy.key"
        p.write_bytes((self.root / "valid.key").read_bytes())
        p.chmod(0o644)
        with self.assertRaises(w.Refused):
            w.private_file(p)
        p.unlink()
        p.symlink_to(self.root / "valid.key")
        with self.assertRaises(w.Refused):
            w.private_file(p)
        p.unlink()

    def test_atomic_update_idempotence_and_rollback(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            w.activate(self.bundle(), root, reload=False, trust=self.root / "ca.pem")
            previous = os.readlink(root / "current")
            with patch.object(w, "run", wraps=w.run) as command:
                self.assertFalse(
                    w.activate(self.bundle(), root, trust=self.root / "ca.pem")
                )
                self.assertFalse(
                    any(c.args[0][0] == "nginx" for c in command.call_args_list)
                )
            original = w.run
            calls = []

            def fake(args, **kwargs):
                if args[0] in ("nginx", "systemctl"):
                    calls.append(args)
                    if len(calls) == 1:
                        raise w.Refused("bad nginx")
                    return ""
                return original(args, **kwargs)

            with patch.object(w, "run", side_effect=fake):
                with self.assertRaises(w.Refused):
                    w.activate(self.bundle("other"), root, trust=self.root / "ca.pem")
            self.assertEqual(os.readlink(root / "current"), previous)
            self.assertEqual(calls[-1], ["systemctl", "reload", "nginx"])
            w.validate(
                root / "current/fullchain.pem",
                root / "current/privkey.pem",
                self.root / "ca.pem",
            )

    def test_invalid_candidate_never_changes_active_files(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            w.activate(self.bundle(), root, reload=False, trust=self.root / "ca.pem")
            previous = os.readlink(root / "current")
            with self.assertRaises(w.Refused):
                w.activate(self.bundle("exact"), root, trust=self.root / "ca.pem")
            self.assertEqual(os.readlink(root / "current"), previous)

    def test_authenticated_https_delivery(self):
        import socket
        import ssl
        import threading
        import secrets

        token = secrets.token_urlsafe(32)
        nodes = {"test": hashlib.sha256(token.encode()).hexdigest()}
        server = w.HTTPServer(("127.0.0.1", 0), w.Handler)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(self.root / "valid.pem", self.root / "valid.key")
        server.socket = context.wrap_socket(server.socket, server_side=True)
        client = ssl.create_default_context(cafile=str(self.root / "ca.pem"))

        def request(header="", path="/v1/certificate"):
            with socket.create_connection(server.server_address, timeout=5) as sock:
                with client.wrap_socket(
                    sock, server_hostname="certs.vetka.rest"
                ) as conn:
                    conn.sendall(
                        (
                            "GET "
                            + path
                            + " HTTP/1.1\r\nHost: certs.vetka.rest\r\n"
                            + header
                            + "Connection: close\r\n\r\n"
                        ).encode()
                    )
                    data = b""
                    while chunk := conn.recv(65536):
                        data += chunk
                    return data

        with (
            patch.object(w, "registry", return_value=nodes),
            patch.object(w, "bundle", return_value=self.bundle()),
        ):
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                denied = request()
                self.assertIn(b"403", denied.splitlines()[0])
                self.assertNotIn(b"PRIVATE KEY", denied)
                allowed = request("Authorization: Bearer " + token + "\r\n")
                self.assertIn(b"200", allowed.splitlines()[0])
                self.assertIn(b"Cache-Control: no-store", allowed)
                self.assertEqual(
                    json.loads(allowed.split(b"\r\n\r\n", 1)[1]), self.bundle()
                )
                missing = request("Authorization: Bearer " + token + "\r\n", "/other")
                self.assertIn(b"404", missing.splitlines()[0])
            finally:
                server.shutdown()
                server.server_close()
                thread.join(timeout=5)


class ProtocolTests(unittest.TestCase):
    def test_auth_isolated_and_revocable(self):
        token = "private-test-token"
        nodes = {"one": hashlib.sha256(token.encode()).hexdigest()}
        self.assertTrue(w.authorized("Bearer " + token, nodes))
        for header in ("", "Bearer wrong", token):
            self.assertFalse(w.authorized(header, nodes))
        self.assertFalse(w.authorized("Bearer " + token, {}))

    def test_https_only_no_redirect_or_embedded_credentials(self):
        for value in (
            "http://manager.example",
            "https://a:b@manager.example",
            "https://manager.example/x",
            "https://manager.example?token=oops",
        ):
            with self.assertRaises(w.Refused):
                w.url(value)
        self.assertEqual(
            w.url("https://certs.vetka.rest:9444/"), "https://certs.vetka.rest:9444"
        )
        with self.assertRaises(w.Refused):
            w.NoRedirect().redirect_request(None, None, None, None, None, None)

    def test_download_retries_and_never_accepts_oversize(self):
        class Response:
            def __enter__(self):
                return self

            def __exit__(self, *args):
                pass

            def read(self, n):
                return b"x" * (w.MAX_BUNDLE + 1)

        with patch.object(w, "private_file"), patch.object(w, "build_opener") as opener:
            opener.return_value.open.return_value = Response()
            with self.assertRaises(w.Refused):
                w.download({"manager": "https://certs.vetka.rest", "token": "test"})
            opener.return_value.open.side_effect = w.URLError("down")
            with patch.object(w.time, "sleep"):
                with self.assertRaises(w.Refused):
                    w.download({"manager": "https://certs.vetka.rest", "token": "test"})
            self.assertEqual(opener.return_value.open.call_count, 4)

    def test_flags_rejected_before_installation(self):
        for args in [
            ["--wildcard", "--cdn"],
            ["--cert-manager", "https://certs.vetka.rest"],
            ["--wildcard", "--domain", "outside.example"],
            ["--wildcard", "--domain", "lt.vetka.rest", "--cert-manager", "http://bad"],
            ["--wildcard", "--wildcard-cert", "/x", "--wildcard-key", "/y"],
        ]:
            result = subprocess.run(
                ["bash", str(ROOT / "deploy.sh"), *args], capture_output=True, text=True
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("[1/8]", result.stdout)
        for script in ("deploy.sh", "deploy-mtproto.sh", "dns01-dynadot.sh"):
            self.assertEqual(
                subprocess.run(["bash", "-n", str(ROOT / script)]).returncode, 0
            )
            self.assertEqual(
                subprocess.run(
                    ["bash", str(ROOT / script), "--help"], capture_output=True
                ).returncode,
                0,
            )

    def test_embedded_helper_matches_source(self):
        text = (ROOT / "deploy.sh").read_text()
        payload = re.search(
            r"p.write_bytes\(zlib.decompress\(base64.b64decode\('([^']+)'\)\)\)", text
        ).group(1)
        self.assertEqual(
            zlib.decompress(base64.b64decode(payload)),
            (ROOT / "wildcard.py").read_bytes(),
        )
        self.assertIn(
            "'--domains','*.vetka.rest'", (ROOT / "dns01-dynadot.sh").read_text()
        )


class DNSWorkflowTests(unittest.TestCase):
    def source(self, label):
        text = (ROOT / "dns01-dynadot.sh").read_text()
        return text.split("<<'" + label + "'\n", 1)[1].split("\n" + label, 1)[0]

    def test_lego_exact_name_and_redacted_failures(self):
        from types import SimpleNamespace

        with tempfile.TemporaryDirectory() as d:
            log = Path(d) / "private.log"
            seen = []

            def fake(args, **kwargs):
                seen.append(args)
                return SimpleNamespace(
                    returncode=1, stdout=b"provider failed secret-key secret-password"
                )

            with (
                patch.dict(
                    os.environ,
                    {
                        "DYNADOT_API_KEY": "secret-key",
                        "DYNADOT_API_SECRET": "secret-password",
                    },
                ),
                patch.object(subprocess, "run", side_effect=fake),
                patch(
                    "sys.argv",
                    [
                        "script",
                        d,
                        "https://staging.example/directory",
                        "test@example.org",
                        "run",
                        str(log),
                    ],
                ),
            ):
                with self.assertRaises(SystemExit) as err:
                    exec(compile(self.source("ACME_RUN"), "<acme-test>", "exec"), {})
            self.assertEqual(err.exception.code, 1)
            self.assertEqual(seen[0][1], "run")
            self.assertIn("--renew-days", seen[0])
            self.assertEqual(seen[0][seen[0].index("--domains") + 1], "*.vetka.rest")
            self.assertNotIn("secret-key", " ".join(seen[0]))
            self.assertNotIn("secret-password", log.read_text())
            self.assertIn("[REDACTED]", log.read_text())

    def test_snapshot_preserves_other_txt_and_cleanup_requires_exact_match(self):
        with tempfile.TemporaryDirectory() as d:
            snapshot = Path(d) / "snapshot.json"

            def answer(args, **kw):
                return '"unrelated TXT"\n' if args[-2] == "TXT" else ""

            with (
                patch.object(subprocess, "check_output", side_effect=answer),
                patch("sys.argv", ["script", str(snapshot), "ns1.dyna-ns.net."]),
            ):
                exec(compile(self.source("DNS_SNAPSHOT"), "<dns-test>", "exec"), {})
            self.assertEqual(
                json.loads(snapshot.read_text()),
                {"ns1.dyna-ns.net.": ['"unrelated TXT"']},
            )
            with (
                patch.object(
                    subprocess, "check_output", return_value='"unrelated TXT"\n'
                ),
                patch("sys.argv", ["script", str(snapshot)]),
            ):
                exec(compile(self.source("DNS_CLEANUP"), "<cleanup-test>", "exec"), {})
            with (
                patch.object(
                    subprocess,
                    "check_output",
                    return_value='"unrelated TXT"\n"stale ACME value"\n',
                ),
                patch.object(w.time, "sleep"),
                patch("sys.argv", ["script", str(snapshot)]),
            ):
                with self.assertRaises(SystemExit):
                    exec(
                        compile(self.source("DNS_CLEANUP"), "<cleanup-test>", "exec"),
                        {},
                    )

    def test_delegation_rejected_without_dns_writes(self):
        with (
            tempfile.TemporaryDirectory() as d,
            patch.object(
                subprocess, "check_output", return_value="delegated.example.\n"
            ),
            patch(
                "sys.argv", ["script", str(Path(d) / "snapshot"), "ns1.dyna-ns.net."]
            ),
        ):
            with self.assertRaises(SystemExit):
                exec(compile(self.source("DNS_SNAPSHOT"), "<dns-test>", "exec"), {})

    def test_nginx_template_accepts_wildcard_pair(self):
        if not shutil.which("nginx"):
            self.skipTest("nginx binary not available")
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            subprocess.run(
                [
                    "openssl",
                    "req",
                    "-x509",
                    "-newkey",
                    "rsa:2048",
                    "-nodes",
                    "-keyout",
                    str(root / "key.pem"),
                    "-out",
                    str(root / "cert.pem"),
                    "-subj",
                    "/CN=*.vetka.rest",
                    "-addext",
                    "subjectAltName=DNS:*.vetka.rest",
                    "-days",
                    "2",
                ],
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            source = (
                (ROOT / "deploy.sh")
                .read_text()
                .split("cat >/etc/nginx/sites-available/default <<EOF\n", 1)[1]
                .split("\nEOF", 1)[0]
            )
            source = (
                source.replace("$DOMAIN", "lt.vetka.rest")
                .replace("$TLS_CERT_PATH", str(root / "cert.pem"))
                .replace("$TLS_KEY_PATH", str(root / "key.pem"))
                .replace("\\$", "$")
            )
            config = root / "nginx.conf"
            config.write_text(
                "pid "
                + str(root / "nginx.pid")
                + ";\nerror_log "
                + str(root / "error.log")
                + ";\nevents{}\nhttp{"
                + source
                + "}\n"
            )
            result = subprocess.run(
                ["nginx", "-t", "-p", str(root), "-c", str(config)],
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
