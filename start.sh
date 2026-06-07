#!/usr/bin/env bash
#
# rkbx_wave launcher: starts the rkbx_wave GUI and the bundled rkbx_link
# together, in the right order, and tears both down on exit.
#
# rkbx_link reads memory from Rekordbox and therefore needs root, so this
# script caches sudo credentials up front. rkbx_wave listens for OSC on
# 127.0.0.1:4460, so it is started first to avoid "connection refused" spam
# from rkbx_link before the listener is bound.
#
# Requirements (one-time, see SETUP_MACOS.md):
#   - A Python 3.10+ environment: either ./.venv, a conda env named
#     "rkbx_wave", or one named via RKBX_WAVE_PYTHON
#   - Rekordbox re-signed via dist/rkbx_link/resign_rekordbox.sh
#
# Usage: ./start.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINK_DIR="$SCRIPT_DIR/dist/rkbx_link"
LINK_BIN="$LINK_DIR/rkbx_link"
OFFSETS="$LINK_DIR/data/offsets-macos"

# UDP ports: rkbx_wave listens on OSC_PORT; rkbx_link opens a source socket on
# SRC_PORT. Both must be free before launch (matches the bundle config).
OSC_PORT=4460
SRC_PORT=4450

# Logs: one file per run (overwritten each launch) so "reproduce, then send me
# logs/" yields the latest session. Child stdout/stderr is tee'd here too.
LOG_DIR="$SCRIPT_DIR/logs"
LAUNCHER_LOG="$LOG_DIR/launcher.log"
WAVE_LOG="$LOG_DIR/rkbx_wave.log"
LINK_LOG="$LOG_DIR/rkbx_link.log"
mkdir -p "$LOG_DIR"
: > "$LAUNCHER_LOG"

# Timestamped logging to both the console and the launcher log.
log() {
    local msg
    msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg"
    echo "$msg" >> "$LAUNCHER_LOG"
}

# Resolve the Python interpreter (first match wins):
#   1. RKBX_WAVE_PYTHON override
#   2. project venv at ./.venv
#   3. a conda env named "rkbx_wave" in a common install location
resolve_python() {
    if [ -n "${RKBX_WAVE_PYTHON:-}" ]; then
        echo "$RKBX_WAVE_PYTHON"; return
    fi
    if [ -x "$SCRIPT_DIR/.venv/bin/python" ]; then
        echo "$SCRIPT_DIR/.venv/bin/python"; return
    fi
    local base
    for base in "$HOME/miniforge3" "$HOME/mambaforge" "$HOME/miniconda3" "$HOME/anaconda3"; do
        if [ -x "$base/envs/rkbx_wave/bin/python" ]; then
            echo "$base/envs/rkbx_wave/bin/python"; return
        fi
    done
    # No interpreter found; return the venv path for a helpful error message.
    echo "$SCRIPT_DIR/.venv/bin/python"
}
PY="$(resolve_python)"

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
fail() {
    log "ERROR: $1"
    log "See SETUP_MACOS.md for setup instructions. Logs are in: $LOG_DIR"
    exit 1
}

[ -x "$LINK_BIN" ] || fail "rkbx_link binary not found or not executable at: $LINK_BIN"
[ -f "$OFFSETS" ] || fail "Rekordbox offsets not found at: $OFFSETS"
[ -x "$PY" ] || fail "No Python found. Create ./.venv, a conda env named 'rkbx_wave', or set RKBX_WAVE_PYTHON. (tried: $PY)"

# Require Python 3.10+ (pinned numpy/scipy and Pillow 12 have no older wheels).
if ! "$PY" -c 'import sys; sys.exit(0 if sys.version_info[:2] >= (3, 10) else 1)' 2>/dev/null; then
    PY_VER="$("$PY" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || echo "unknown")"
    fail "Python 3.10+ required, but $PY is $PY_VER. Recreate the venv with python3.10 (see SETUP_MACOS.md)."
fi

# ---------------------------------------------------------------------------
# Process lifecycle
# ---------------------------------------------------------------------------
WAVE_PID=""
KEEPALIVE_PID=""

# Return 0 while either UDP port is still held by some process.
ports_in_use() {
    lsof -nP -iUDP:"$OSC_PORT" -iUDP:"$SRC_PORT" >/dev/null 2>&1
}

# Stop any rkbx_wave/rkbx_link instances and wait for their ports to free up.
# rkbx_link runs as root, so it needs sudo; rkbx_wave runs as the user. Escalate
# to SIGKILL if a graceful stop does not release the ports. The [r] bracket keeps
# pkill from matching unrelated text and never matches this launcher (bash start.sh).
kill_all() {
    sudo pkill -x rkbx_link 2>/dev/null || true
    pkill -f "[r]kbx_wave.py" 2>/dev/null || true
    local i
    for i in $(seq 1 10); do
        ports_in_use || return 0
        sleep 0.5
    done
    sudo pkill -9 -x rkbx_link 2>/dev/null || true
    pkill -9 -f "[r]kbx_wave.py" 2>/dev/null || true
    sleep 0.5
}

cleanup() {
    trap - EXIT INT TERM
    log "Shutting down; stopping rkbx_wave and rkbx_link..."
    [ -n "$KEEPALIVE_PID" ] && kill "$KEEPALIVE_PID" 2>/dev/null || true
    kill_all
    log "Stopped. Logs saved in: $LOG_DIR"
}
trap cleanup EXIT INT TERM

log "Launcher starting. Logs: $LOG_DIR"

# Cache sudo credentials once so the backgrounded rkbx_link does not need a TTY.
echo "rkbx_link needs administrator access to read Rekordbox memory."
sudo -v

# Keep the sudo timestamp fresh for long sessions.
( while true; do sudo -n true 2>/dev/null || exit; sleep 60; done ) &
KEEPALIVE_PID=$!

# Clear any leftovers from a previous run so the ports are free. This makes
# repeated start/stop work without manual `pkill`/`lsof` cleanup.
if ports_in_use; then
    log "Found leftover rkbx_wave/rkbx_link from a previous run; cleaning up..."
    kill_all
    ports_in_use && fail "Ports $OSC_PORT/$SRC_PORT are still in use by another process. Close it and retry."
fi

# Start rkbx_wave first so the OSC listener (127.0.0.1:4460) is bound.
# tee mirrors output to both the console and the per-process log for debugging.
log "Starting rkbx_wave..."
: > "$WAVE_LOG"
"$PY" "$SCRIPT_DIR/rkbx_wave.py" 2>&1 | tee -a "$WAVE_LOG" &
WAVE_PID=$!

# Wait until rkbx_wave has actually bound the OSC port before starting rkbx_link,
# so the link doesn't spam "connection refused" while Python/Tk is still loading.
# OSC_PORT matches osc_port in default_config.json and osc.destination in the
# rkbx_link bundle config. Bail out early if the GUI dies during startup.
for _ in $(seq 1 60); do
    lsof -nP -iUDP:"$OSC_PORT" >/dev/null 2>&1 && break
    kill -0 "$WAVE_PID" 2>/dev/null || break
    sleep 0.5
done

# Start rkbx_link from its bundle dir so it finds ./config and ./data/offsets-macos.
log "Starting rkbx_link..."
: > "$LINK_LOG"
( cd "$LINK_DIR" && exec sudo ./rkbx_link ) 2>&1 | tee -a "$LINK_LOG" &
LINK_PID=$!

# Tear down everything as soon as either process stops. macOS ships Bash 3.2,
# which has no `wait -n`, so poll both PIDs instead.
while kill -0 "$WAVE_PID" 2>/dev/null && kill -0 "$LINK_PID" 2>/dev/null; do
    sleep 1
done
