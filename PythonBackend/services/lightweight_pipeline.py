"""
Lightweight OCR pipeline — bypasses magic-pdf CustomPEKModel.

Key design:
- Models loaded on demand (not all at startup)
- LayoutLMv3 runs first on all pages → block classification
- Text pages with embedded text → direct fitz text extraction (no OCR)
- Table/formula pages → load only needed models → process → release
- MPS cache cleaned after each batch
- Progressive output: pages streamed as they complete

Bypasses: CustomPEKModel.__init__ (forces OCR load), BatchAnalyze.__call__
Uses: AtomModelSingleton.get_atom_model() directly for on-demand loading.
"""

import gc
import logging
import os
import time
from dataclasses import dataclass, field
from enum import Enum
from typing import Callable, Optional

import cv2
import fitz
import numpy as np
import torch

from magic_pdf.config.constants import MODEL_NAME
from magic_pdf.model.model_list import AtomicModel
from magic_pdf.model.sub_modules.model_init import AtomModelSingleton
from magic_pdf.model.sub_modules.model_utils import crop_img

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

EMBEDDED_TEXT_MIN_CHARS = 1  # any embedded text → TEXT (not scanned)
Y_TOLERANCE = 10  # px, same-row tolerance for reading order

# LayoutLMv3 category IDs (from doclayout_yolo dataset labels)
CAT_TEXT = {0, 1, 2, 3, 6}  # 1=text, 2=title, 3=caption; 0,6 seen on scans
CAT_TABLE = {5}              # 5=table
CAT_FORMULA = {7, 8}         # 7=isolated formula, 8=inline formula
CAT_IMAGE = {4}              # 4=image


class PageGroup(Enum):
    TEXT = "text"
    OCR = "ocr"
    TABLE = "table"
    FORMULA = "formula"
    ALL = "all"


# ---------------------------------------------------------------------------
# Data structures
# ---------------------------------------------------------------------------

@dataclass
class PageResult:
    page_no: int
    group: PageGroup
    layout_blocks: list = field(default_factory=list)
    image: Optional[np.ndarray] = None
    markdown: str = ""


@dataclass
class PipelineProgress:
    phase: str = ""
    current: int = 0
    total: int = 0
    message: str = ""
    content: str = ""       # latest completed page markdown
    page_no: int = -1       # page number of latest content (0-based)


ProgressCallback = Callable[[PipelineProgress], None]

# ---------------------------------------------------------------------------
# Model path resolution (computed once, cached)
# ---------------------------------------------------------------------------

_model_paths = None


def _get_model_paths() -> dict:
    global _model_paths
    if _model_paths is not None:
        return _model_paths

    from magic_pdf.libs.config_reader import get_local_models_dir
    models_dir = get_local_models_dir()

    # model_config directory relative to magic_pdf package
    import magic_pdf
    magic_pdf_root = os.path.dirname(magic_pdf.__file__)
    model_config_dir = os.path.join(magic_pdf_root, 'resources', 'model_config')

    _model_paths = {
        'models_dir': models_dir,
        'model_config_dir': model_config_dir,
        'layout_weights': os.path.join(models_dir, 'Layout', 'LayoutLMv3', 'model_final.pth'),
        'layout_config': os.path.join(model_config_dir, 'layoutlmv3', 'layoutlmv3_base_inference.yaml'),
        'mfd_weights': os.path.join(models_dir, 'MFD', 'YOLO', 'yolo_v8_ft.pt'),
        'mfr_weight_dir': os.path.join(models_dir, 'MFR', 'unimernet_hf_small_2503'),
        'mfr_cfg_path': os.path.join(model_config_dir, 'UniMERNet', 'demo.yaml'),
    }
    return _model_paths


# ---------------------------------------------------------------------------
# Reading order: sort blocks by (y_top, x_left), multi-column aware
# ---------------------------------------------------------------------------

def sort_blocks_reading_order(blocks: list) -> list:
    """Sort blocks by reading order: top-to-bottom, left-to-right within row."""
    if len(blocks) <= 1:
        return blocks

    sorted_blocks = sorted(blocks, key=lambda b: (b['poly'][1], b['poly'][0]))

    ordered = []
    row = [sorted_blocks[0]]
    for b in sorted_blocks[1:]:
        if abs(b['poly'][1] - row[0]['poly'][1]) < Y_TOLERANCE:
            row.append(b)
        else:
            ordered.extend(sorted(row, key=lambda x: x['poly'][0]))
            row = [b]
    ordered.extend(sorted(row, key=lambda x: x['poly'][0]))
    return ordered


# ---------------------------------------------------------------------------
# Model release
# ---------------------------------------------------------------------------

def release_atom_model(atom_model_name: str, **keys) -> bool:
    """Remove a model from AtomModelSingleton cache and free memory.

    Returns True if a model was actually released.
    """
    manager = AtomModelSingleton()

    if atom_model_name == 'layout':
        key = (atom_model_name, keys.get('layout_model_name'))
    elif atom_model_name == 'table':
        key = (atom_model_name, keys.get('table_model_name'), keys.get('lang'))
    else:
        key = atom_model_name

    if key in manager._models:
        model = manager._models.pop(key)
        del model
        gc.collect()
        if torch.backends.mps.is_available():
            torch.mps.empty_cache()
        return True
    return False


def cleanup_mps():
    """Force MPS cache cleanup + Python GC."""
    gc.collect()
    if torch.backends.mps.is_available():
        torch.mps.empty_cache()


# ---------------------------------------------------------------------------
# LightweightPipeline
# ---------------------------------------------------------------------------

class LightweightPipeline:
    """Progressive OCR pipeline with on-demand model loading."""

    def __init__(self, lang: Optional[str] = None):
        self.lang = lang
        self._models_loaded: set = set()
        self._manager = AtomModelSingleton()
        self._device = self._resolve_device()

    # ── device ────────────────────────────────────────────────────────

    def _resolve_device(self) -> str:
        from magic_pdf.libs.config_reader import get_device
        return str(get_device())

    # ── model loading (on-demand, via AtomModelSingleton) ──────────────

    def _ensure_layout_model(self):
        if 'layout' in self._models_loaded:
            return self._manager.get_atom_model(
                atom_model_name=AtomicModel.Layout,
                layout_model_name=MODEL_NAME.LAYOUTLMv3,
            )

        paths = _get_model_paths()
        # LayoutLMv3 on MPS → force CPU (detectron2 MPS support is poor)
        layout_device = 'cpu' if self._device.startswith("mps") else self._device

        logger.info(f"Loading LayoutLMv3 on {layout_device}...")
        t0 = time.time()
        model = self._manager.get_atom_model(
            atom_model_name=AtomicModel.Layout,
            layout_model_name=MODEL_NAME.LAYOUTLMv3,
            layout_weights=paths['layout_weights'],
            layout_config_file=paths['layout_config'],
            device=layout_device,
        )
        self._models_loaded.add('layout')
        logger.info(f"LayoutLMv3 loaded in {time.time() - t0:.1f}s")
        return model

    def _ensure_mfd_model(self):
        if 'mfd' in self._models_loaded:
            return self._manager.get_atom_model(atom_model_name=AtomicModel.MFD)

        paths = _get_model_paths()
        logger.info("Loading MFD (YOLOv8 formula detection)...")
        t0 = time.time()
        model = self._manager.get_atom_model(
            atom_model_name=AtomicModel.MFD,
            mfd_weights=paths['mfd_weights'],
            device=self._device,
        )
        self._models_loaded.add('mfd')
        logger.info(f"MFD loaded in {time.time() - t0:.1f}s")
        return model

    def _ensure_mfr_model(self):
        if 'mfr' in self._models_loaded:
            return self._manager.get_atom_model(atom_model_name=AtomicModel.MFR)

        paths = _get_model_paths()
        logger.info("Loading MFR (Unimernet formula recognition)...")
        t0 = time.time()
        model = self._manager.get_atom_model(
            atom_model_name=AtomicModel.MFR,
            mfr_weight_dir=paths['mfr_weight_dir'],
            mfr_cfg_path=paths['mfr_cfg_path'],
            device=self._device,
        )
        self._models_loaded.add('mfr')
        logger.info(f"MFR loaded in {time.time() - t0:.1f}s")
        return model

    def _ensure_table_model(self):
        if 'table' in self._models_loaded:
            return self._manager.get_atom_model(
                atom_model_name=AtomicModel.Table,
                table_model_name=MODEL_NAME.RAPID_TABLE,
                lang=self.lang,
            )

        logger.info("Loading RapidTable...")
        t0 = time.time()
        model = self._manager.get_atom_model(
            atom_model_name=AtomicModel.Table,
            table_model_name=MODEL_NAME.RAPID_TABLE,
            table_model_path='',
            table_max_time=400,
            device='cpu',
            lang=self.lang,
            table_sub_model_name='slanet_plus',
        )
        self._models_loaded.add('table')
        logger.info(f"RapidTable loaded in {time.time() - t0:.1f}s")
        return model

    # ── model release ─────────────────────────────────────────────────

    def _release_model(self, name: str):
        if name not in self._models_loaded:
            return

        if name == 'layout':
            release_atom_model('layout', layout_model_name=MODEL_NAME.LAYOUTLMv3)
        elif name == 'mfd':
            release_atom_model('mfd')
        elif name == 'mfr':
            release_atom_model('mfr')
        elif name == 'table':
            release_atom_model('table', table_model_name=MODEL_NAME.RAPID_TABLE, lang=self.lang)

        self._models_loaded.discard(name)

    # ── PDF rendering ─────────────────────────────────────────────────

    def _render_page(self, fitz_doc: fitz.Document, page_no: int) -> np.ndarray:
        """Render single PDF page at 200 DPI (matching magic-pdf's default)."""
        page = fitz_doc[page_no]
        mat = fitz.Matrix(200 / 72, 200 / 72)
        pix = page.get_pixmap(matrix=mat, alpha=False)

        # Magic-pdf clamps to 4500px — match that
        if pix.width > 4500 or pix.height > 4500:
            pix = page.get_pixmap(matrix=fitz.Matrix(1.0, 1.0), alpha=False)

        img = np.frombuffer(pix.samples, dtype=np.uint8).reshape(pix.height, pix.width, 3)
        return img

    # ── page classification ───────────────────────────────────────────

    # ── block deduplication ───────────────────────────────────────────

    @staticmethod
    def _block_iou(a: dict, b: dict) -> float:
        """Intersection over Union of two block bounding boxes."""
        x1 = max(a['poly'][0], b['poly'][0])
        y1 = max(a['poly'][1], b['poly'][1])
        x2 = min(a['poly'][4], b['poly'][4])
        y2 = min(a['poly'][5], b['poly'][5])
        if x2 <= x1 or y2 <= y1:
            return 0.0
        inter = (x2 - x1) * (y2 - y1)
        area_a = (a['poly'][4] - a['poly'][0]) * (a['poly'][5] - a['poly'][1])
        area_b = (b['poly'][4] - b['poly'][0]) * (b['poly'][5] - b['poly'][1])
        union = area_a + area_b - inter
        return inter / union if union > 0 else 0.0

    def _deduplicate_blocks(self, blocks: list, min_score: float = 0.5,
                            iou_threshold: float = 0.6) -> list:
        """Remove low-confidence and overlapping blocks via score filter + NMS."""
        filtered = [b for b in blocks if b.get('score', 0) >= min_score]
        if not filtered:
            return blocks

        filtered.sort(key=lambda b: b.get('score', 0), reverse=True)
        kept = []
        for b in filtered:
            if not any(self._block_iou(b, k) > iou_threshold for k in kept):
                kept.append(b)
        return kept

    # ── per-block processing ──────────────────────────────────────────

    def _extract_text_block(self, block: dict, fitz_page: fitz.Page) -> str:
        """Extract text from a single text block using fitz.

        LayoutLMv3 coordinates are in 200 DPI image space.
        fitz uses PDF points (72 DPI). Conversion: pdf = img * (72/200).
        """
        # Scale factor from 200 DPI image coords to PDF points
        scale = 72.0 / 200.0
        poly = block['poly']
        x0, y0 = poly[0] * scale, poly[1] * scale
        x2, y2 = poly[4] * scale, poly[5] * scale
        rect = fitz.Rect(x0, y0, x2, y2)
        text = fitz_page.get_text('text', clip=rect).strip()
        return text

    def _ocr_full_page(self, page_image: np.ndarray) -> str:
        """OCR a scanned page using Apple Vision."""
        try:
            from .vision_text_detector import detect_text_simple
            return detect_text_simple(page_image, min_confidence=0.3)
        except Exception:
            logger.exception("Vision OCR failed")
            return ""

    # ── table / formula page processing ────────────────────────────────

    # ── table / formula page processing ────────────────────────────────

    def _process_table_page(self, image: np.ndarray) -> str:
        """Process a full page image as a table → HTML via RapidTable."""
        try:
            table_model = self._ensure_table_model()
            image_bgr = cv2.cvtColor(image, cv2.COLOR_RGB2BGR)
            html, _, _, _ = table_model.predict(image_bgr)
            if html and (html.strip().endswith('</html>') or html.strip().endswith('</table>')):
                return html
            return "[TABLE]"
        except Exception:
            logger.exception("Table page processing failed")
            return "[TABLE]"

    def _process_formula_page(self, image: np.ndarray) -> str:
        """Process a full page image for formulas via MFD + MFR → LaTeX."""
        try:
            mfd_model = self._ensure_mfd_model()
            mfr_model = self._ensure_mfr_model()
            image_bgr = cv2.cvtColor(image, cv2.COLOR_RGB2BGR)

            mfd_res = mfd_model.predict(image_bgr)
            if not mfd_res:
                return ""

            mfr_list = mfr_model.predict(mfd_res, image_bgr)
            parts = []
            for r in mfr_list:
                text = r.get('text', '') if isinstance(r, dict) else str(r)
                if text:
                    parts.append(f"$$\n{text}\n$$")
            return "\n\n".join(parts) if parts else "[FORMULA]"
        except Exception:
            logger.exception("Formula page processing failed")
            return "[FORMULA]"

    def _process_table_block(self, block: dict, page_image: np.ndarray) -> Optional[str]:
        """Recognize a single table block → HTML."""
        try:
            table_model = self._ensure_table_model()
            new_image, _ = crop_img(block, page_image)
            html, _, _, _ = table_model.predict(new_image)
            if html and (html.strip().endswith('</html>') or html.strip().endswith('</table>')):
                return html
            else:
                logger.warning("Table recognition returned incomplete HTML")
                return None
        except Exception:
            logger.exception("Table recognition failed")
            return None

    def _process_single_page(
        self, page_result: PageResult, fitz_page: fitz.Page
    ) -> str:
        """Process one page: text + table + formula blocks → markdown (reading order)."""
        blocks = page_result.layout_blocks
        if not blocks:
            return ""

        # OCR pages: use Vision on the full page
        if page_result.group == PageGroup.OCR:
            return self._ocr_full_page(page_result.image)

        # Non-OCR pages: deduplicate blocks + category-based routing
        blocks = self._deduplicate_blocks(blocks)
        ordered = sort_blocks_reading_order(blocks)

        # Non-OCR pages: category-based routing
        formula_results = {}
        formula_blocks = [b for b in ordered if int(b['category_id']) in CAT_FORMULA]
        if formula_blocks and page_result.image is not None:
            try:
                mfd_model = self._ensure_mfd_model()
                mfr_model = self._ensure_mfr_model()
                mfd_res = mfd_model.predict(page_result.image)
                mfr_list = mfr_model.predict(mfd_res, page_result.image)
                formula_results = self._match_formulas_to_blocks(formula_blocks, mfr_list)
            except Exception:
                logger.exception("Formula batch processing failed")

        parts = []
        for b in ordered:
            cat = int(b['category_id'])

            if cat in CAT_TEXT:
                text = self._extract_text_block(b, fitz_page)
                if text:
                    parts.append(text)

            elif cat in CAT_TABLE:
                if page_result.image is not None:
                    html = self._process_table_block(b, page_result.image)
                    parts.append(html if html else "[TABLE]")

            elif cat in CAT_FORMULA:
                latex = formula_results.get(id(b), '')
                parts.append(f"$$\n{latex}\n$$" if latex else "[FORMULA]")

            elif cat in CAT_IMAGE:
                parts.append("[IMAGE]")

        return "\n\n".join(parts)

    @staticmethod
    def _match_formulas_to_blocks(formula_blocks: list, mfr_results: list) -> dict:
        """Match MFR results to formula blocks by bounding box proximity."""
        matched = {}
        mfr_items = [r for r in mfr_results if 'poly' in r and 'text' in r]

        for fb in formula_blocks:
            fb_x = (fb['poly'][0] + fb['poly'][4]) / 2
            fb_y = (fb['poly'][1] + fb['poly'][5]) / 2

            best_dist = float('inf')
            best_text = ''
            for m in mfr_items:
                mx = (m['poly'][0] + m['poly'][4]) / 2
                my = (m['poly'][1] + m['poly'][5]) / 2
                dist = abs(fb_x - mx) + abs(fb_y - my)
                if dist < best_dist:
                    best_dist = dist
                    best_text = m['text']

            if best_text and best_dist < 500:
                matched[id(fb)] = best_text

        return matched

    # ── document-level preflight ──────────────────────────────────────

    PREFLIGHT_SAMPLE = 5       # pages to sample for embedded-text check
    PREFLIGHT_VISION_SAMPLE = 3  # pages to sample for table/formula check

    def _preflight(self, fitz_doc: fitz.Document) -> dict:
        """Sample first few pages to determine document type.

        A PDF is almost always uniformly scanned or text-based, not mixed.
        We sample a few pages instead of classifying every page.

        Returns dict with:
          - doc_type: 'scanned' | 'text' | 'table' | 'formula'
          - needs_table: bool
          - needs_formula: bool
        """
        total_pages = fitz_doc.page_count
        sample_size = min(self.PREFLIGHT_SAMPLE, total_pages)

        # Step 1: fitz check — any embedded text?
        embedded_pages = []
        for p_no in range(sample_size):
            if len(fitz_doc[p_no].get_text().strip()) > EMBEDDED_TEXT_MIN_CHARS:
                embedded_pages.append(p_no)

        if not embedded_pages:
            return {'doc_type': 'scanned', 'needs_table': False, 'needs_formula': False}

        # Step 2: Vision classify a few embedded-text pages for table/formula
        from .vision_text_detector import classify_page

        has_table = False
        has_formula = False
        vision_count = min(self.PREFLIGHT_VISION_SAMPLE, len(embedded_pages))

        for p_no in embedded_pages[:vision_count]:
            try:
                img = self._render_page(fitz_doc, p_no)
                result = classify_page(img)
                if result['group'] == 'table':
                    has_table = True
                elif result['group'] == 'formula':
                    has_formula = True
            except Exception:
                logger.debug(f"Vision preflight failed for page {p_no+1}",
                             exc_info=True)

        if has_table and has_formula:
            return {'doc_type': 'all', 'needs_table': True, 'needs_formula': True}
        elif has_table:
            return {'doc_type': 'table', 'needs_table': True, 'needs_formula': False}
        elif has_formula:
            return {'doc_type': 'formula', 'needs_table': False, 'needs_formula': True}
        else:
            return {'doc_type': 'text', 'needs_table': False, 'needs_formula': False}

    # ── main pipeline ─────────────────────────────────────────────────

    def process(
        self,
        pdf_path: str,
        output_dir: str,
        progress_callback: Optional[ProgressCallback] = None,
    ) -> str:
        """Run pipeline with document-level preflight.

        Samples first few pages to determine document type, then processes
        all pages uniformly — no per-page classification needed since PDFs
        are almost always uniformly scanned or text-based.
        """
        t_total = time.time()
        fitz_doc = fitz.open(pdf_path)
        total_pages = fitz_doc.page_count
        os.makedirs(output_dir, exist_ok=True)

        logger.info(f"Starting pipeline: {total_pages} pages")

        # ── Preflight: determine document type ────────────────────────
        doc_info = self._preflight(fitz_doc)
        doc_type = doc_info['doc_type']
        logger.info(f"Preflight: doc_type={doc_type}")

        self._notify(progress_callback, PipelineProgress(
            phase="preflight", current=0, total=total_pages,
            message=f"Document type: {doc_type}"
        ))

        # ── Load models if needed ─────────────────────────────────────
        if doc_info['needs_table']:
            self._ensure_table_model()
        if doc_info['needs_formula']:
            self._ensure_mfd_model()
            self._ensure_mfr_model()

        # ── Process all pages (with adaptive mode switch) ─────────────
        page_results: dict[int, PageResult] = {}
        fallback_streak = 0  # consecutive pages where model found nothing

        for p_no in range(total_pages):
            self._notify(progress_callback, PipelineProgress(
                phase=doc_type, current=p_no + 1, total=total_pages,
                message=f"Page {p_no+1}/{total_pages}"
            ))

            try:
                if doc_type == 'scanned':
                    img = self._render_page(fitz_doc, p_no)
                    markdown = self._ocr_full_page(img)

                elif doc_type == 'table':
                    img = self._render_page(fitz_doc, p_no)
                    markdown = self._process_table_page(img)
                    if not markdown or markdown == '[TABLE]':
                        markdown = fitz_doc[p_no].get_text('text').strip()
                        markdown = '\n'.join(l for l in markdown.split('\n') if l.strip())
                        fallback_streak += 1
                    else:
                        fallback_streak = 0
                    if fallback_streak >= 3:
                        doc_type = 'text'

                elif doc_type == 'formula':
                    img = self._render_page(fitz_doc, p_no)
                    markdown = self._process_formula_page(img)
                    if not markdown or markdown == '[FORMULA]':
                        markdown = fitz_doc[p_no].get_text('text').strip()
                        markdown = '\n'.join(l for l in markdown.split('\n') if l.strip())
                        fallback_streak += 1
                    else:
                        fallback_streak = 0
                    if fallback_streak >= 3:
                        doc_type = 'text'

                else:  # text
                    markdown = fitz_doc[p_no].get_text('text').strip()
                    markdown = '\n'.join(
                        l for l in markdown.split('\n') if l.strip()
                    )

            except Exception:
                logger.exception(f"Failed page {p_no+1}")
                markdown = f"[PAGE {p_no+1}: processing failed]"

            page_results[p_no] = PageResult(
                page_no=p_no, group=PageGroup.TEXT, markdown=markdown,
            )
            self._notify(progress_callback, PipelineProgress(
                phase=doc_type, current=p_no + 1, total=total_pages,
                message=f"Page {p_no+1}/{total_pages}",
                content=markdown, page_no=p_no,
            ))
        self._notify(progress_callback, PipelineProgress(
            phase="merge", current=0, total=total_pages,
            message="Merging pages..."
        ))

        merged = self._merge_results(page_results, total_pages)
        output_path = os.path.join(output_dir, "output.md")
        with open(output_path, 'w', encoding='utf-8') as f:
            f.write(merged)

        fitz_doc.close()
        cleanup_mps()

        elapsed = time.time() - t_total
        logger.info(f"Pipeline complete: {total_pages} pages in {elapsed:.0f}s")

        self._notify(progress_callback, PipelineProgress(
            phase="done", current=total_pages, total=total_pages,
            message=f"Complete: {total_pages} pages in {elapsed:.0f}s"
        ))

        return output_path

    # ── merge ─────────────────────────────────────────────────────────

    @staticmethod
    def _merge_results(page_results: dict, total_pages: int) -> str:
        """Merge all page markdowns in page number order."""
        parts = []
        for p_no in range(total_pages):
            pr = page_results.get(p_no)
            if pr and pr.markdown:
                parts.append(pr.markdown)
        return "\n\n---\n\n".join(parts)

    # ── helpers ───────────────────────────────────────────────────────

    @staticmethod
    def _notify(cb: Optional[ProgressCallback], progress: PipelineProgress):
        if cb:
            try:
                cb(progress)
            except Exception:
                pass
