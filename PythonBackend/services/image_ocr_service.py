import os
import asyncio
import tempfile
from pathlib import Path
from typing import Optional
import logging

from PIL import Image
import img2pdf

from .pdf_ocr_service import process_pdf
from ..core.progress import ProgressTracker
from ..core.config import get_cache_dir

logger = logging.getLogger(__name__)

SUPPORTED_IMAGE_EXTS = {".png", ".jpg", ".jpeg", ".tiff", ".tif", ".bmp", ".heic", ".webp"}


def is_supported_image(file_path: str) -> bool:
    ext = Path(file_path).suffix.lower()
    return ext in SUPPORTED_IMAGE_EXTS


async def process_image(
    image_path: str,
    task_id: str,
    progress_tracker: ProgressTracker,
    cancel_event: asyncio.Event,
) -> str:
    temp_dir = os.path.join(str(get_cache_dir()), task_id, "tmp")
    os.makedirs(temp_dir, exist_ok=True)

    img = Image.open(image_path)
    if img.mode in ("RGBA", "P", "LA"):
        img = img.convert("RGB")

    pdf_path = os.path.join(temp_dir, "page.pdf")
    with open(pdf_path, "wb") as f:
        f.write(img2pdf.convert(image_path))

    await progress_tracker.set_processing(total_pages=1)

    result_path = await process_pdf(pdf_path, task_id, progress_tracker, cancel_event)

    return result_path
