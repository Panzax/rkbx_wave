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
    echo "Error: $1" >&2
    echo "See SETUP_MACOS.md for setup instructions." >&2
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

cleanup() {
    trap - EXIT INT TERM
    [ -n "$KEEPALIVE_PID" ] && kill "$KEEPALIVE_PID" 2>/dev/null || true
    [ -n "$WAVE_PID" ] && kill "$WAVE_PID" 2>/dev/null || true
    # rkbx_link runs as root; kill it with sudo by exact process name.
    sudo pkill -x rkbx_link 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# Cache sudo credentials once so the backgrounded rkbx_link does not need a TTY.
echo "rkbx_link needs administrator access to read Rekordbox memory."
sudo -v

# Keep the sudo timestamp fresh for long sessions.
( while true; do sudo -n true 2>/dev/null || exit; sleep 60; done ) &
KEEPALIVE_PID=$!

# Start rkbx_wave first so the OSC listener (127.0.0.1:4460) is bound.
echo "Starting rkbx_wave..."
"$PY" "$SCRIPT_DIR/rkbx_wave.py" &
WAVE_PID=$!

# Wait until rkbx_wave has actually bound the OSC port before starting rkbx_link,
# so the link doesn't spam "connection refused" while Python/Tk is still loading.
# Port 4460 matches osc_port in default_config.json and osc.destination in the
# rkbx_link bundle config. Bail out early if the GUI dies during startup.
OSC_PORT=4460
for _ in $(seq 1 60); do
    lsof -nP -iUDP:"$OSC_PORT" >/dev/null 2>&1 && break
    kill -0 "$WAVE_PID" 2>/dev/null || break
    sleep 0.5
done

# Start rkbx_link from its bundle dir so it finds ./config and ./data/offsets-macos.
echo "Starting rkbx_link..."
( cd "$LINK_DIR" && exec sudo ./rkbx_link ) &
LINK_PID=$!

# Tear down everything as soon as either process stops. macOS ships Bash 3.2,
# which has no `wait -n`, so poll both PIDs instead.
while kill -0 "$WAVE_PID" 2>/dev/null && kill -0 "$LINK_PID" 2>/dev/null; do
    sleep 1
done
