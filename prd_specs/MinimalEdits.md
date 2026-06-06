Here’s a structured proposal that pulls together how `rkbx_wave` works, what it depends on, and a concrete plan to get it running on macOS.

***

## 1. Purpose and High‑Level Behavior

`rkbx_wave` is a real‑time external waveform display for Rekordbox DJ that:

- Connects to Rekordbox via `rkbx_link` and listens to deck time/BPM/track events over OSC.
- Resolves the Rekordbox ANLZ folder for the current track, parses the full‑resolution 3‑band waveform and beat grid using `pyrekordbox`.
- Renders a zoomable, prerendered, cached waveform image (16–256+ seconds) that can scroll smoothly with the playhead, independent of Rekordbox’s UI zoom limit.[^1]

This effectively replicates (and extends) XDJ‑style long‑window waveforms on a laptop.

***

## 2. Architecture Overview

### 2.1 Top‑Level Components

The codebase is organized around three main layers:

1. **Frontend GUI (`rkbx_wave.py`)**
    - Tkinter app; creates windows, canvas widgets, tuning controls, and per‑deck waveform views.
    - Starts/stops a background `rkbx_link` process (Windows `.exe`) and instantiates a `RekordboxLinkListener` to receive OSC events.
    - Owns `DeckController` instances, one per deck, which combine Rekordbox events, analysis data, and rendering.[^2][^1]
2. **Rekordbox link integration (`rb_waveform_core.rkbx_link_listener`)**
    - Python OSC server that listens for messages from `rkbx_link` on `127.0.0.1:4460`.
    - Tracks per‑deck state (time, ANLZ path, original/current BPM) and emits immutable `DeckEvent` objects to the GUI layer.[^3][^4]
3. **Waveform analysis and rendering (`rb_waveform_core.*`)**
    - `ANLZ.py` \& `analysis.py`: parse Rekordbox ANLZ files via `pyrekordbox` and convert PWV waveform tags to normalized numpy arrays.
    - `deck_controller.py`: orchestrates ANLZ loading, beat grid extraction, prerender caching, and per‑frame rendering calls.
    - `playhead.py` \& `render.py`: compute the visible time window and draw the waveform + beat grid into a Pillow image.[^5][^6][^7][^8][^9]

***

## 3. Detailed Data Flow

### 3.1 From Rekordbox to `rkbx_wave`

1. **Rekordbox ↔ `rkbx_link`**
    - `rkbx_link` (external project) hooks into Rekordbox (7.2.2 in current README) and exports:
        - Deck time (seconds)
        - Current/original BPM
        - ANLZ folder path for the currently loaded track
    - It publishes these over OSC to localhost and supports Ableton Link for synchronization.[^4][^10]
2. **`rkbx_link` → `RekordboxLinkListener`**
    - `rkbx_wave` starts `rkbx_link.exe` and then opens an OSC UDP server on `127.0.0.1:4460`.
    - Handlers are registered for addresses like `/time/{deck}`, `/bpm/{deck}/current`, `/bpm/{deck}/original`, `/track/{deck}/anlz_path`.
    - Each incoming message updates a per‑deck state object; snapshots are turned into `DeckEvent` objects and forwarded to the GUI via a callback queue.[^3]
3. **`DeckEvent` → `DeckController`**
    - On `anlz_path` change: `DeckController.load_anlz(folder)` is invoked.
    - On time updates: `DeckController.update_time(time_seconds)` stores the live playhead.
    - On BPM updates: `DeckController.update_live_bpm(bpm)` recomputes a tempo scale factor and, if needed, invalidates cached prerenders.[^7]

***

### 3.2 ANLZ Parsing and Waveform Model

When a new ANLZ folder is detected:

1. **ANLZ file selection**
    - `analyze_anlz_folder(folder)` chooses the correct ANLZ file (.2EX, .EXT, .DAT) and reads it using `pyrekordbox`.
    - It extracts:
        - `PWV7` tag → high‑resolution 3‑band waveform as an $N \times 3$ uint8 array
        - `PPTH` tag → path to the corresponding audio file
        - Duration (from frame count at 150 fps).[^6][^5]
2. **Beat grid extraction**
    - `extract_beat_grid(folder)` reads the `PQTZ` tag for beat grid entries (time, beat number, BPM).
    - Downbeats (beat 1 of each bar) are prefiltered for visualization.[^5][^7]
3. **Waveform normalization**
    - `analysis_from_rb_waveform(data, duration)` converts PWV data to a `WaveformAnalysis` object:
        - Low/mid/high arrays normalized to 0–1 per band.
        - Duration set from ANLZ if available; fallback heuristics if not.
    - This yields an analysis model independent of Rekordbox’s internal rendering.[^6]
4. **Audio path resolution (optional)**
    - `resolve_audio_path(ppth_path, library_root)` tries to map Rekordbox’s stored path to a real file on disk.
    - Useful for lab tools, but not required for waveform display; waveform data is fully contained in ANLZ.[^7][^6]

***

### 3.3 Rendering and Prerender Cache

Rendering steps per deck:

1. **Timing model**
    - `compute_timing_info(analysis)` → total duration, bin count, seconds per bin.
    - `compute_window_plan(...)` uses current playhead, zoom (e.g. 16–256 seconds), and tempo scale to compute:
        - Visible time window (start time, duration)
        - Corresponding bin indices (start bin, number of bins)
        - Playhead fraction within the window (for drawing the center line).[^8][^7]
2. **Full‑track prerender cache**
    - `PrerenderCache` holds a full‑track waveform image at a configurable resolution (pixels per second), plus metadata.
    - `ensure_prerender_cache(...)` decides whether to rebuild this image (track changed, width changed, or cache flagged dirty).
    - When valid, the renderer crops the appropriate window region from this big image rather than repainting the whole waveform each frame.[^9][^8]
3. **Waveform drawing**
    - `render_window_image(...)` and helper functions in `render.py` perform:
        - Window slicing: take a subset of low/mid/high arrays for the visible bins.
        - Smoothing: optional moving average over bins.
        - Column mapping: average bins into per‑pixel columns.
        - Drawing:
            - Symmetric overlaid mode, stacked band mode, or Rekordbox‑style overview stack.
            - Beat grid lines/markers drawn on top if enabled.[^9]
4. **Final compositing**
    - The cropped window image is resized to the canvas dimensions.
    - A vertical playhead line is drawn at the appropriate x‑position.
    - Result is presented in the Tkinter canvas for that deck.[^8][^7]

This design is what allows very wide zoom windows (16–256 seconds) at good performance: heavy work is done once in the prerender; playback uses cheap crops and small overlays.[^1][^8]

***

## 4. Dependencies

### 4.1 Runtime Dependencies (Python)

From `pyproject.toml` / `requirements.txt` and imports, the app depends on:

- **Python 3.9+**.[^1]
- **Tkinter** (standard library GUI).
- **numpy** – numeric arrays and efficient column averaging.
- **Pillow (PIL)** – image generation and drawing.
- **python‑osc** – OSC UDP server for `rkbx_link` communication.
- **pyrekordbox** – ANLZ file parsing (PWV/beat grid/cues).[^5][^1]

All of these are cross‑platform and available on macOS.

### 4.2 External Tool: `rkbx_link`

- `rkbx_wave` is tightly coupled to **`rkbx_link`**, an external tool that reads Rekordbox state and exposes it over OSC/Ableton Link.[^4][^1]
- On Windows, `rkbx_wave` bundles `rkbx_link.exe` and starts it automatically.
- `rkbx_link` has its own distribution and documentation, and newer releases indicate support for macOS alongside Windows, with the same OSC schema intended to be used for external integrations.[^10][^11][^12]


### 4.3 Platform/Packaging Assumptions

- README explicitly lists: **Windows 10/11**, Python 3.9+, Rekordbox 7.2.2.[^1]
- Packaging classifiers mark the project as Windows‑only (`Operating System :: Microsoft :: Windows`, `Environment :: Win32`).
- Config files are stored in `%APPDATA%\rkbx_wave\` (`default_config.json`, `last_config.txt`).[^1]

These are policy and packaging decisions rather than hard technical requirements of the waveform/rendering logic.

***

## 5. Why It’s Currently Windows‑Only

The Windows restriction stems from three things:

1. **Explicit guard in `rkbx_wave.py`**
    - If `sys.platform != "win32"`, the script prints an error and exits, citing the `rkbx_link.exe` dependency.
2. **Bundled Windows binary assumption**
    - The launcher logic searches for `rkbx_link.exe` in Windows‑style install locations and fails hard if it isn’t found.
    - It does not currently support “attach to an already‑running rkbx_link on another platform.”
3. **Windows‑specific defaults and metadata**
    - Config path under `%APPDATA%`.
    - Packaging marked Windows‑only, blocking pip install on macOS in the default configuration.[^1]

By contrast, the core pipeline (OSC listener, ANLZ parsing, rendering, Tkinter UI) is OS‑agnostic and uses cross‑platform libraries.

***

## 6. Quickest Path to macOS Support

The fastest way to get `rkbx_wave` running on macOS is:

> **Leave the entire waveform/GUI pipeline unchanged and only decouple the app from its Windows‑bundled `rkbx_link.exe`, so it can talk to a separately‑installed macOS build of `rkbx_link` over OSC.**

Concretely:

### 6.1 Make `rkbx_link` external and configurable

1. **Stop auto‑spawning a Windows `.exe` on non‑Windows**
    - For `sys.platform == "win32"`: keep existing behavior (auto‑spawn `rkbx_link.exe` for convenience).
    - For `sys.platform == "darwin"` (macOS):
        - Do **not** attempt to spawn any `.exe`.
        - Instead, assume the user will run `rkbx_link` manually (or provide a configurable command).
2. **Expose OSC connection parameters**
    - Add config entries for OSC `ip` and `port` (default `127.0.0.1:4460`).
    - Let the user configure these in a simple preferences dialog or a JSON file.
    - `RekordboxLinkListener` already takes `ip` and `port` arguments; wire those to config instead of hardcoding.[^3]
3. **Document macOS usage**
    - Install `rkbx_link` for macOS from its GitHub releases.
    - Run `rkbx_link` with Rekordbox open, ensuring OSC output is enabled and using the same port as configured in `rkbx_wave`.
    - Then start `rkbx_wave` and confirm it receives deck events.

This keeps the `rkbx_link` protocol and message schema intact, minimizing changes on both sides.[^11][^4]

***

### 6.2 Relax the hard Windows guard

1. **Modify the platform check**

Current behavior: immediately exit when not `win32`.
Proposed behavior:
    - If `sys.platform == "win32"`:
        - Run as today (auto‑spawn `rkbx_link.exe`, use `%APPDATA%` paths by default).
    - If `sys.platform == "darwin"`:
        - Allow the app to launch.
        - Display a one‑time info dialog explaining that `rkbx_link` must be installed and running separately on macOS, and where to configure OSC host/port.
    - For other platforms: either behave like macOS or stay unsupported.
2. **Update packaging metadata**
    - Change classifiers to include macOS, remove “Windows only”.
    - Remove `platforms=["win32"]` restriction so pip install on macOS is allowed.

This unlocks macOS installation without touching the core logic.

***

### 6.3 Adjust config paths and defaults for macOS

1. **Cross‑platform config directory**
    - Use `platformdirs` or similar to choose:
        - Windows: `%APPDATA%\rkbx_wave\` (keep current behavior).
        - macOS: `~/Library/Application Support/rkbx_wave/` or equivalent.
    - Keep the same filenames (`default_config.json`, `last_config.txt`) and load/save semantics.[^1]
2. **Library root defaults**
    - Remove hardcoded Windows paths (e.g. `C:\Rekordbox`) from any helper scripts.
    - Either leave the library root blank by default on macOS or expose it as a configurable path in the tuning panel or a config file.
    - Since waveform data comes from ANLZ, this is a quality‑of‑life tweak rather than a functional requirement.

These changes are minimal and localized to configuration utilities and path helpers.

***

### 6.4 Testing Plan

1. **Unit testing on macOS**
    - With saved ANLZ folders (from a Windows or mac Rekordbox environment), exercise:
        - `analyze_anlz_folder`, `analysis_from_rb_waveform`, and `extract_beat_grid` to confirm waveform and grid extraction.
        - `DeckController.load_anlz` and `render` to ensure images are generated correctly with no platform‑specific assumptions.
2. **End‑to‑end testing with Rekordbox + macOS `rkbx_link`**
    - Install Rekordbox 7.2.x on mac.
    - Install macOS `rkbx_link`, start it with OSC enabled.
    - Run `rkbx_wave` with the new platform guard and config wiring.
    - Verify:
        - Deck time sync, beat grid alignment, correct ANLZ folder resolution from `/track/{deck}/anlz_path`.
        - Zoom and scrolling behavior at multiple window durations and BPM changes.
3. **Regression testing on Windows**
    - Ensure Windows workflow remains unchanged: `rkbx_wave` still finds and spawns `rkbx_link.exe`, uses `%APPDATA%`, and renders identically.

***

## 7. Longer‑Term Enhancements (Optional)

Once the basic macOS port is working, you could consider:

- **Unified connection model**:
    - Even on Windows, allow “external” mode where `rkbx_wave` does not spawn `rkbx_link.exe` but simply listens on a config‑specified host/port.
- **Detection of `rkbx_link` availability**:
    - Add UI indicators for “connected/disconnected” and log the raw OSC messages for debugging.
- **Plugin‑like timing sources**:
    - Abstract the timing/track source behind an interface, so you can support other protocols (Pro DJ Link over UDP, Ableton Link only, etc.) without touching the rendering pipeline.

These are not necessary for the quickest macOS port but would future‑proof the app.

***

If you want, I can sketch an actual patch layout (file‑by‑file edits) or a small prototype CLI that runs the core ANLZ→waveform render path on macOS so you can validate the pipeline before wiring in `rkbx_link`.

<div align="center">⁂</div>

[^1]: https://www.reddit.com/r/Rekordbox/comments/1pjg9vg/full_zoom_out_xdjlike_waveforms/

[^2]: https://forums.pioneerdj.com/hc/en-us/community/posts/115000329206-How-change-size-of-waveforms-in-performance-mode-zoom-out-more-than-two-times

[^3]: https://community.pioneerdj.com/hc/en-us/community/posts/22977610650649-Rekordbox-Zoom-out

[^4]: https://github.com/grufkork/rkbx_link

[^5]: https://www.deejayplaza.com/en/articles/rekordbox-size-waveform-zoom

[^6]: https://www.reddit.com/r/Beatmatch/comments/1en355d/im_going_insane_is_there_a_way_to_make_rekordbox/

[^7]: https://forums.pioneerdj.com/hc/en-us/community/posts/203459013-zooming-in-and-out-of-waveforms-in-rekordbox-DJ

[^8]: https://www.youtube.com/watch?v=TzK21zT3rFI

[^9]: https://www.reddit.com/r/Rekordbox/comments/fqu3qa/is_there_an_option_to_enlarge_the_waveform_in/

[^10]: https://3gg.se/products/rkbx_link/

[^11]: https://3gg.se/projects/rkbx_link/

[^12]: https://github.com/grufkork/rkbx_link/releases

