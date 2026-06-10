#!/bin/bash
set -euo pipefail

# patch_magic_pdf.sh - Apply required patches to magic-pdf after pip install
# These patches fix compatibility issues with the model checkpoints we use.

SITE_PACKAGES="${1:-}"

if [ -z "$SITE_PACKAGES" ]; then
    echo "Usage: $0 <path/to/site-packages>"
    echo "Example: $0 build/python-runtime/lib/python3.12/site-packages"
    exit 1
fi

MAGIC_PDF_DIR="$SITE_PACKAGES/magic_pdf"
MODEL_CONFIG_DIR="$MAGIC_PDF_DIR/resources/model_config"

if [ ! -d "$MAGIC_PDF_DIR" ]; then
    echo "ERROR: magic_pdf not found at $MAGIC_PDF_DIR"
    exit 1
fi

echo "=== Patching magic-pdf at $MAGIC_PDF_DIR ==="

# Patch 1: LayoutLMv3 Cascade R-CNN config
# The checkpoint uses CascadeROIHeads but the default config has StandardROIHeads.
# magic-pdf 1.3.12 from PyPI doesn't include this config file at all, so we create it.
LAYOUT_DIR="$MODEL_CONFIG_DIR/layoutlmv3"
LAYOUT_YAML="$LAYOUT_DIR/layoutlmv3_base_inference.yaml"

echo ""
echo "[1/2] Creating LayoutLMv3 Cascade R-CNN config..."

mkdir -p "$LAYOUT_DIR"

if [ -f "$LAYOUT_YAML" ]; then
    # If file exists, just ensure CascadeROIHeads is set
    sed -i '' 's/NAME: "StandardROIHeads"/NAME: "CascadeROIHeads"/g' "$LAYOUT_YAML"
    echo "    Updated existing config"
else
    # Create the config from scratch (Cascade R-CNN with ViT backbone)
    # Must use VLGeneralizedRCNN for vision-language dict inputs
    cat > "$LAYOUT_YAML" << 'EOF'
MODEL:
  META_ARCHITECTURE: "VLGeneralizedRCNN"
  WEIGHTS: ""
  BACKBONE:
    NAME: "build_vit_fpn_backbone"
  VIT:
    NAME: "layoutlmv3_base"
    OUT_FEATURES: ["layer3", "layer5", "layer7", "layer11"]
    IMG_SIZE: [224, 224]
    POS_TYPE: "shared_rel"
    DROP_PATH: 0.0
    MODEL_KWARGS: '"{}"'
  FPN:
    IN_FEATURES: ["layer3", "layer5", "layer7", "layer11"]
    OUT_CHANNELS: 256
    NORM: ""
    FUSE_TYPE: "sum"
  ANCHOR_GENERATOR:
    SIZES: [[32], [64], [128], [256]]
    ASPECT_RATIOS: [[0.5, 1.0, 2.0]]
  RPN:
    IN_FEATURES: ["p3", "p4", "p5", "p6"]
    PRE_NMS_TOPK_TRAIN: 2000
    PRE_NMS_TOPK_TEST: 1000
    POST_NMS_TOPK_TRAIN: 1000
    POST_NMS_TOPK_TEST: 1000
    BATCH_SIZE_PER_IMAGE: 256
  ROI_HEADS:
    NAME: "CascadeROIHeads"
    NUM_CLASSES: 9
    IN_FEATURES: ["p3", "p4", "p5", "p6"]
    BATCH_SIZE_PER_IMAGE: 512
    SCORE_THRESH_TEST: 0.2
    NMS_THRESH_TEST: 0.5
    PROPOSAL_APPEND_GT: False
  ROI_BOX_HEAD:
    NAME: "FastRCNNConvFCHead"
    NUM_FC: 2
    POOLER_RESOLUTION: 7
    CLS_AGNOSTIC_BBOX_REG: True
  ROI_BOX_CASCADE_HEAD:
    BBOX_REG_WEIGHTS: ((10.0, 10.0, 5.0, 5.0), (20.0, 20.0, 10.0, 10.0), (30.0, 30.0, 15.0, 15.0))
    IOUS: (0.5, 0.6, 0.7)
  IMAGE_ONLY: True
  CONFIG_PATH: ""
  DEVICE: "cpu"
  PIXEL_MEAN: [127.5, 127.5, 127.5]
  PIXEL_STD: [127.5, 127.5, 127.5]
DATASETS:
  TRAIN: ("publynet_train",)
  TEST: ("publynet_val",)
DATALOADER:
  NUM_WORKERS: 2
INPUT:
  MIN_SIZE_TEST: 224
  MAX_SIZE_TEST: 224
SOLVER:
  IMS_PER_BATCH: 2
  BASE_LR: 0.0002
  STEPS: (20000, 26000)
  MAX_ITER: 30000
  WARMUP_ITERS: 1000
  OPTIMIZER: "ADAMW"
  GRADIENT_ACCUMULATION_STEPS: 1
VERSION: 2
EOF
    echo "    Created Cascade R-CNN config"
fi

# Patch 2: MFR Unimernet ignore_mismatched_sizes
UNIMERNET_PY="$MAGIC_PDF_DIR/model/sub_modules/mfr/unimernet/Unimernet.py"
echo ""
echo "[2/2] Patching Unimernet for weight size mismatches..."

if [ -f "$UNIMERNET_PY" ]; then
    if ! grep -q "ignore_mismatched_sizes" "$UNIMERNET_PY"; then
        sed -i '' 's/self\.model = UnimernetModel\.from_pretrained(weight_dir, attn_implementation="eager")/self.model = UnimernetModel.from_pretrained(weight_dir, attn_implementation="eager", ignore_mismatched_sizes=True)/g' "$UNIMERNET_PY"
        sed -i '' 's/self\.model = UnimernetModel\.from_pretrained(weight_dir)/self.model = UnimernetModel.from_pretrained(weight_dir, ignore_mismatched_sizes=True)/g' "$UNIMERNET_PY"
        echo "    Patched: ignore_mismatched_sizes=True added"
    else
        echo "    Already patched (skip)"
    fi
else
    echo "    WARNING: Unimernet.py not found at $UNIMERNET_PY"
fi

# Patch 3: Map 'zh' language to 'ch' in PytorchPaddleOCR (PaddleOCR uses 'ch' not 'zh')
PADDLE_PY="$MAGIC_PDF_DIR/model/sub_modules/ocr/paddleocr2pytorch/pytorch_paddle.py"
echo ""
echo "[3/3] Patching PaddleOCR language mapping (zh → ch)..."

if [ -f "$PADDLE_PY" ]; then
    if ! grep -q "lang == 'zh'" "$PADDLE_PY"; then
        sed -i '' 's/self.lang = kwargs.get(.lang., .ch.)/self.lang = kwargs.get("lang", "ch")\n        if self.lang == "zh":\n            self.lang = "ch"/' "$PADDLE_PY"
        echo "    Patched: zh → ch language mapping added"
    else
        echo "    Already patched (skip)"
    fi
else
    echo "    WARNING: pytorch_paddle.py not found at $PADDLE_PY"
fi

echo ""
echo "=== Patching complete ==="
