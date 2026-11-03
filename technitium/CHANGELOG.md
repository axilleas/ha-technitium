# Changelog

## 1.0.7

- Pin official Technitium 15.6.2 to OCI multi-architecture index
  `sha256:eb48ac5c135f4ab936b536f74f853d53e15ab39ef37fdbc9598a089b90d9f245`.
  Docker Registry v2 and Docker Hub tag metadata verified on 2026-11-03:
  linux/amd64, linux/arm64, linux/arm/v7. Build checks retain .NET 10.
- Disable NGINX access/error output, including request URLs containing API tokens.
  Log only proxy lifecycle warnings; Technitium application logs are unchanged.
- Retry optional Ingress proxy failures with bounded exponential backoff without
  taking DNS down. Fail DNS startup on missing child-owned TCP/UDP listeners.
- Probe actual DNS responses over UDP and TCP during startup and runtime; add a
  Docker HEALTHCHECK. Exit after three consecutive runtime health failures so
  Supervisor Watchdog can recover the stopped add-on when enabled.
- Reap children on normal exit, startup failure and signals; bound shutdown,
  and use Docker init to reap orphaned descendants.
- Correct repository URLs to axilleas; bump add-on version to 1.0.7.
- Add isolated regression/integration tests and CI.

**Migration:** A different repository means a separate Supervisor add-on and
configuration directory. Back up/export the old add-on, stop it, install this
fork and explicitly import Technitium settings. No automatic migration occurs.
See README for rollback and verification steps.
