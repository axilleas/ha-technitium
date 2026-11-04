#!/usr/bin/env bash
set -e
# shellcheck source=technitium/listeners.sh
source "$(dirname "${BASH_SOURCE[0]}")/listeners.sh"
TECHNITIUM_IDENTITY_FILE="${TECHNITIUM_IDENTITY_FILE:-/run/technitium.identity}"
export TECHNITIUM_IDENTITY_FILE

TECHNITIUM_CONFIG_DIR="/config/technitium"
TECHNITIUM_APP="/opt/technitium/dns/DnsServerApp.dll"
TECHNITIUM_RUNTIME_CONFIG="/opt/technitium/dns/DnsServerApp.runtimeconfig.json"
OPTIONS_FILE="/data/options.json"
REQUIRED_DOTNET_MAJOR="10"
TECHNITIUM_WEB_PORT="5380"
INGRESS_PROXY_PORT="8099"
NGINX_CONFIG="/tmp/technitium-ingress-nginx.conf"

read_option() {
  local key="$1"
  local default_value="$2"

  if [ -f "${OPTIONS_FILE}" ]; then
    local value
    value=$(sed -nE "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"([^\"]*)\".*/\1/p" "${OPTIONS_FILE}" | tail -n 1)
    if [ -n "${value}" ]; then
      printf '%s' "${value}"
      return 0
    fi
  fi

  printf '%s' "${default_value}"
}

LOG_LEVEL=$(read_option "log_level" "info")

level_number() {
  case "$1" in
    trace) echo 0 ;;
    debug) echo 1 ;;
    info) echo 2 ;;
    warning) echo 3 ;;
    error) echo 4 ;;
    *) echo 2 ;;
  esac
}

LOG_LEVEL_NUMBER=$(level_number "${LOG_LEVEL}")

log() {
  local level="$1"
  shift
  if [ "$(level_number "${level}")" -ge "${LOG_LEVEL_NUMBER}" ]; then
    printf '[%s] [%s] %s\n' "$(date -Iseconds)" "${level^^}" "$*"
  fi
}

run_debug_command() {
  local description="$1"
  shift

  log debug "${description}"
  if [ "${LOG_LEVEL_NUMBER}" -le 1 ]; then
    "$@" 2>&1 | sed 's/^/[debug]   /' || true
  fi
}

require_file() {
  local path="$1"
  if [ ! -f "${path}" ]; then
    log error "Required file is missing: ${path}"
    exit 1
  fi
}

require_command() {
  local command_name="$1"
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    log error "Required command is missing: ${command_name}"
    exit 1
  fi
}

require_dotnet_runtime() {
  log info "Checking installed .NET runtimes"
  /usr/bin/dotnet --list-runtimes 2>&1 | sed 's/^/[dotnet] /'

  if ! /usr/bin/dotnet --list-runtimes | grep -Eq "^Microsoft\.NETCore\.App ${REQUIRED_DOTNET_MAJOR}\."; then
    log error "Microsoft.NETCore.App ${REQUIRED_DOTNET_MAJOR}.x is not installed in the add-on image."
    exit 1
  fi

  if ! /usr/bin/dotnet --list-runtimes | grep -Eq "^Microsoft\.AspNetCore\.App ${REQUIRED_DOTNET_MAJOR}\."; then
    log error "Microsoft.AspNetCore.App ${REQUIRED_DOTNET_MAJOR}.x is not installed in the add-on image."
    exit 1
  fi

  log info "Required .NET ${REQUIRED_DOTNET_MAJOR}.x runtimes are installed"
}

log_listeners() {
  if command -v ss >/dev/null 2>&1; then
    ss -lntup 2>&1 | sed 's/^/[listeners] /' || true
  else
    log warning "Cannot list listening sockets because 'ss' is not installed"
  fi
}

wait_for_port() {
  local protocol="$1" port="$2" name="$3" pid="$4" attempts="${5:-30}" attempt
  for ((attempt=1; attempt<=attempts; attempt++)); do
    if ! kill -0 "$pid" 2>/dev/null; then
      log error "${name} process exited during startup"
      return 1
    fi
    if listener_owned "$protocol" "$port" "$pid"; then
      log info "${name} owns ${protocol} port ${port}"
      return 0
    fi
    sleep 1
  done
  log error "${name} did not bind ${protocol} port ${port} within ${attempts} seconds"
  return 1
}

write_nginx_config() {
  cat >"${NGINX_CONFIG}" <<NGINX
worker_processes 1;
daemon off;
pid /tmp/nginx.pid;
# Error logs can contain API tokens in request URIs too.
error_log /dev/null crit;

events {
    worker_connections 1024;
}

http {
    access_log off;
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    sendfile on;

    map \$http_upgrade \$connection_upgrade {
        default upgrade;
        '' close;
    }

    upstream technitium_backend {
        server 127.0.0.1:${TECHNITIUM_WEB_PORT};
    }

    server {
        listen 0.0.0.0:${INGRESS_PROXY_PORT} default_server;

        allow 172.30.32.2;
        deny all;

        location / {
            proxy_http_version 1.1;
            proxy_pass http://technitium_backend;
            proxy_set_header Accept-Encoding "";
            proxy_set_header Host \$http_host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Host \$http_host;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_set_header X-Forwarded-Prefix \$http_x_ingress_path;
            proxy_set_header X-Ingress-Path \$http_x_ingress_path;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection \$connection_upgrade;
            proxy_read_timeout 86400s;
            proxy_send_timeout 86400s;
            proxy_redirect / \$http_x_ingress_path/;
            proxy_cookie_path / \$http_x_ingress_path/;

            sub_filter_once off;
            sub_filter_types text/html application/javascript text/javascript;
            sub_filter '<head>' '<head><base href="\$http_x_ingress_path/">';
            sub_filter 'window.location = "/";' 'window.location = window.location.pathname;';
        }
    }
}
NGINX
}

start_nginx() {
  write_nginx_config || return 1
  nginx -t -c "${NGINX_CONFIG}" >/dev/null 2>&1 || return 1
  nginx -c "${NGINX_CONFIG}" >/dev/null 2>&1 &
  NGINX_PID=$!
  log info "Starting NGINX ingress proxy (PID ${NGINX_PID})"
}

maintain_nginx() {
  if [ -n "${NGINX_PID:-}" ]; then
    if kill -0 "$NGINX_PID" 2>/dev/null; then
      if (( SECONDS - NGINX_STARTED_AT >= 60 )) && listener_owned tcp "$INGRESS_PROXY_PORT" "$NGINX_PID"; then
        NGINX_BACKOFF=1
      fi
      return 0
    fi
    wait "$NGINX_PID" || true
    NGINX_PID=''
    log warning "Ingress proxy exited; DNS remains running"
  fi
  if (( SECONDS < NGINX_RETRY_AT )); then
    return 0
  fi
  if ! start_nginx; then
    log warning "Ingress proxy could not start; DNS remains running"
  fi
  NGINX_STARTED_AT=$SECONDS
  NGINX_RETRY_AT=$((SECONDS + NGINX_BACKOFF))
  NGINX_BACKOFF=$((NGINX_BACKOFF < 30 ? NGINX_BACKOFF * 2 : 60))
}

shutdown() {
  trap '' TERM INT
  [ -z "${TECHNITIUM_IDENTITY_FILE:-}" ] || rm -f "$TECHNITIUM_IDENTITY_FILE"
  log info "Stopping Technitium DNS Server add-on"
  local pid deadline=$((SECONDS + ${SHUTDOWN_TIMEOUT:-8}))
  for pid in "${NGINX_PID:-}" "${TECHNITIUM_PID:-}" "${SLEEP_PID:-}"; do
    [ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null || true
  done
  for pid in "${NGINX_PID:-}" "${TECHNITIUM_PID:-}" "${SLEEP_PID:-}"; do
    [ -n "$pid" ] || continue
    while kill -0 "$pid" 2>/dev/null && (( SECONDS < deadline )); do
      sleep 0.2
    done
    if kill -0 "$pid" 2>/dev/null; then
      kill -KILL "$pid" 2>/dev/null || true
    fi
    wait "$pid" 2>/dev/null || true
  done
}

main() {
  trap shutdown EXIT
  trap 'exit 0' TERM INT
  rm -f "$TECHNITIUM_IDENTITY_FILE"
  mkdir -p "${TECHNITIUM_CONFIG_DIR}"
  log info "Starting Technitium DNS Server; wrapper log level ${LOG_LEVEL}"
  require_file "${TECHNITIUM_APP}"
  require_file "${TECHNITIUM_RUNTIME_CONFIG}"
  require_command ss
  require_command dig
  require_dotnet_runtime
  /usr/bin/dotnet "${TECHNITIUM_APP}" "${TECHNITIUM_CONFIG_DIR}" &
  TECHNITIUM_PID=$!
  read_process "$TECHNITIUM_PID" || return 1
  # PID alone can be reused; bind independent probes to this launch's start time.
  (umask 077; printf '%s %s\n' "$TECHNITIUM_PID" "$PROCESS_START" > "$TECHNITIUM_IDENTITY_FILE") || return 1
  wait_for_port tcp 53 "Technitium DNS" "$TECHNITIUM_PID" 60 || return 1
  wait_for_port udp 53 "Technitium DNS" "$TECHNITIUM_PID" 30 || return 1
  wait_for_port tcp "$TECHNITIUM_WEB_PORT" "Technitium Web UI" "$TECHNITIUM_PID" 60 || return 1
  /healthcheck.sh || { log error "DNS startup health check failed"; return 1; }
  NGINX_PID=''
  NGINX_RETRY_AT=0
  NGINX_BACKOFF=1
  NGINX_STARTED_AT=0
  local failed_checks=0 next_check=$SECONDS
  log info "DNS is ready; starting optional Ingress proxy"
  while true; do
    if ! kill -0 "$TECHNITIUM_PID" 2>/dev/null; then
      log error "Technitium process exited unexpectedly"
      return 1
    fi
    maintain_nginx
    if (( SECONDS >= next_check )); then
      if /healthcheck.sh; then
        failed_checks=0
      else
        failed_checks=$((failed_checks + 1))
        log warning "DNS health check failed (${failed_checks}/3)"
        if (( failed_checks >= 3 )); then
          log error "DNS is unhealthy; exiting for Supervisor recovery"
          return 1
        fi
      fi
      next_check=$((SECONDS + 30))
    fi
    sleep 1 &
    SLEEP_PID=$!
    wait "$SLEEP_PID" || true
    SLEEP_PID=''
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
