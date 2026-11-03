#!/usr/bin/env bash
set -e

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
  local port="$1"
  local name="$2"
  local attempts="${3:-30}"

  if ! command -v ss >/dev/null 2>&1; then
    log warning "Skipping ${name} listener check because 'ss' is not installed"
    return 0
  fi

  for attempt in $(seq 1 "${attempts}"); do
    if ss -lntup | grep -Eq ":${port}[[:space:]]"; then
      log info "${name} is listening on TCP port ${port}"
      return 0
    fi

    if [ -n "${TECHNITIUM_PID:-}" ] && ! kill -0 "${TECHNITIUM_PID}" 2>/dev/null; then
      log error "Technitium process exited before ${name} started listening"
      wait "${TECHNITIUM_PID}"
      exit $?
    fi

    if [ -n "${NGINX_PID:-}" ] && ! kill -0 "${NGINX_PID}" 2>/dev/null; then
      log error "NGINX ingress proxy exited before ${name} started listening"
      wait "${NGINX_PID}"
      exit $?
    fi

    log debug "Waiting for ${name} on TCP port ${port} (${attempt}/${attempts})"
    sleep 1
  done

  log warning "${name} did not start listening on TCP port ${port} within ${attempts} seconds"
  log warning "Current listening sockets:"
  log_listeners
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
  require_command nginx
  write_nginx_config
  run_debug_command "Generated NGINX ingress proxy configuration" cat "${NGINX_CONFIG}"

  log info "Starting NGINX ingress proxy on TCP port ${INGRESS_PROXY_PORT}; forwarding to Technitium on 127.0.0.1:${TECHNITIUM_WEB_PORT}"
  nginx -c "${NGINX_CONFIG}" &
  NGINX_PID=$!
  log info "NGINX ingress proxy started with PID ${NGINX_PID}"
}

shutdown() {
  log info "Stopping Technitium DNS Server add-on"
  if [ -n "${NGINX_PID:-}" ] && kill -0 "${NGINX_PID}" 2>/dev/null; then
    kill -TERM "${NGINX_PID}"
    wait "${NGINX_PID}" || true
  fi
  if [ -n "${TECHNITIUM_PID:-}" ] && kill -0 "${TECHNITIUM_PID}" 2>/dev/null; then
    kill -TERM "${TECHNITIUM_PID}"
    wait "${TECHNITIUM_PID}" || true
  fi
}

trap shutdown TERM INT

mkdir -p "${TECHNITIUM_CONFIG_DIR}"

log info "Starting Technitium DNS Server add-on"
log info "Configured wrapper log level: ${LOG_LEVEL}"
log info "Persistent data directory: ${TECHNITIUM_CONFIG_DIR}"
log info "Technitium application: ${TECHNITIUM_APP}"
log info "Technitium native web UI port: ${TECHNITIUM_WEB_PORT}"
log info "Home Assistant ingress proxy port: ${INGRESS_PROXY_PORT}"
log info "Container architecture: $(uname -m)"

require_file "${TECHNITIUM_APP}"
require_file "${TECHNITIUM_RUNTIME_CONFIG}"
require_dotnet_runtime

run_debug_command "Technitium runtime configuration" cat "${TECHNITIUM_RUNTIME_CONFIG}"
run_debug_command "Technitium application directory" ls -la /opt/technitium/dns
run_debug_command "Persistent data directory details" ls -la "${TECHNITIUM_CONFIG_DIR}"
run_debug_command "Listening sockets before Technitium start" log_listeners

log info "Launching Technitium DNS Server"
/usr/bin/dotnet "${TECHNITIUM_APP}" "${TECHNITIUM_CONFIG_DIR}" &
TECHNITIUM_PID=$!
log info "Technitium process started with PID ${TECHNITIUM_PID}"

wait_for_port "${TECHNITIUM_WEB_PORT}" "Technitium native web UI" 60
start_nginx
wait_for_port "${INGRESS_PROXY_PORT}" "Home Assistant ingress proxy" 30
wait_for_port 53 "Technitium DNS TCP service" 30

if [ "${LOG_LEVEL_NUMBER}" -le 1 ]; then
  log debug "Listening sockets after startup"
  log_listeners
fi

log info "Technitium DNS Server is running; Web UI is available through Home Assistant Ingress on add-on port ${INGRESS_PROXY_PORT}"

while true; do
  if ! kill -0 "${TECHNITIUM_PID}" 2>/dev/null; then
    log error "Technitium process stopped unexpectedly"
    wait "${TECHNITIUM_PID}"
    exit $?
  fi

  if ! kill -0 "${NGINX_PID}" 2>/dev/null; then
    log error "NGINX ingress proxy stopped unexpectedly"
    wait "${NGINX_PID}"
    exit $?
  fi

  sleep 5
done
