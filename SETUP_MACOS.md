# rkbx_wave - macOS Setup

Run rkbx_wave with live Rekordbox sync on macOS. A prebuilt `rkbx_link` is
bundled in [dist/rkbx_link/](dist/rkbx_link/), so you do not need Rust.

## Requirements

- Apple Silicon Mac (M-series)
- Rekordbox **7.2.8** (this is the only version the bundled offsets support)
- Python **3.10+** (3.10 is the tested version; the pinned numpy/scipy have no wheels for older versions)

## One-time setup

### 1. Python environment

You need Python 3.10+. Use whichever of the two options below you prefer.

**Option A - conda / miniforge (recommended, handles the Python version for you):**

```bash
conda create -n rkbx_wave python=3.10 -y
conda activate rkbx_wave
pip install -r requirements.txt
```

The launcher auto-detects a conda env named `rkbx_wave`, so you do not need to
set anything else.

**Option B - venv (requires Python 3.10+ already installed):**

```bash
python3 --version            # must be 3.10 or newer
python3 -m venv .venv         # or python3.10 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

The launcher resolves Python in this order: `RKBX_WAVE_PYTHON` (if set) ->
`./.venv` -> a conda env named `rkbx_wave`. It refuses to start on anything
older than 3.10.

### 2. Re-sign Rekordbox

`rkbx_link` reads Rekordbox's memory, which macOS blocks unless Rekordbox is
re-signed with the `get-task-allow` entitlement. This is a one-time step and
persists across reboots.

**Important:** macOS privacy protection blocks `codesign` from modifying app
bundles unless your terminal has Full Disk Access. Before running the script,
go to **System Settings > Privacy & Security > Full Disk Access**, enable your
terminal app (Terminal or iTerm), then fully quit and reopen it. Without this
the script fails at "Re-signing..." with `Operation not permitted`.

Quit Rekordbox first (check Activity Monitor for `rekordbox` and
`rekordboxAgent`), then:

```bash
cd dist/rkbx_link
./resign_rekordbox.sh
```

The first Rekordbox launch afterward may need a right-click > Open to get past
Gatekeeper.

## Running

1. Start Rekordbox and load tracks onto deck 1 and/or deck 2.
2. From the repo root:

```bash
./start.sh
```

Enter your password when prompted (needed so `rkbx_link` can read Rekordbox
memory). The launcher starts the waveform GUI and `rkbx_link` together and
shuts both down when you close either one.

## Troubleshooting

- **No window appears** - Use Cmd-Tab / Mission Control to find the GUI, and
  look for a first-run "macOS Setup" dialog to dismiss.
- **Window opens but no waveforms** - Confirm Rekordbox is 7.2.8 and that
  tracks are loaded on deck 1/2.
- **"rkbx_link cannot be opened" (Gatekeeper)** - Clear the quarantine flag:
  ```bash
  xattr -dr com.apple.quarantine dist/rkbx_link/rkbx_link
  ```
- **"Address already in use" / endless "Connection refused"** - `start.sh` now
  clears leftover processes automatically on each launch, so just run it again.
  If a non-rkbx app is holding the port, the launcher will say so; otherwise you
  can still force a manual cleanup:
  ```bash
  sudo pkill -x rkbx_link
  ```
- **Something went wrong - where are the logs?** - Each run writes to the `logs/`
  folder next to `start.sh`: `launcher.log` (startup/shutdown steps),
  `rkbx_wave.log` (GUI output), and `rkbx_link.log` (Rekordbox/OSC output). They
  are overwritten on every launch, so reproduce the issue, then send these files.
- **Need verbose logs** - Set `app.debug true` and `display.enabled true` in
  [dist/rkbx_link/config](dist/rkbx_link/config).

## Credits

`rkbx_link` is by [grufkork](https://github.com/grufkork/rkbx_link); the
bundled binary is built from a fork with a small macOS deck-handling fix.
