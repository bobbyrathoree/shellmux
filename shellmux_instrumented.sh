#!/usr/bin/env bash
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
SCHED="$(dirname "$SELF")/sched.sh"

die() { printf 'shellmux: %s\n' "$*" >&2; exit 1; }

fanout() {
  local rec="$1" td="$2" f pid frame
  local wto="${SHELLMUX_WRITE_TIMEOUT:-0.05}"
  frame="${#rec}"$'\n'"$rec"
  for f in "$td"/sub_*.fifo; do
    [ -e "$f" ] || continue
    [ "$f" = "${INFIFO:-}" ] && continue
    [ -p "$f" ] || continue
    if [ "${SHELLMUX_LEAKY_WRITE:-0}" = "1" ]; then
      printf '%s' "$frame" > "$f" 2>/dev/null &
    else
      pid="${f##*/sub_}"; pid="${pid%.fifo}"
      # INSTRUMENTED: time the write
      local wstart=$(date +%s%3N)
      if ! timeout "$wto" bash -c 'printf "%s" "$2" > "$1"' _ "$f" "$frame" 2>/dev/null; then
        local wend=$(date +%s%3N)
        local wms=$((wend - wstart))
        echo "FANOUT_TIMEOUT: ${wms}ms to wedged $pid" >&2
        ( flock 9
          v=$(cat "$td/drops_$pid" 2>/dev/null)
          printf '%d\n' $(( ${v:-0} + 1 )) > "$td/drops_$pid"
        ) 9>"$td/.drops.lock"
      else
        local wend=$(date +%s%3N)
        local wms=$((wend - wstart))
        if [ "$wms" -gt 10 ]; then
          echo "FANOUT_SLOW: ${wms}ms to $pid" >&2
        fi
      fi
    fi
  done
}

_handle() {
  local dir="$1"
  local ctl; IFS= read -r ctl || exit 0
  local verb="${ctl%% *}" rest="${ctl#* }"
  case "$verb" in
    SUB)
      local topic="$rest" td
      [ -n "$topic" ] && [ "$topic" != "SUB" ] || exit 0
      td="$dir/topics/$topic"; mkdir -p "$td"
      INFIFO="$td/sub_$$.fifo"
      mkfifo "$INFIFO" 2>/dev/null || exit 1
      [ "${SHELLMUX_NO_TRAP:-0}" = "1" ] || trap 'rm -f "$INFIFO"' EXIT
      local pid="$$" wto="${SHELLMUX_WRITE_TIMEOUT:-0.05}"
      
      # INSTRUMENTED DRAINER
      ( exec 9>"$td/.drops.lock"
        local iter=0
        local write_timeouts=0
        while IFS= read -r len; do
          case "$len" in *[!0-9]*|'') continue ;; esac
          IFS= read -r -N "$len" -t 0.5 payload || continue
          [ "${#payload}" -eq "$len" ] || continue
          
          # TIME THE SOCKET WRITE
          local wstart=$(date +%s%3N)
          if ! timeout "$wto" bash -c 'printf "%s\n" "$1"' _ "$payload" 2>/dev/null; then
            local wend=$(date +%s%3N)
            local wms=$((wend - wstart))
            write_timeouts=$((write_timeouts + 1))
            echo "DRAINER_WRITE_TIMEOUT: iter=$iter wms=${wms}ms (payload=${#payload})" >&2
            flock 9
            v=$(cat "$td/drops_$pid" 2>/dev/null)
            printf '%d\n' $(( ${v:-0} + 1 )) > "$td/drops_$pid"
            flock -u 9
          else
            local wend=$(date +%s%3N)
            local wms=$((wend - wstart))
            if [ "$wms" -gt 5 ]; then
              echo "DRAINER_SLOW_WRITE: iter=$iter wms=${wms}ms" >&2
            fi
          fi
          iter=$((iter + 1))
        done < "$INFIFO"
        echo "DRAINER_FINAL: iter=$iter write_timeouts=$write_timeouts" >&2
      ) &
      
      exec 3>"$INFIFO"
      while IFS= read -r _; do :; done
      ;;
    PUB)
      local topic="" at="" delay="" tok
      set -- $rest
      topic="${1:-}"; shift || true
      while [ $# -gt 0 ]; do
        case "$1" in
          --at)    at="$2"; shift 2 ;;
          --delay) delay="$2"; shift 2 ;;
          *) shift ;;
        esac
      done
      [ -n "$topic" ] || exit 0
      local td="$dir/topics/$topic"; mkdir -p "$td"
      while IFS= read -r rec; do
        fanout "$rec" "$td"
      done
      exit 0
      ;;
    *)
      exit 0 ;;
  esac
}

serve() {
  local dir="$1"; shift
  local unix_path="" tcp_port=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --unix) unix_path="$2"; shift 2 ;;
      --tcp)  tcp_port="$2";  shift 2 ;;
      *) die "serve: unknown arg $1" ;;
    esac
  done
  [ -n "$unix_path" ] || [ -n "$tcp_port" ] || die "serve: need --unix and/or --tcp"

  mkdir -p "$dir/topics" "$dir/deferred" "$dir/outbox"
  [ -p "$dir/wake.fifo" ] || mkfifo "$dir/wake.fifo"

  env SCHED_IDLE_POLL_MS="${SCHED_IDLE_POLL_MS:-1000}" bash "$SCHED" "$dir" &
  local sched_pid=$!

  local pids=("$sched_pid")
  export SHELLMUX_NO_TRAP="${SHELLMUX_NO_TRAP:-0}"
  export SHELLMUX_LEAKY_WRITE="${SHELLMUX_LEAKY_WRITE:-0}"
  export SHELLMUX_WRITE_TIMEOUT="${SHELLMUX_WRITE_TIMEOUT:-0.05}"
  local exec_cmd="bash $SELF _handle $dir"

  if [ -n "$unix_path" ]; then
    rm -f "$unix_path"
    socat "UNIX-LISTEN:$unix_path,fork" "EXEC:$exec_cmd" &
    pids+=($!)
  fi
  if [ -n "$tcp_port" ]; then
    socat "TCP-LISTEN:$tcp_port,reuseaddr,fork" "EXEC:$exec_cmd" &
    pids+=($!)
  fi

  shutdown() { local p; for p in "${pids[@]}"; do pkill -P "$p" 2>/dev/null; kill "$p" 2>/dev/null; done; exit 0; }
  trap shutdown TERM INT
  wait
}

_endpoint() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --unix) printf 'UNIX-CONNECT:%s' "$2"; return ;;
      --tcp)  printf 'TCP-CONNECT:127.0.0.1:%s' "$2"; return ;;
    esac
    shift
  done
  die "need --unix <path> or --tcp <port>"
}

sub() {
  local dir="$1" topic="$2"; shift 2
  local ep; ep="$(_endpoint "$@")" || exit 1
  local cf; cf="$(mktemp -u)"; mkfifo "$cf"
  socat "$ep" - <"$cf" &
  local scpid=$!
  exec 4>"$cf"
  printf 'SUB %s\n' "$topic" >&4
  trap 'exec 4>&-; kill "$scpid" 2>/dev/null; rm -f "$cf"; exit 0' TERM INT
  wait "$scpid"
  exec 4>&-; rm -f "$cf"
}

pub() {
  local dir="$1" topic="$2"; shift 2
  local opts="" ep_args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --at|--delay) opts="$opts $1 $2"; shift 2 ;;
      --unix|--tcp) ep_args+=("$1" "$2"); shift 2 ;;
      *) shift ;;
    esac
  done
  local ep; ep="$(_endpoint "${ep_args[@]}")" || exit 1
  local linger="${SHELLMUX_PUB_LINGER:-1}"
  { printf 'PUB %s%s\n' "$topic" "$opts"; cat; sleep "$linger"; } | socat - "$ep"
}

cmd="${1:-}"; shift || true
case "$cmd" in
  serve)   serve "$@" ;;
  sub)     sub "$@" ;;
  pub)     pub "$@" ;;
  _handle) _handle "$@" ;;
  *) die "usage: shellmux {serve|sub|pub} ... (got '${cmd:-}')" ;;
esac
