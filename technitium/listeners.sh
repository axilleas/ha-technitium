#!/usr/bin/env bash
# Definitions only: shared by startup and the standalone Docker healthcheck.

read_process() {
  local pid="$1" stat
  local -a fields
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
  { IFS= read -r stat < "/proc/$pid/stat"; } 2>/dev/null || return 1
  # comm (field 2) can contain spaces and ')'; strip through its final ') '.
  read -r -a fields <<< "${stat##*) }"
  [[ ${#fields[@]} -ge 20 && "${fields[0]}" != Z && "${fields[0]}" != X ]] || return 1
  PROCESS_PARENT=${fields[1]}
  PROCESS_START=${fields[19]}
}

process_in_tree() {
  local pid="$1" root="$2"
  while read_process "$pid"; do
    [ "$pid" != "$root" ] || return 0
    [ "$PROCESS_PARENT" != "$pid" ] || return 1
    pid=$PROCESS_PARENT
  done
  return 1
}

listener_owned() {
  local protocol="$1" port="$2" root="$3" flags sockets address owners pid
  read_process "$root" || return 1
  local start="${4:-$PROCESS_START}" found=0 owned
  [[ "$start" =~ ^[0-9]+$ && "$PROCESS_START" == "$start" ]] || return 1
  case "$protocol" in
    tcp) flags=-Hlnpt ;;
    udp) flags=-Hlnpu ;;
    *) return 1 ;;
  esac
  sockets=$(ss "$flags") || return 1
  while read -r _ _ _ address owners; do
    [[ "$address" == *":$port" ]] || continue
    owned=0
    # Parse complete numeric PID tokens, not process names or PID substrings.
    while [[ "$owners" =~ pid=([0-9]+), ]]; do
      pid=${BASH_REMATCH[1]}
      if process_in_tree "$pid" "$root"; then owned=1; fi
      owners=${owners#*pid="$pid",}
    done
    # Fail closed for hidden/unrelated owners, including a different bind
    # address on the same port: its loopback replies must not mask this app.
    [ "$owned" = 1 ] || return 1
    found=1
  done <<< "$sockets"
  [ "$found" = 1 ] || return 1
  read_process "$root" && [ "$PROCESS_START" = "$start" ]
}
