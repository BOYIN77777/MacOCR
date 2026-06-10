#!/bin/bash
set -euo pipefail

# package_app.sh - Build and package MacOCR.app for distribution
# Requires: Xcode, python-build-standalone environment already built

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
DERIVED_DATA="$BUILD_DIR/DerivedData"
APP_NAME="MacOCR"
PYTHON_RUNTIME_SRC="$BUILD_DIR/python-runtime"

echo "=== MacOCR App Packager ==="

# Step 1: Build Python runtime if not already built
if [ ! -d "$PYTHON_RUNTIME_SRC/bin" ]; then
    echo "Building Python runtime..."
    bash "$SCRIPT_DIR/build_python_env.sh"
fi

# Step 2: Build the Swift app in Release configuration
echo ""
echo "[1/3] Building Swift app (Release)..."
xcodebuild \
    -project "$PROJECT_DIR/MacOCR.xcodeproj" \
    -scheme MacOCR \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA" \
    2>&1 | grep -E "error:|warning:|BUILD" | grep -v "note:" | tail -20 || true

APP_PATH="$DERIVED_DATA/Build/Products/Release/$APP_NAME.app"

if [ ! -d "$APP_PATH" ]; then
    echo "ERROR: App bundle not found at $APP_PATH"
    echo "Checking Debug path..."
    APP_PATH="$DERIVED_DATA/Build/Products/Debug/$APP_NAME.app"
    if [ ! -d "$APP_PATH" ]; then
        echo "ERROR: App not found in either Release or Debug"
        exit 1
    fi
    echo "Using Debug build: $APP_PATH"
fi

echo "Swift binary: $APP_PATH/Contents/MacOS/$APP_NAME"

# Step 3: Embed Python runtime
echo ""
echo "[2/3] Embedding Python runtime..."
RESOURCES_DIR="$APP_PATH/Contents/Resources"
mkdir -p "$RESOURCES_DIR"

# Copy the entire Python runtime
rm -rf "$RESOURCES_DIR/python-runtime"
rsync -a "$PYTHON_RUNTIME_SRC/" "$RESOURCES_DIR/python-runtime/"

# Create the backend launcher script inside the app
BACKEND_LAUNCHER="$APP_PATH/Contents/MacOS/start-backend"
cat > "$BACKEND_LAUNCHER" << 'SHEOF'
#!/bin/bash
set -e

# Find the app bundle directory
if [ -n "$MACOCR_APP_DIR" ]; then
    APP_DIR="$MACOCR_APP_DIR"
else
    APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
fi

RUNTIME_DIR="$APP_DIR/Resources/python-runtime"
export PYTHONHOME="$RUNTIME_DIR"
export PYTHONPATH="$RUNTIME_DIR/lib/python3.12/site-packages"

# Start the backend server
exec "$RUNTIME_DIR/bin/python3.12" -m PythonBackend.server "$@"
SHEOF
chmod +x "$BACKEND_LAUNCHER"

# Step 4: Update Info.plist
echo ""
echo "[3/3] Updating Info.plist..."
PLIST="$APP_PATH/Contents/Info.plist"

# Ensure ATS allows local networking (already in plist but verify)
if /usr/libexec/PlistBuddy -c "Print :NSAppTransportSecurity:NSAllowsLocalNetworking" "$PLIST" 2>/dev/null; then
    echo "ATS local networking: OK"
else
    echo "WARNING: NSAllowsLocalNetworking not found in Info.plist"
fi

# Verify bundle structure
echo ""
echo "=== Bundle Contents ==="
echo "App size: $(du -sh "$APP_PATH" | cut -f1)"
echo ""
echo "Top-level:"
ls -la "$APP_PATH/Contents/"
echo ""
echo "Resources:"
ls "$APP_PATH/Contents/Resources/" | head -10
echo ""
echo "Python runtime: $(du -sh "$RESOURCES_DIR/python-runtime" | cut -f1)"

# Step 5: Test launch (optional, requires terminal)
echo ""
echo "=== Packaging Complete ==="
echo "App bundle: $APP_PATH"
echo ""
echo "To test: open $APP_PATH"
echo "To sign and notarize: bash Scripts/sign_and_notarize.sh $APP_PATH"
