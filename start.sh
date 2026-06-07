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
#   - Python env at ./.venv (or set RKBX_WAVE_PYTHON to another interpreter)
#   - Rekordbox re-signed via dist/rkbx_link/resign_rekordbox.sh
#
# Usage: ./start.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINK_DIR="$SCRIPT_DIR/dist/rkbx_link"
LINK_BIN="$LINK_DIR/rkbx_link"
OFFSETS="$LINK_DIR/data/offsets-macos"

# Python interpreter: default to the project venv, allow override.
PY="${RKBX_WAVE_PYTHON:-$SCRIPT_DIR/.venv/bin/python}"

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
[ -x "$PY" ] || fail "Python interpreter not found at: $PY (create ./.venv or set RKBX_WAVE_PYTHON)"

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
    # rkbx_link runs as root; kill it with sudo by matching its path.
    sudo pkill -f "$LINK_BIN" 2>/dev/null || true
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

# Give the listener a moment to bind before rkbx_link starts sending.
sleep 1

# Start rkbx_link from its bundle dir so it finds ./config and ./data/offsets-macos.
echo "Starting rkbx_link..."
( cd "$LINK_DIR" && exec sudo ./rkbx_link ) &

# Exit (and tear down everything) as soon as either process stops.
wait -n
