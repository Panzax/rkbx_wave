# rkbx_wave - macOS Setup

Run rkbx_wave with live Rekordbox sync on macOS. A prebuilt `rkbx_link` is
bundled in [dist/rkbx_link/](dist/rkbx_link/), so you do not need Rust.

## Requirements

- Apple Silicon Mac (M-series)
- Rekordbox **7.2.8** (this is the only version the bundled offsets support)
- Python **3.10+** (3.10 is the tested version; the pinned numpy/scipy have no wheels for older versions)

## One-time setup

### 1. Python environment

First check your Python version:

```bash
python3 --version
```

If it is older than 3.10, install a newer one (e.g. `brew install python@3.10`,
or from [python.org](https://www.python.org/downloads/macos/)). You can then
use `python3.10` explicitly below.

From the repo root, create the venv with a 3.10+ interpreter:

```bash
python3.10 -m venv .venv      # or: python3 -m venv .venv (if python3 is >= 3.10)
source .venv/bin/activate
pip install -r requirements.txt
```

The launcher uses `./.venv` by default and refuses to start if that interpreter
is older than 3.10. To use a different interpreter (e.g. a conda env), set
`RKBX_WAVE_PYTHON=/path/to/python` before running it.

### 2. Re-sign Rekordbox

`rkbx_link` reads Rekordbox's memory, which macOS blocks unless Rekordbox is
re-signed with the `get-task-allow` entitlement. This is a one-time step and
persists across reboots.

Quit Rekordbox first, then:

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
- **Need verbose logs** - Set `app.debug true` and `display.enabled true` in
  [dist/rkbx_link/config](dist/rkbx_link/config).

## Credits

`rkbx_link` is by [grufkork](https://github.com/grufkork/rkbx_link); the
bundled binary is built from a fork with a small macOS deck-handling fix.
