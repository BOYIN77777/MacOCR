#!/bin/bash
set -euo pipefail

# build_python_env.sh - Build a relocatable Python environment for MacOCR.app
# Downloads python-build-standalone and installs all dependencies.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
PYTHON_RUNTIME_DIR="$BUILD_DIR/python-runtime"

PYTHON_VERSION="3.12.13"
PYTHON_BUILD="cpython-${PYTHON_VERSION}+20260602-aarch64-apple-darwin-install_only.tar.gz"
PYTHON_DOWNLOAD_URL="https://github.com/indygreg/python-build-standalone/releases/download/20260602/${PYTHON_BUILD}"

echo "=== MacOCR Python Runtime Builder ==="
echo "Python: ${PYTHON_VERSION} (python-build-standalone)"
echo "Build dir: ${BUILD_DIR}"

# Step 1: Download python-build-standalone
if [ ! -f "$BUILD_DIR/$PYTHON_BUILD" ]; then
    echo ""
    echo "[1/6] Downloading python-build-standalone..."
    mkdir -p "$BUILD_DIR"
    curl -L --progress-bar -o "$BUILD_DIR/$PYTHON_BUILD" "$PYTHON_DOWNLOAD_URL"
    echo ""
else
    echo ""
    echo "[1/6] Python archive already downloaded (skip)"
fi

# Step 2: Extract Python runtime
echo ""
echo "[2/6] Extracting Python runtime..."
rm -rf "$PYTHON_RUNTIME_DIR"
mkdir -p "$PYTHON_RUNTIME_DIR"
tar xzf "$BUILD_DIR/$PYTHON_BUILD" -C "$PYTHON_RUNTIME_DIR" --strip-components=1

PYTHON_EXE="$PYTHON_RUNTIME_DIR/bin/python3.12"
echo "Python: $($PYTHON_EXE --version)"

# Step 3: Bootstrap pip (install_only variant has no pip)
echo ""
echo "[3/6] Bootstrapping pip..."
"$PYTHON_EXE" -m ensurepip --upgrade 2>&1 | tail -3
"$PYTHON_EXE" -m pip install --upgrade pip --quiet 2>&1 | tail -3
echo "pip: $($PYTHON_EXE -m pip --version)"

# Step 4: Install all dependencies from requirements.txt
echo ""
echo "[4/6] Installing Python packages (~20-40 min)..."
echo "This downloads torch, transformers, detectron2, opencv, etc."

# Install torch first (detectron2 setup.py imports torch at build time)
echo "  [4a] Installing torch (prerequisite for detectron2)..."
"$PYTHON_EXE" -m pip install torch torchvision --quiet 2>&1 | tail -3

# Install detectron2 separately with --no-build-isolation
# because its setup.py imports torch during the build phase
echo "  [4b] Installing detectron2 (from source, --no-build-isolation)..."
"$PYTHON_EXE" -m pip install --no-build-isolation \
    "git+https://github.com/facebookresearch/detectron2.git" \
    2>&1 | tail -5

echo "  [4c] Installing remaining packages..."
"$PYTHON_EXE" -m pip install \
    "transformers==4.49.0" \
    fastapi \
    "uvicorn[standard]" \
    python-multipart \
    aiofiles \
    aiohttp \
    Pillow \
    img2pdf \
	    pyobjc-framework-Vision \
    magic-pdf \
    doclayout_yolo \
    rapid-table \
    modelscope \
    timm \
    ultralytics \
    ftfy \
    shapely \
    pyclipper \
    openai \
    2>&1 | grep -v "^Requirement already satisfied" | tail -30

# Verify critical packages
echo ""
echo "--- Verification ---"
"$PYTHON_EXE" -c "
import magic_pdf, fastapi, uvicorn, PIL, cv2, torch, transformers
print(f'magic-pdf: OK')
print(f'fastapi: {fastapi.__version__}')
print(f'torch: {torch.__version__} (mps: {torch.backends.mps.is_available()})')
print(f'cv2: {cv2.__version__}')
"

# Step 5: Apply patches to magic-pdf
echo ""
echo "[5/6] Applying magic-pdf patches..."
bash "$SCRIPT_DIR/patch_magic_pdf.sh" "$PYTHON_RUNTIME_DIR/lib/python3.12/site-packages"

# Step 6: Copy the backend source
echo ""
echo "[6/6] Copying backend source..."
BACKEND_DEST="$PYTHON_RUNTIME_DIR/lib/python3.12/site-packages/PythonBackend"
rsync -a "$PROJECT_DIR/PythonBackend/" "$BACKEND_DEST/" \
    --exclude='__pycache__' \
    --exclude='*.pyc' \
    --exclude='.venv' \
    --exclude='venv'

# Create launcher script
cat > "$PYTHON_RUNTIME_DIR/bin/start-macocr-backend" << 'PYEOF'
#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNTIME_DIR="$(dirname "$SCRIPT_DIR")"
export PYTHONHOME="$RUNTIME_DIR"
export PYTHONPATH="$RUNTIME_DIR/lib/python3.12/site-packages"
exec "$SCRIPT_DIR/python3.12" -m PythonBackend.server "$@"
PYEOF
chmod +x "$PYTHON_RUNTIME_DIR/bin/start-macocr-backend"

# Report
echo ""
echo "=== Build Complete ==="
echo "Runtime size: $(du -sh "$PYTHON_RUNTIME_DIR" | cut -f1)"
echo "Packages: $("$PYTHON_EXE" -m pip list 2>/dev/null | wc -l)"
echo ""
echo "To test: $PYTHON_RUNTIME_DIR/bin/start-macocr-backend --port 8765"
