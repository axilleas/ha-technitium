# Technitium DNS Server Add-on

This add-on runs Technitium DNS Server on Home Assistant OS through the Home Assistant Supervisor.

The initial version is intentionally minimal:

- DNS on port **53/UDP**
- DNS on port **53/TCP**
- Technitium web UI on port **5380/TCP** and via Home Assistant Ingress through an internal NGINX proxy
- Persistent Technitium data in the add-on configuration directory
- No enforced DNS-over-HTTPS, DNS-over-TLS, or HTTPS setup

## Installation

1. Add the repository to Home Assistant under **Settings → Add-ons → Add-on Store → Repositories**.
2. Open the **Technitium DNS Server** add-on page.
3. Select **Install**.
4. Wait for the image to build and install.

## Start

1. Open the add-on page.
2. Start the add-on.
3. Check the **Log** tab for startup messages.
4. Enable **Start on boot** if it is not already enabled.

## Configuration

| Option | Default | Description |
| --- | --- | --- |
| `log_level` | `info` | Controls the add-on wrapper logs. Use `debug` or `trace` while troubleshooting startup, port binding, NGINX Ingress, or Web UI issues. |

The log level affects the Home Assistant add-on startup wrapper. Technitium application output is unchanged. Only NGINX request and error logs are disabled because request URLs can contain API tokens. Wrapper lifecycle warnings remain available.

## Web UI

Prefer the Home Assistant add-on page button:

1. Open **Settings → Add-ons → Technitium DNS Server**.
2. Click **Open Web UI**.
3. Technitium should open inside Home Assistant via Ingress, using an internal NGINX reverse proxy pattern similar to AdGuard Home. The proxy keeps Technitium assets, API calls, redirects, and cookies under the Home Assistant Ingress path.

The direct LAN URL remains available as a fallback:

```text
http://HOME_ASSISTANT_IP:5380
```

Replace `HOME_ASSISTANT_IP` with the IP address of your Home Assistant OS host.

Technitium may initialize its own default administrator account on first start. Change default credentials immediately in the Technitium web UI if Technitium prompts or auto-logs in with defaults.

## DNS test

From another machine on the same network, test DNS resolution with either `dig`:

```sh
dig @HOME_ASSISTANT_IP example.com
```

or `nslookup`:

```sh
nslookup example.com HOME_ASSISTANT_IP
```

If the test fails, first check whether the add-on is running and whether another service already occupies port 53.

## Logs

Technitium application output and wrapper lifecycle messages appear in the
Home Assistant add-on log view. Startup reports .NET runtime checks and
child-owned TCP/UDP listener readiness. NGINX access and error output are disabled
at every log level because both can contain API tokens in request URLs. Proxy
startup failures are reported as sanitized wrapper warnings.

To inspect logs:

1. Open **Settings → Add-ons**.
2. Select **Technitium DNS Server**.
3. Open the **Log** tab.

## Persistent data and backups

Technitium is started with this data directory inside the add-on container:

```text
/config/technitium
```

The add-on maps `/config` to the Supervisor-managed `addon_config` directory. On the Home Assistant host this is the add-on-specific folder under:

```text
/addon_configs/{REPO}_technitium_dns
```

This is preferred over storing application data in Home Assistant Core's own configuration directory because it keeps add-on state isolated and aligned with current Home Assistant add-on conventions.

Use Home Assistant backups before major changes. A full backup should include the Supervisor-managed add-on configuration directory and the add-on settings. For important DNS deployments, export Technitium configuration from the web UI before upgrades or large configuration changes.

## Updates

This add-on pins official Technitium **15.6.2** by multi-architecture index digest (see Dockerfile), retaining amd64, ARM64, ARMv7 and .NET 10. Updates require a reviewed version/digest change; rebuilding does not silently upgrade the base image. The image also installs NGINX for Home Assistant Ingress proxying, verifies that the required .NET 10 runtime frameworks are present at build time, and the start script checks them again before launching Technitium. To update Technitium, update/rebuild the add-on image through Home Assistant after a new add-on release is published.

Before updating:

1. Create a Home Assistant backup.
2. Optionally export Technitium settings from the web UI.
3. Review the add-on release notes and Technitium release notes.

## Known limitations

- This add-on uses `host_network: true` so DNS clients can reach port 53 directly on the Home Assistant host IP. If another service already uses port 53, the add-on will not start correctly.
- The **Open Web UI** button uses Home Assistant Ingress on internal proxy port 8099. NGINX forwards those requests to Technitium on `127.0.0.1:5380`, injects the Ingress base path into the HTML, and rewrites redirects/cookies back to the Home Assistant Ingress path. If direct access to `http://HOME_ASSISTANT_IP:5380` fails, use the Ingress button first and then check the add-on logs with `log_level` set to `debug`.
- Home Assistant OS becomes part of the DNS path. If Home Assistant OS is offline, clients that rely only on this DNS server may lose DNS resolution.
- Only `amd64`, `aarch64`, and `armv7` are declared. The Docker base image and .NET runtime must be available for the target architecture during build.
- DoH, DoT, DoQ, HTTPS for the web UI, DHCP service, and certificate automation are not configured by this add-on.
- No secrets are hardcoded by the add-on. Configure credentials in Technitium itself after first start.

## Future extensions

Technitium supports encrypted DNS modes such as DNS-over-HTTPS and DNS-over-TLS. Those can be added later together with a clear certificate and port strategy. They are intentionally not enabled in this first minimal Home Assistant add-on version.


## Security and supported architectures

The base image is pinned to Technitium **15.6.2** by a multi-architecture index
digest. Supported targets are `amd64`, `aarch64` and `armv7`. Container runtime
tests were performed on amd64; native ARM and Home Assistant Supervisor/Ingress
deployment still need validation.

Host networking means the Docker `EXPOSE` list is not a firewall. Keep DNS and
management listeners LAN-only, restrict recursion to trusted clients, and prefer
Technitium HTTPS or authenticated HA Ingress for administration. Never expose an
open recursive resolver or the admin UI to the Internet.

## Startup and recovery

Startup requires child-owned DNS TCP/UDP sockets and the native Web UI. Missing
listeners or failed DNS readiness exit nonzero instead of silently continuing.
NGINX is optional: failed starts/crashes retry with exponential backoff capped at
60 seconds without stopping DNS. Request/error logs are disabled in NGINX at all
log levels to avoid leaking query-string API tokens (including on error paths).
Technitium's own application/query logs are not redacted by this wrapper.

DNS health uses real nonrecursive localhost queries over **both UDP and TCP**;
it needs no Internet/upstream resolver. NOERROR, NXDOMAIN and REFUSED are valid
policy responses; SERVFAIL, timeouts and malformed replies fail. This checks DNS
responsiveness, not external recursive resolution or the correctness of zones.
Docker HEALTHCHECK reports health; the wrapper exits after three consecutive
runtime failures, checking every 30 seconds. Enable Home Assistant's **Watchdog**
for stopped-container recovery. There is deliberately no `dns://` watchdog URL:
Supervisor documents only HTTP(S)/TCP URL checks, not DNS protocol probes.
A proxy-only failure must not trigger a whole-container/DNS restart.

## Development checks

```sh
python3 -m unittest discover -s tests -v  # from repository root
bash -n technitium/run.sh technitium/healthcheck.sh
shellcheck technitium/run.sh technitium/healthcheck.sh
docker build -t ha-technitium-hardening-test:1.0.7 technitium
python3 tests/integration.py bridge
```

Integration tests create/remove only uniquely named disposable containers, use
tmpfs data and publish no ports. On hosts unable to create bridge interfaces,
`python3 tests/integration.py none` tests via container-local probes instead.
No running Home Assistant installation is used by these tests.