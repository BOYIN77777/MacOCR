"""
Apple Vision text detection + recognition for scanned PDF pages.

Uses macOS Vision framework (VNRecognizeTextRequest) with ANE acceleration.
~0.3s/page vs PaddleOCR's ~1.2s/page (4× faster).
Built-in Chinese + English recognition — no external model needed.

Fallback: PaddleOCR if Vision is unavailable or fails.
"""

import logging
import time
from typing import List, Optional

import numpy as np

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Vision framework (lazy import — only imported when used)
# ---------------------------------------------------------------------------

_Vision = None
_objc = None


def _ensure_vision():
    global _Vision, _objc
    if _Vision is None:
        import Vision as _V
        import objc as _o
        _Vision = _V
        _objc = _o
    return _Vision, _objc


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


class VisionTextResult:
    """Single text region detected by Vision."""
    __slots__ = ('text', 'confidence', 'bbox')

    def __init__(self, text: str, confidence: float, bbox: tuple):
        self.text = text
        self.confidence = confidence
        # bbox: (x, y, width, height) in image pixel coordinates
        self.bbox = bbox


def detect_text(
    image: np.ndarray,
    min_confidence: float = 0.3,
    languages: Optional[List[str]] = None,
) -> List[VisionTextResult]:
    """Detect and recognize text in an image using Apple Vision.

    Args:
        image: RGB numpy array (H, W, 3), uint8.
        min_confidence: Minimum confidence threshold (0.0–1.0).
        languages: Recognition languages, e.g. ['zh-Hans', 'en'].
                   Defaults to ['zh-Hans', 'en'].

    Returns:
        List of VisionTextResult, sorted by reading order (y, then x).
    """
    if languages is None:
        languages = ['zh-Hans', 'en']

    try:
        Vision, objc = _ensure_vision()
        return _detect_via_vision(image, min_confidence, languages, Vision, objc)
    except Exception:
        logger.debug("Vision detection failed, will fall back to PaddleOCR",
                     exc_info=True)
        return []


def is_available() -> bool:
    """Check if Vision framework is available on this system."""
    try:
        _ensure_vision()
        return True
    except ImportError:
        return False


# ---------------------------------------------------------------------------
# Internal
# ---------------------------------------------------------------------------


def _detect_via_vision(
    image: np.ndarray,
    min_confidence: float,
    languages: List[str],
    Vision,
    objc,
) -> List[VisionTextResult]:
    """Core Vision detection using temp-file CIImage (reliable, ~0.3s/page)."""
    h, w = image.shape[:2]

    import tempfile, os
    import fitz

    # Save via fitz pixmap (handles RGB→PNG correctly)
    tmp_path = os.path.join(tempfile.gettempdir(),
                            f'_vision_ocr_{id(image)}.png')
    try:
        # fitz pixmap from numpy is fastest
        pix = fitz.Pixmap(fitz.csRGB, w, h, image.tobytes(), False)
        pix.save(tmp_path)
        pix = None  # free

        nsurl = objc.lookUpClass('NSURL').fileURLWithPath_(tmp_path)
        ci_image = objc.lookUpClass('CIImage').imageWithContentsOfURL_(nsurl)

        handler = Vision.VNImageRequestHandler.alloc().initWithCIImage_options_(
            ci_image, None
        )

        request = Vision.VNRecognizeTextRequest.alloc().init()
        request.setRecognitionLevel_(
            Vision.VNRequestTextRecognitionLevelAccurate
        )
        request.setRecognitionLanguages_(languages)
        request.setUsesLanguageCorrection_(True)

        success, error = handler.performRequests_error_([request], None)

        if not success:
            logger.warning(f"Vision request failed: {error}")
            return []

        results = []
        for obs in request.results():
            candidate = obs.topCandidates_(1)[0]
            conf = candidate.confidence()
            if conf < min_confidence:
                continue

            text = candidate.string()
            if not text or not text.strip():
                continue

            # Bounding box: normalized [0,1] → pixel coordinates
            bbox = obs.boundingBox()
            # Vision uses bottom-left origin; convert to top-left
            x = bbox.origin.x * w
            y = (1.0 - bbox.origin.y - bbox.size.height) * h
            bw = bbox.size.width * w
            bh = bbox.size.height * h

            results.append(VisionTextResult(
                text=text.strip(),
                confidence=float(conf),
                bbox=(x, y, bw, bh),
            ))

        # Sort by reading order: y descending (Vision coords), then x ascending
        results.sort(key=lambda r: (r.bbox[1], r.bbox[0]))
        return results

    finally:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass


def detect_text_simple(image: np.ndarray, min_confidence: float = 0.3) -> str:
    """Detect text and return as a single newline-joined string.

    Convenience wrapper for pipeline use. Filters single-character noise
    (Vision produces many low-confidence single-char artifacts on scans).
    Multi-char strings at low confidence are kept — they're usually real
    text (e.g., decorative English labels).
    """
    regions = detect_text(image, min_confidence=min_confidence)
    if not regions:
        return ""

    filtered = []
    for r in regions:
        # Single-char: only keep if Vision is very confident
        if len(r.text) == 1 and r.confidence < 0.8:
            continue
        filtered.append(r.text)

    return "\n".join(filtered)


def detect_text_with_confidence(image: np.ndarray, min_confidence: float = 0.3) -> tuple:
    """Detect text and return (text, avg_confidence, low_ratio).

    Returns:
        text: joined recognized text lines
        avg_confidence: mean confidence across filtered regions
        low_ratio: fraction of regions with confidence < 0.5 (0.0–1.0)

    low_ratio > 0.2 suggests poor quality → PaddleOCR fallback recommended.
    """
    regions = detect_text(image, min_confidence=min_confidence)
    if not regions:
        return "", 0.0, 0.0

    confidences = []
    filtered = []
    for r in regions:
        if len(r.text) == 1 and r.confidence < 0.8:
            continue
        filtered.append(r.text)
        confidences.append(r.confidence)

    avg_conf = sum(confidences) / len(confidences) if confidences else 0.0
    low_count = sum(1 for c in confidences if c < 0.5)
    low_ratio = low_count / len(confidences) if confidences else 0.0
    return "\n".join(filtered), avg_conf, low_ratio


# ---------------------------------------------------------------------------
# Page classification via Vision spatial + text analysis
# ---------------------------------------------------------------------------


def classify_page(image: np.ndarray) -> dict:
    """Classify a page as TEXT, OCR, TABLE, or FORMULA using Vision output.

    Runs Vision detect+recognize on the image, then analyzes text density,
    CJK ratio, character fragmentation, and spatial grid patterns to
    determine the page type.

    Args:
        image: RGB numpy array (H, W, 3), uint8.

    Returns:
        dict with keys:
          - group: 'text', 'ocr', 'table', 'formula', or 'all'
          - avg_chars_per_region: float
          - cjk_ratio: float (0.0–1.0)
          - grid_score: float (0.0–1.0)
          - total_regions: int
          - table_bbox: (x, y, w, h) or None — best-guess table region
          - regions: list of VisionTextResult
    """
    regions = detect_text(image, min_confidence=0.3)
    total_regions = len(regions)

    # Scanned / blank page
    if total_regions == 0:
        return {
            'group': 'ocr', 'avg_chars_per_region': 0, 'cjk_ratio': 0,
            'grid_score': 0, 'total_regions': 0,
            'table_bbox': None, 'regions': [],
        }

    full_text = ''.join(r.text for r in regions)
    total_chars = max(len(full_text), 1)

    # CJK ratio
    cjk_count = sum(1 for c in full_text if '一' <= c <= '鿿')
    cjk_ratio = cjk_count / total_chars

    # Average chars per region (formula pages have many tiny fragments)
    avg_chars = total_chars / total_regions

    # Grid score: column-aligned text regions → table indicator
    bboxes = [(r.bbox[0], r.bbox[1], r.bbox[2], r.bbox[3]) for r in regions]

    grid_score = 0.0
    table_bbox = None
    if total_regions >= 6:
        # X-position clustering: count distinct columns with >=3 regions
        xs = [round(b[0], 2) for b in bboxes]
        from collections import Counter
        x_counts = Counter(xs)
        aligned_cols = sum(1 for c in x_counts.values() if c >= 3)
        grid_score = aligned_cols / max(len(x_counts), 1)

        # Find table region: largest cluster of aligned regions
        if grid_score > 0.3:
            table_xs = [x for x, c in x_counts.items() if c >= 3]
            if table_xs:
                table_regions = [b for b in bboxes if round(b[0], 2) in table_xs]
                if table_regions:
                    min_x = min(b[0] for b in table_regions)
                    min_y = min(b[1] for b in table_regions)
                    max_x = max(b[0] + b[2] for b in table_regions)
                    max_y = max(b[1] + b[3] for b in table_regions)
                    table_bbox = (min_x, min_y, max_x - min_x, max_y - min_y)

    # Classification rules
    if avg_chars < 12 and cjk_ratio < 0.6 and total_regions > 15:
        group = 'formula'
    elif grid_score > 0.5 and total_regions > 10:
        group = 'table'
    else:
        group = 'text'

    return {
        'group': group,
        'avg_chars_per_region': avg_chars,
        'cjk_ratio': cjk_ratio,
        'grid_score': grid_score,
        'total_regions': total_regions,
        'table_bbox': table_bbox,
        'regions': regions,
    }
