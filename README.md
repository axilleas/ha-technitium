# Dion Home Assistant Add-ons

This repository is a custom Home Assistant OS add-on repository. It currently contains an add-on for running [Technitium DNS Server](https://technitium.com/dns/) under the Home Assistant Supervisor.

The add-on is intended for Home Assistant OS or Home Assistant Supervised installations where add-ons are managed by the Supervisor. It does **not** require manual changes to Home Assistant OS and does **not** require starting Docker containers outside Home Assistant.

## Included add-ons

- **Technitium DNS Server** (`technitium_dns`): DNS service on port 53 and the Technitium web UI on port 5380.

## Add this repository to Home Assistant OS

1. Open Home Assistant.
2. Go to **Settings → Add-ons → Add-on Store**.
3. Open the three-dot menu in the upper right corner.
4. Select **Repositories**.
5. Add this GitHub repository URL:

   ```text
   https://github.com/Dion/ha-technitium
   ```
6. Close the dialog and refresh the Add-on Store if needed.
7. Install **Technitium DNS Server**.

## Ports

| Port | Protocol | Purpose |
| --- | --- | --- |
| 53 | UDP | Standard DNS queries |
| 53 | TCP | DNS queries that require TCP, such as large responses and zone-related traffic |
| 5380 | TCP | Technitium DNS Server web UI |

Click **Open Web UI** on the add-on page to open Technitium inside Home Assistant via Ingress. Like the AdGuard Home add-on, this add-on uses an internal NGINX ingress proxy instead of sending Home Assistant directly to the application port. The direct LAN URL can also be used as a fallback:

```text
http://HOME_ASSISTANT_IP:5380
```

## Important: port 53 conflicts

DNS uses port 53. Only one service can bind to port 53 on the Home Assistant host IP at the same time.

Before starting this add-on, check whether another add-on or host service already provides DNS, for example:

- AdGuard Home add-on
- Pi-hole add-on
- Another DNS resolver or DHCP/DNS service
- Router or network configuration that forwards DNS to Home Assistant

This add-on uses `host_network: true` for the first minimal version. That is the most predictable approach for a DNS server on Home Assistant OS because clients can query the Home Assistant host IP directly on port 53. The trade-off is that port conflicts are immediate and must be resolved before the add-on can start successfully.

## Add-on logging

The add-on includes a `log_level` option. Keep it at `info` for normal use. Temporarily switch it to `debug` or `trace` when diagnosing startup, Web UI, Ingress, or port-binding issues. The wrapper reports startup ownership/readiness and DNS/proxy lifecycle failures. NGINX request and error logs are always disabled to avoid leaking API tokens.

## Persistent data

Technitium data is stored below:

```text
/config/technitium
```

Inside the add-on container, `/config` is provided by the Home Assistant Supervisor through the modern `addon_config` mapping. On the Home Assistant host, this corresponds to the add-on-specific folder under `/addon_configs/{REPO}_technitium_dns`. This keeps Technitium configuration and databases separate from Home Assistant Core's own `/config` directory while still making the files available to Supervisor backups.

## Using Home Assistant OS as the central DNS host

### Advantages

- One always-on device can provide DNS for the home network.
- DNS configuration can be managed from the Technitium web UI.
- Add-on lifecycle, logs, backup, and updates are managed by Home Assistant Supervisor.
- No manually maintained external Docker container is needed.

### Disadvantages and risks

- If Home Assistant OS is down, rebooting, or being updated, DNS for the network may also be unavailable.
- Port 53 conflicts must be avoided.
- Misconfigured DNS can make Home Assistant, integrations, or clients appear offline.
- A router or DHCP server must usually be configured to hand out the Home Assistant IP as DNS server.

For critical networks, consider a secondary DNS resolver or a fallback plan before making Home Assistant the only DNS server.

## Roadmap / future extensions

This version intentionally exposes only classic DNS on port 53 and the HTTP web UI on port 5380. The Home Assistant **Open Web UI** button uses an internal NGINX ingress proxy on add-on port 8099 so the Technitium UI opens inside Home Assistant instead of redirecting the browser to `http://HOME_ASSISTANT_IP:5380`. The proxy injects the Home Assistant Ingress base path and rewrites redirects/cookies so Technitium assets and API calls stay under the Ingress URL. DNS-over-HTTPS (DoH), DNS-over-TLS (DoT), HTTPS for the web UI, and certificate management are possible future extensions, but they are not enabled or enforced by default in this minimal release.


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