#!/bin/bash
set -euo pipefail

# bundle_dylibs.sh - Bundle and fix native library dependencies
# Ensures all .dylib/.so files in the app bundle have correct install names

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP_PATH="$1"

if [ -z "$APP_PATH" ] || [ ! -d "$APP_PATH" ]; then
    echo "Usage: $0 <path/to/MacOCR.app>"
    exit 1
fi

echo "=== Bundling Native Libraries ==="

# Find all dylibs and .so files
find "$APP_PATH" -type f \( -name "*.dylib" -o -name "*.so" \) | while read -r lib; do
    echo "Fixing: $(basename "$lib")"

    # Change install name to use @rpath
    install_name_tool -id "@rpath/$(basename "$lib")" "$lib" 2>/dev/null || true

    # Fix dependencies to point within the bundle
    otool -L "$lib" | grep -oE '/opt/homebrew/[^ ]+' | while read -r dep; do
        dep_name=$(basename "$dep")
        install_name_tool -change "$dep" "@rpath/$dep_name" "$lib" 2>/dev/null || true
    done

    # Code sign
    codesign --force --sign - "$lib" 2>/dev/null || true
done

echo "Done."
