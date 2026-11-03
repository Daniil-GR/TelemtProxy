import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import tomllib
import hashlib

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("gcore_edge", ROOT / "gcore-edge.py")
edge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(edge)

CONFIG = """[general]
ad_tag = "00000000000000000000000000000000"
[general.links]
public_host = "edge.example.org"
[server]
port = 443
[server.api]
enabled = true
listen = "127.0.0.1:9091"
[[server.listeners]]
ip = "0.0.0.0"
port = 443
[censorship]
tls_domain = "www.booking.com"
[access.users]
hello = "11111111111111111111111111111111"
"""
CIDRS = ["92.223.84.0/26", "193.239.179.0/24"]


class EdgeTests(unittest.TestCase):
    def test_network_validation(self):
        self.assertEqual(edge.networks({"addresses": CIDRS + CIDRS}), sorted(CIDRS))
        for value in [
            [],
            ["0.0.0.0/0"],
            ["127.0.0.1/32"],
            ["10.0.0.0/8"],
            ["224.0.0.0/8"],
            ["::/0"],
            ["92.223.84.1/26"],
            ["-j DROP"],
        ]:
            with (
                self.subTest(value=value),
                self.assertRaises((ValueError, KeyError, TypeError)),
            ):
                edge.networks(value)

    def test_config_preserves_profile_and_nested_sections(self):
        old = tomllib.loads(CONFIG)
        expected = copy.deepcopy(old)
        expected["server"].update(
            proxy_protocol=True,
            proxy_protocol_trusted_cidrs=sorted(CIDRS),
            proxy_protocol_header_timeout_ms=3000,
            max_connections=16384,
        )
        actual = edge.patch_config(CONFIG, CIDRS)
        self.assertEqual(tomllib.loads(actual), expected)
        self.assertEqual(edge.patch_config(actual, CIDRS), actual)
        self.assertEqual(tomllib.loads(actual)["access"], old["access"])
        self.assertEqual(tomllib.loads(actual)["general"], old["general"])

    def test_reject_web_and_wrong_port(self):
        for text in [
            CONFIG + "\n[web]\nenabled = true\n",
            CONFIG.replace("port = 443", "port = 9443"),
        ]:
            with self.assertRaises(ValueError):
                edge.patch_config(text, CIDRS)

    def test_firewall_only_changes_own_sets_chains_and_tcp443(self):
        calls = []

        def run(*args, **kwargs):
            calls.append((args, kwargs))

        with (
            patch.object(edge, "run", side_effect=run),
            patch.object(
                edge.subprocess, "run", return_value=subprocess.CompletedProcess([], 1)
            ),
        ):
            edge.firewall(CIDRS)
        iptables = [args for args, kw in calls if args[0] == "iptables"]
        self.assertTrue(
            any(
                "-I" in cmd and "INPUT" in cmd and "--dport" in cmd and "443" in cmd
                for cmd in iptables
            )
        )
        self.assertTrue(all("-F" not in cmd and "-P" not in cmd for cmd in iptables))
        self.assertTrue(all("22" not in cmd for cmd in iptables))
        self.assertEqual(
            [args for args, kw in calls if args[:2] == ("ipset", "swap")],
            [("ipset", "swap", "tm_gcore_edge_next", "tm_gcore_edge")],
        )
        self.assertTrue(
            all(
                args[2] == "tm_gcore_edge_next"
                for args, kw in calls
                if args[:2] == ("ipset", "flush")
            )
        )

    def test_unchanged_sources_never_restart(self):
        with tempfile.TemporaryDirectory() as folder:
            cache = Path(folder) / "cache.json"
            cache.write_text(json.dumps(CIDRS))
            with (
                patch.object(edge, "CACHE", cache),
                patch.object(edge, "fetch", return_value=sorted(CIDRS)),
                patch.object(edge, "run") as run,
            ):
                edge.refresh()
                run.assert_not_called()

    def test_failed_refresh_restores_config_cache_and_firewall(self):
        with tempfile.TemporaryDirectory() as folder:
            config = Path(folder) / "telemt.toml"
            config.write_text(edge.patch_config(CONFIG, CIDRS))
            before = config.read_text()
            cache = Path(folder) / "cache.json"
            cache.write_text(json.dumps(CIDRS))
            attempts = []

            def run(*args, **kwargs):
                attempts.append(args)
                if len(attempts) == 1:
                    raise RuntimeError("restart failed")

            new = CIDRS + ["92.223.116.0/24"]
            with (
                patch.object(edge, "CONFIG", config),
                patch.object(edge, "CACHE", cache),
                patch.object(edge, "fetch", return_value=sorted(new)),
                patch.object(edge, "firewall") as firewall,
                patch.object(edge, "run", side_effect=run),
            ):
                with self.assertRaises(RuntimeError):
                    edge.refresh()
                self.assertEqual(config.read_text(), before)
                self.assertEqual(json.loads(cache.read_text()), CIDRS)
                self.assertEqual(
                    [c.args[0] for c in firewall.call_args_list],
                    [sorted(new), sorted(CIDRS)],
                )
                self.assertEqual(attempts[-1], ("systemctl", "restart", "telemt"))

    def test_atomic_preserves_file_permissions(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "config"
            path.write_text("old")
            path.chmod(0o640)
            edge.atomic(path, "new")
            self.assertEqual(path.read_text(), "new")
            self.assertEqual(path.stat().st_mode & 0o777, 0o640)

    def test_installer_help_and_pinned_helper_match(self):
        result = subprocess.run(
            ["bash", str(ROOT / "deploy-mtproto.sh"), "--help"],
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0)
        self.assertIn("--edge-proxy", result.stdout)
        digest = hashlib.sha256((ROOT / "gcore-edge.py").read_bytes()).hexdigest()
        self.assertIn(digest, (ROOT / "deploy-mtproto.sh").read_text())

    def test_boot_dependencies_and_refresh_frequency(self):
        units = edge.units()
        self.assertIn(
            "Requires=telemt-gcore-firewall.service",
            units["/etc/systemd/system/telemt.service.d/gcore-edge.conf"],
        )
        self.assertIn(
            "OnUnitActiveSec=10min",
            units["/etc/systemd/system/telemt-gcore-refresh.timer"],
        )

    def test_unavailable_api_keeps_existing_files_and_firewall(self):
        with tempfile.TemporaryDirectory() as folder:
            cache = Path(folder) / "cache"
            cache.write_text(json.dumps(CIDRS))
            with (
                patch.object(edge, "CACHE", cache),
                patch.object(edge, "fetch", side_effect=TimeoutError()),
                patch.object(edge, "firewall") as firewall,
                patch.object(edge, "run") as run,
            ):
                with self.assertRaises(TimeoutError):
                    edge.refresh()
                self.assertEqual(json.loads(cache.read_text()), CIDRS)
                firewall.assert_not_called()
                run.assert_not_called()

    def test_custom_connection_limit_is_preserved_on_refresh(self):
        original = edge.patch_config(CONFIG, CIDRS).replace(
            "max_connections = 16384", "max_connections = 32768"
        )
        self.assertEqual(
            tomllib.loads(edge.patch_config(original, CIDRS))["server"][
                "max_connections"
            ],
            32768,
        )

    def test_fresh_install_writes_only_scoped_files(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            config = root / "telemt.toml"
            config.write_text(CONFIG)
            config.chmod(0o640)
            cache, helper = root / "cache.json", root / "lib/helper.py"
            unit = root / "systemd/test.service"
            with (
                patch.object(edge, "CONFIG", config),
                patch.object(edge, "CACHE", cache),
                patch.object(edge, "HELPER", helper),
                patch.object(edge, "units", return_value={str(unit): "unit"}),
                patch.object(edge, "run") as run,
            ):
                edge.install(CIDRS)
                self.assertTrue(
                    tomllib.loads(config.read_text())["server"]["proxy_protocol"]
                )
                self.assertEqual(json.loads(cache.read_text()), sorted(CIDRS))
                self.assertEqual(
                    config.with_name("telemt.toml.before-gcore").read_text(), CONFIG
                )
                self.assertEqual(helper.stat().st_mode & 0o777, 0o700)
                self.assertEqual(cache.stat().st_mode & 0o777, 0o600)
                self.assertEqual(
                    run.call_args_list[0].args, ("systemctl", "daemon-reload")
                )
                before = config.read_text()
                with self.assertRaises(ValueError):
                    edge.install(CIDRS)
                self.assertEqual(config.read_text(), before)


if __name__ == "__main__":
    unittest.main()
