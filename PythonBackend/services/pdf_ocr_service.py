import gc
import os
import asyncio
import logging
from concurrent.futures import ThreadPoolExecutor

import fitz

from ..core.progress import ProgressTracker
from ..core.config import load_or_create_config, get_cache_dir
from ..core.exceptions import OCRProcessingError
from .lightweight_pipeline import LightweightPipeline, PipelineProgress

logger = logging.getLogger(__name__)

WARNING_PAGE_COUNT = 50
_ocr_executor = ThreadPoolExecutor(max_workers=1)


class LargeFileWarning(Exception):
    def __init__(self, page_count: int):
        self.page_count = page_count
        super().__init__(f"Large PDF: {page_count} pages")


def _get_page_count(pdf_bytes: bytes) -> int:
    doc = fitz.open(stream=pdf_bytes, filetype="pdf")
    count = doc.page_count
    doc.close()
    return count


async def process_pdf(
    pdf_path: str,
    task_id: str,
    progress_tracker: ProgressTracker,
    cancel_event: asyncio.Event,
    method: str = "auto",
    confirmed: bool = False,
) -> str:
    """Process a PDF using the lightweight progressive pipeline.

    Phase 1: LayoutLMv3 layout analysis on all pages (batched, MPS cleaned)
    Phase 2: Process pages by group (text → table → formula → all)
    Phase 3: Merge by page number
    """
    output_dir = os.path.join(str(get_cache_dir()), task_id)
    os.makedirs(output_dir, exist_ok=True)

    with open(pdf_path, "rb") as f:
        pdf_bytes = f.read()

    page_count = _get_page_count(pdf_bytes)
    del pdf_bytes

    if page_count > WARNING_PAGE_COUNT and not confirmed:
        raise LargeFileWarning(page_count)

    config = load_or_create_config()
    lang = config.get("lang")

    await progress_tracker.set_processing(total_pages=page_count)

    loop = asyncio.get_event_loop()

    def on_progress(pp: PipelineProgress):
        """Bridge from sync pipeline callback to ProgressTracker."""
        pct = (pp.current / max(pp.total, 1)) * 100 if pp.total > 0 else 0
        pt = progress_tracker._latest
        pt.progress = pct
        pt.current_page = pp.current
        pt.total_pages = pp.total
        pt.stage = pp.phase
        pt.message = pp.message
        if pp.content:
            pt.completed_pages = pp.page_no + 1 if pp.page_no >= 0 else pt.completed_pages + 1
            pt.latest_content = pp.content

    def run_pipeline():
        pipeline = LightweightPipeline(lang=lang)
        return pipeline.process(pdf_path, output_dir, progress_callback=on_progress)

    try:
        md_path = await loop.run_in_executor(_ocr_executor, run_pipeline)
    except asyncio.CancelledError:
        await progress_tracker.set_cancelled()
        raise

    await progress_tracker.set_completed(md_path)
    return md_path
