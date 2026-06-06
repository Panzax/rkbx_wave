#!/bin/bash
#
# Re-sign Rekordbox 7 ad-hoc with the get-task-allow entitlement.
#
# Why: rkbx_link uses task_for_pid() to read Rekordbox's memory. Apple's
# notarized signature does not include get-task-allow, so we must replace
# the signature with an ad-hoc one that does.
#
# Why move to ~/Desktop first: starting with macOS Ventura the App Management
# privacy feature blocks codesign (even via sudo) from modifying app bundles
# under /Applications. Moving the bundle out of /Applications sidesteps this
# protection without disabling SIP. We move it back when we're done.

set -e

REKORDBOX_DIR_NAME="rekordbox 7"
APPLICATIONS_PATH="/Applications/${REKORDBOX_DIR_NAME}"
WORK_PATH="${HOME}/Desktop/${REKORDBOX_DIR_NAME}"
ENTITLEMENTS_PLIST="/tmp/rekordbox_entitlements.plist"

echo "=== Resigning Rekordbox with get-task-allow ==="
echo ""
echo "This will:"
echo "  1. Move Rekordbox out of /Applications to bypass App Management"
echo "  2. Extract its existing entitlements and add get-task-allow"
echo "  3. Re-sign the inner executable and outer bundle ad-hoc"
echo "  4. Move Rekordbox back to /Applications"
echo ""
echo "WARNING: Rekordbox will lose Apple notarization. The first launch may"
echo "         require right-click > Open. Make sure Rekordbox is NOT running."
echo ""
read -p "Continue? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 1
fi

# Refuse to run while Rekordbox is alive, otherwise codesign will fail
# with "Operation not permitted" on the open executable.
if pgrep -x "rekordbox" >/dev/null; then
    echo "✗ Rekordbox is currently running. Quit it and try again."
    exit 1
fi

# Locate the bundle. Allow re-runs that left the app on the Desktop.
if [ -d "${APPLICATIONS_PATH}" ]; then
    SOURCE_LOCATION="applications"
elif [ -d "${WORK_PATH}" ]; then
    echo "Note: Rekordbox already at ~/Desktop. Continuing in place."
    SOURCE_LOCATION="desktop"
else
    echo "✗ Rekordbox not found at ${APPLICATIONS_PATH} or ${WORK_PATH}"
    exit 1
fi

echo ""
echo "Step 1: Moving Rekordbox to ~/Desktop..."
if [ "${SOURCE_LOCATION}" = "applications" ]; then
    sudo mv "${APPLICATIONS_PATH}" "${HOME}/Desktop/"
    echo "  Moved to: ${WORK_PATH}"
else
    echo "  Already on Desktop, skipping."
fi

REKORDBOX_BUNDLE="${WORK_PATH}/rekordbox.app"
REKORDBOX_BIN="${REKORDBOX_BUNDLE}/Contents/MacOS/rekordbox"

if [ ! -f "${REKORDBOX_BIN}" ]; then
    echo "✗ rekordbox executable not found at: ${REKORDBOX_BIN}"
    echo "  The bundle may be corrupted. Reinstall Rekordbox and try again."
    exit 1
fi

echo ""
echo "Step 2: Clearing extended attributes (avoids 'internal error in Code Signing subsystem')..."
sudo xattr -cr "${REKORDBOX_BUNDLE}" 2>/dev/null || true

echo ""
echo "Step 3: Extracting current entitlements..."
# Use ':-' rather than '-' to get clean XML on stdout instead of a binary blob.
# The deprecation warning goes to stderr and is harmless.
if sudo codesign -d --entitlements :- "${REKORDBOX_BIN}" 2>/dev/null > "${ENTITLEMENTS_PLIST}" \
        && [ -s "${ENTITLEMENTS_PLIST}" ]; then
    echo "  Extracted from inner executable."
elif sudo codesign -d --entitlements :- "${REKORDBOX_BUNDLE}" 2>/dev/null > "${ENTITLEMENTS_PLIST}" \
        && [ -s "${ENTITLEMENTS_PLIST}" ]; then
    echo "  Extracted from app bundle."
else
    # Fallback used only if the bundle is already unsigned (e.g. a previous
    # failed run). Includes the entitlements Pioneer normally ships with so
    # JIT/audio/camera still work after re-signing.
    echo "  No existing signature found — writing minimal plist."
    cat > "${ENTITLEMENTS_PLIST}" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
    <true/>
    <key>com.apple.security.cs.disable-library-validation</key>
    <true/>
    <key>com.apple.security.device.audio-input</key>
    <true/>
    <key>com.apple.security.device.camera</key>
    <true/>
    <key>com.apple.security.get-task-allow</key>
    <true/>
</dict>
</plist>
EOF
fi

echo ""
echo "Step 4: Ensuring get-task-allow is in the plist..."
if grep -q "com.apple.security.get-task-allow" "${ENTITLEMENTS_PLIST}"; then
    echo "  Already present."
else
    echo "  Adding it before closing </dict>."
    sed -i '' 's|</dict>|    <key>com.apple.security.get-task-allow</key>\
    <true/>\
</dict>|' "${ENTITLEMENTS_PLIST}"
fi

echo ""
echo "Step 5: Re-signing inner executable + outer bundle ad-hoc..."
# Sign the inner Mach-O first so the bundle's seal references a valid sub-signature.
sudo codesign -s - --force --entitlements "${ENTITLEMENTS_PLIST}" "${REKORDBOX_BIN}"
# Then seal the bundle. We do not use --deep because Pioneer's frameworks are
# already correctly signed and re-signing them ad-hoc tends to trip the
# "internal error in Code Signing subsystem" failure mode.
sudo codesign -s - --force --entitlements "${ENTITLEMENTS_PLIST}" "${REKORDBOX_BUNDLE}"

echo ""
echo "Step 6: Verifying..."
if sudo codesign -d --entitlements :- "${REKORDBOX_BIN}" 2>/dev/null | grep -q "get-task-allow"; then
    echo "  ✓ get-task-allow present on rekordbox executable."
else
    echo "  ✗ get-task-allow missing — verification failed."
    exit 1
fi

echo ""
echo "Step 7: Moving Rekordbox back to /Applications..."
sudo mv "${WORK_PATH}" /Applications/

rm -f "${ENTITLEMENTS_PLIST}"

echo ""
echo "=== Done! ==="
echo ""
echo "Next steps:"
echo "  1. Launch Rekordbox (right-click > Open if Gatekeeper complains the first time)"
echo "  2. Load and play a track"
echo "  3. In another terminal: sudo ./target/release/rkbx_link"
