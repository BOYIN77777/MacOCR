#!/bin/bash
set -euo pipefail

# create_dmg.sh - Build a distributable DMG for MacOCR.app
# Uses only macOS built-in tools (no brew deps required).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
OUTPUT_DIR="$PROJECT_DIR/Distribution"

APP_PATH="${1:-$BUILD_DIR/DerivedData/Build/Products/Release/MacOCR.app}"
APP_NAME="MacOCR"
DMG_NAME="${APP_NAME}"
DMG_FILE="$OUTPUT_DIR/${DMG_NAME}.dmg"
TMP_DMG_DIR="$BUILD_DIR/dmg-staging"
TMP_DMG="$BUILD_DIR/${DMG_NAME}-tmp.dmg"

if [ ! -d "$APP_PATH" ]; then
    echo "ERROR: App not found at $APP_PATH"
    echo "Usage: $0 [path/to/MacOCR.app]"
    exit 1
fi

echo "=== MacOCR DMG Builder ==="
echo "App:  $APP_PATH"
echo "Output: $DMG_FILE"

# Step 1: Clean and prepare staging
echo ""
echo "[1/5] Preparing staging directory..."
rm -rf "$TMP_DMG_DIR"
mkdir -p "$TMP_DMG_DIR"
mkdir -p "$OUTPUT_DIR"

# Step 2: Copy app
echo "[2/5] Copying app..."
rsync -a "$APP_PATH" "$TMP_DMG_DIR/"

# Step 3: Create Applications symlink
echo "[3/5] Creating Applications symlink..."
ln -s /Applications "$TMP_DMG_DIR/Applications"

# Step 4: Create background image with instructions
echo "[4/5] Creating DMG background..."
BG_DIR="$TMP_DMG_DIR/.background"
mkdir -p "$BG_DIR"

# Generate a simple background image using Python (built-in macOS Python)
export TMP_DMG_DIR
python3 - "$TMP_DMG_DIR" << 'PYEOF'
import os, struct, zlib, sys

dmg_dir = sys.argv[1]
bg_dir = os.path.join(dmg_dir, '.background')
os.makedirs(bg_dir, exist_ok=True)
bg_path = os.path.join(bg_dir, 'background.png')
w, h = 660, 400

def chunk(chunk_type, data):
    c = chunk_type + data
    crc = struct.pack('>I', zlib.crc32(c) & 0xffffffff)
    return struct.pack('>I', len(data)) + c + crc

header = b'\x89PNG\r\n\x1a\n'
ihdr = chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))

raw = b''
for y in range(h):
    raw += b'\x00'
    for x in range(w):
        factor = 1.0 - (y / h) * 0.06
        raw += struct.pack('BBBB',
            int(245 * factor), int(245 * factor), int(250 * factor), 255)

idat = chunk(b'IDAT', zlib.compress(raw))
iend = chunk(b'IEND', b'')

with open(bg_path, 'wb') as f:
    f.write(header + ihdr + idat + iend)

print(f"  Background: {bg_path} ({w}x{h})")
PYEOF

# Step 5: Build DMG
echo ""
echo "[5/5] Building DMG..."

# Remove old files
rm -f "$TMP_DMG" "$DMG_FILE"

# Calculate size with generous padding (HFS+ needs ~20-25% overhead + room for metadata)
STAGING_SIZE_KB=$(du -sk "$TMP_DMG_DIR" | cut -f1)
DMG_SIZE_KB=$(( STAGING_SIZE_KB + 512000 ))  # +500MB for HFS+ overhead and safety

echo "  Staging size: $(( STAGING_SIZE_KB / 1024 )) MB"
echo "  DMG capacity: $(( DMG_SIZE_KB / 1024 )) MB"

# Create the DMG
hdiutil create -volname "$APP_NAME" \
    -srcfolder "$TMP_DMG_DIR" \
    -size "${DMG_SIZE_KB}k" \
    -fs HFS+ \
    -fsargs "-c c=64,a=16,e=16" \
    -format UDRW \
    -quiet \
    "$TMP_DMG"

echo "  Raw DMG created, setting layout..."

# Mount and configure layout
DEVICE=$(hdiutil attach -readwrite -noverify -noautoopen "$TMP_DMG" 2>&1 | \
         grep 'Apple_HFS' | awk '{print $1}' | head -1 || true)

if [ -z "$DEVICE" ]; then
    echo "  WARNING: Could not mount DMG for layout customization"
else
    MOUNT_POINT="/Volumes/$APP_NAME"

    # Set icon positions via AppleScript
    /usr/bin/osascript << EOF
    tell application "Finder"
        tell disk "${APP_NAME}"
            open
            set current view of container window to icon view
            set toolbar visible of container window to false
            set statusbar visible of container window to false
            set the bounds of container window to {200, 200, 860, 600}
            set viewOptions to the icon view options of container window
            set arrangement of viewOptions to not arranged
            set icon size of viewOptions to 96
            set background picture of viewOptions to file ".background:background.png"
            set position of item "${APP_NAME}" of container window to {180, 180}
            set position of item "Applications" of container window to {480, 180}
            close
            open
        end tell
    end tell
EOF

    # Wait for Finder to apply changes
    sleep 2

    # Unmount
    hdiutil detach "$DEVICE" -quiet -force
    echo "  Layout applied"
fi

# Convert to compressed read-only DMG
echo "  Converting to compressed DMG..."
hdiutil convert "$TMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_FILE" -quiet

# Clean up
rm -f "$TMP_DMG"
rm -rf "$TMP_DMG_DIR"

# Report
echo ""
echo "=== DMG Complete ==="
echo "File: $DMG_FILE"
echo "Size: $(du -sh "$DMG_FILE" | cut -f1)"
echo ""
echo "To sign the DMG:"
echo "  codesign --force --sign \"\$DEVELOPER_ID\" --timestamp \"$DMG_FILE\""
echo ""
echo "To notarize:"
echo "  xcrun notarytool submit \"$DMG_FILE\" --apple-id \"\$APPLE_ID\" --team-id \"\$TEAM_ID\" --password \"\$APP_PASSWORD\" --wait"
echo "  xcrun stapler staple \"$DMG_FILE\""
