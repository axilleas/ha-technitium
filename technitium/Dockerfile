FROM docker.io/technitium/dns-server:15.6.2@sha256:eb48ac5c135f4ab936b536f74f853d53e15ab39ef37fdbc9598a089b90d9f245

ARG BUILD_VERSION=1.0.6
ARG BUILD_ARCH=amd64

LABEL \
  io.hass.version="${BUILD_VERSION}" \
  io.hass.type="addon" \
  io.hass.arch="${BUILD_ARCH}" \
  org.opencontainers.image.title="Technitium DNS Server Home Assistant Add-on" \
  org.opencontainers.image.description="Technitium DNS Server packaged as a Home Assistant OS add-on" \
  org.opencontainers.image.source="https://github.com/axilleas/ha-technitium"

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    dnsutils \
    iproute2 \
    nginx \
    procps \
  && /usr/bin/dotnet --list-runtimes | grep -E "^Microsoft\.NETCore\.App 10\." \
  && /usr/bin/dotnet --list-runtimes | grep -E "^Microsoft\.AspNetCore\.App 10\." \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

COPY run.sh healthcheck.sh /
HEALTHCHECK --interval=30s --timeout=6s --start-period=90s --retries=3 CMD ["/healthcheck.sh"]
RUN chmod 0755 /run.sh /healthcheck.sh

EXPOSE 53/tcp 53/udp 5380/tcp 8099/tcp
ENTRYPOINT ["/run.sh"]
