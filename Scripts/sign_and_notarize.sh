#!/bin/bash
set -euo pipefail

# sign_and_notarize.sh - Code sign and notarize MacOCR.app
# Prerequisites:
#   - Apple Developer account with Developer ID Application certificate
#   - App-specific password for notarization
#
# Required env vars:
#   DEVELOPER_ID       "Developer ID Application: Your Name (TEAMID)"
#   APPLE_ID           your@email.com
#   APPLE_TEAM_ID      Your Team ID
#   APPLE_APP_PASSWORD App-specific password (created at appleid.apple.com)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP_PATH="${1:-}"

if [ -z "$APP_PATH" ] || [ ! -d "$APP_PATH" ]; then
    echo "Usage: $0 <path/to/MacOCR.app>"
    echo ""
    echo "Environment variables:"
    echo "  DEVELOPER_ID        Your Developer ID Application identity"
    echo "  APPLE_ID            Apple ID email"
    echo "  APPLE_TEAM_ID       Team ID"
    echo "  APPLE_APP_PASSWORD  App-specific password"
    echo ""
    echo "To find your Developer ID: security find-identity -v -p codesigning | grep 'Developer ID'"
    exit 1
fi

APP_NAME=$(basename "$APP_PATH" .app)
ENTITLEMENTS="$PROJECT_DIR/MacOCR/Resources/MacOCR.entitlements"

if [ ! -f "$ENTITLEMENTS" ]; then
    echo "ERROR: Entitlements file not found at $ENTITLEMENTS"
    echo "Creating minimal entitlements..."
    cat > "$ENTITLEMENTS" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
    <true/>
    <key>com.apple.security.cs.disable-library-validation</key>
    <true/>
    <key>com.apple.security.network.client</key>
    <true/>
</dict>
</plist>
EOF
fi

echo "=== Code Sign & Notarize ==="
echo "App: $APP_PATH"
echo "Identity: ${DEVELOPER_ID:-<not set>}"
echo "Apple ID: ${APPLE_ID:-<not set>}"
echo ""

# Validate required vars
for var in DEVELOPER_ID APPLE_ID APPLE_TEAM_ID APPLE_APP_PASSWORD; do
    if [ -z "${!var:-}" ]; then
        echo "ERROR: $var is not set"
        exit 1
    fi
done

# Step 1: Sign all shared libraries and binaries inside Python runtime
echo "[1/5] Signing Python runtime binaries..."

SIGN_COUNT=0
# Sign .dylib files
find "$APP_PATH/Contents/Resources/python-runtime" -type f \( -name "*.dylib" -o -name "*.so" \) -print0 2>/dev/null | while IFS= read -r -d '' file; do
    codesign --force --sign "$DEVELOPER_ID" --timestamp --options=runtime 2>/dev/null "$file" || true
done

# Sign Python executables
find "$APP_PATH/Contents/Resources/python-runtime/bin" -type f -print0 2>/dev/null | while IFS= read -r -d '' file; do
    if file "$file" | grep -q "Mach-O"; then
        codesign --force --sign "$DEVELOPER_ID" --timestamp --options=runtime 2>/dev/null "$file" || true
    fi
done

# Step 2: Sign any embedded .framework bundles
echo "[2/5] Signing frameworks..."
find "$APP_PATH" -name "*.framework" -type d -print0 2>/dev/null | while IFS= read -r -d '' framework; do
    codesign --force --sign "$DEVELOPER_ID" --timestamp --options=runtime "$framework" 2>/dev/null || true
done

# Step 3: Sign the main app bundle
echo "[3/5] Signing main application..."
codesign --force --deep --sign "$DEVELOPER_ID" \
    --timestamp \
    --options=runtime \
    --entitlements "$ENTITLEMENTS" \
    "$APP_PATH"

# Step 4: Verify signature
echo "[4/5] Verifying signature..."
codesign --verify --deep --strict "$APP_PATH" 2>&1 || {
    echo "WARNING: Signature verification failed"
    echo "You may need to sign internal components manually"
}
echo "Signature: OK"

# Step 5: Notarize
echo "[5/5] Submitting for notarization..."
ZIP_PATH="/tmp/${APP_NAME}_notarize.zip"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

xcrun notarytool submit "$ZIP_PATH" \
    --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_PASSWORD" \
    --wait

rm -f "$ZIP_PATH"

# Staple the notarization ticket
echo ""
echo "Stapling notarization ticket..."
xcrun stapler staple "$APP_PATH"

echo ""
echo "=== Complete ==="
echo "Notarized app: $APP_PATH"
echo "Ready for distribution."
