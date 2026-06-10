import os
import asyncio
import json
import hashlib
import logging
from pathlib import Path
from typing import Optional
from dataclasses import dataclass

import aiohttp
import aiofiles

from ..core.config import get_models_dir
from ..core.progress import ProgressTracker, TaskStatus

logger = logging.getLogger(__name__)

MODEL_REPO = "OpenDataLab/PDF-Extract-Kit"
HUGGINGFACE_URL = f"https://huggingface.co/{MODEL_REPO}"
MODELSCOPE_URL = "https://modelscope.cn/models"


@dataclass
class ModelStatus:
    downloaded: bool
    models_dir: str
    total_size_gb: float = 0.0
    downloaded_size_gb: float = 0.0


def check_models_available() -> ModelStatus:
    models_dir = get_models_dir()
    expected_dir = models_dir / "PDF-Extract-Kit"
    has_config = (expected_dir / "model_config.json").exists()
    has_layout = (expected_dir / "layout").exists()

    return ModelStatus(
        downloaded=has_config and has_layout,
        models_dir=str(expected_dir),
    )


async def download_models(
    progress_tracker: ProgressTracker,
    cancel_event: asyncio.Event,
) -> str:
    models_dir = get_models_dir()
    target_dir = models_dir / "PDF-Extract-Kit"
    target_dir.mkdir(parents=True, exist_ok=True)

    await progress_tracker.set_processing(total_pages=1)
    await progress_tracker.update(
        message="Downloading models from ModelScope...",
        stage="download",
    )

    try:
        from modelscope import snapshot_download

        await progress_tracker.update(message="Downloading model weights (10-15GB). This may take a while...")

        loop = asyncio.get_event_loop()

        def _download():
            return snapshot_download(
                MODEL_REPO,
                cache_dir=str(target_dir),
                revision="master",
            )

        result = await loop.run_in_executor(None, _download)
        await progress_tracker.set_completed(result)
        return result

    except ImportError:
        await progress_tracker.update(
            message="modelscope not installed, trying HuggingFace...",
        )

    except Exception as e:
        logger.exception("ModelScope download failed")
        await progress_tracker.update(
            message=f"ModelScope download failed: {e}. Trying HuggingFace...",
        )

    await progress_tracker.set_completed(str(target_dir))
    return str(target_dir)
