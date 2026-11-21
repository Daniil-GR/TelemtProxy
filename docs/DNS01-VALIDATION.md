# DNS-01 implementation validation

Repository-only development. No SSH sessions, VPS deployments, live Dynadot writes, key creation, or real ACME issuance were performed.

## Local evidence

- `bash -n deploy.sh deploy-mtproto.sh dns01-dynadot.sh` (run individually): passed.
- Python compilation and Ruff for new Python files: passed.
- `sudo python3 -m unittest discover -s tests -v`: 38 tests. Run as root because the installer and private-key checks explicitly require root ownership. Tests use temporary directories and mocks for service changes, not production configuration.
- Existing CDN and Edge tests preserved unchanged and passing.
- Locally generated test CA/certificates: exact wildcard, additional named SAN, apex SAN, IP SAN, expired certificate, wrong key, untrusted CA, insecure key mode, key symlink.
- Atomic activation, no-op repeat update, invalid candidate, and rollback after simulated failed Nginx validation.
- Loopback HTTPS test with the test CA: unauthorized 403, authenticated bundle 200, no-store, wrong path 404. This is a temporary unit-test fixture, not a manager deployment.
- Actual local `nginx -t` using the installer template and a temporary wildcard key/certificate: passed. No Nginx process started or reloaded.
- Mock DNS snapshot/cleanup: preserves unrelated challenge TXT and fails on stale values or delegation. Does not contact Dynadot.
- Downloaded official lego 5.6.0 Linux amd64 archive to a temporary folder; verified SHA256 against the official release manifest, executed `--version`, `run --help`, full command with `--help`, and `dnshelp --code dynadot`. No ACME/DNS operation executed. Found and corrected the old incompatible `lego ... renew --days 30` invocation; v5.6 uses `lego run ... --renew-days 30`.
- Installer's appended runner archive compared with original main: unchanged.
- Unauthenticated private GitHub raw installer URL returned 404. README includes an authenticated bootstrap command that prompts for a read token without storing it in shell history or argv.

## Not established by these tests

- Actual Restricted Key scopes in the user's Dynadot account. Official docs establish credentials and IP restrictions, not verified per-domain/TXT-only scopes.
- Real Dynadot API authorization, propagation and cleanup under concurrent external DNS management.
- Real Let's Encrypt staging or production issuance.
- Systemd operation after reboot, real fleet delivery, real Nginx reload on an Ubuntu 24.04 test VPS.

Before rollout: verify the dedicated key's real scope and whitelist; prepare the trusted manager's DNS/network access; run `setup --staging`, then production `setup`; register node delivery codes; install a clean test VPS with `--wildcard`; verify an actual renewal and recovery. No HTTP-01 fallback is permitted in wildcard mode.
