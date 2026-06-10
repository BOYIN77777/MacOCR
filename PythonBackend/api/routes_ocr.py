import os
import asyncio
import logging
from pathlib import Path
from fastapi import APIRouter, UploadFile, File, HTTPException, Depends, Request
from fastapi.responses import JSONResponse

from ..services.pdf_ocr_service import process_pdf, LargeFileWarning
from ..services.image_ocr_service import process_image, is_supported_image
from ..services.task_manager import task_manager
from ..core.progress import TaskStatus
from ..core.config import get_cache_dir

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/v1/ocr", tags=["ocr"])

ALLOWED_EXTENSIONS = {".pdf", ".png", ".jpg", ".jpeg", ".tiff", ".tif", ".bmp", ".heic", ".webp"}


def _validate_file(filename: str) -> str:
    ext = Path(filename).suffix.lower()
    if ext not in ALLOWED_EXTENSIONS:
        raise HTTPException(status_code=400, detail=f"Unsupported file type: {ext}")
    return ext


async def _save_upload(upload_file: UploadFile, task_id: str) -> str:
    cache_dir = get_cache_dir()
    task_dir = cache_dir / task_id
    task_dir.mkdir(parents=True, exist_ok=True)

    file_path = task_dir / upload_file.filename
    content = await upload_file.read()
    file_path.write_bytes(content)
    return str(file_path)


@router.post("/upload")
async def upload_and_ocr(request: Request, file: UploadFile = File(...), method: str = "auto", confirmed: bool = False):
    ext = _validate_file(file.filename)
    task_id, progress, cancel_event = task_manager.create_task()

    # Check if another task is already processing (executor has 1 worker)
    current = task_manager.current_task_id
    if current is not None:
        task_manager.remove_task(task_id)
        return JSONResponse(
            status_code=409,
            content={"detail": f"Another task ({current}) is already processing. Please wait or cancel it."},
        )

    task_manager.current_task_id = task_id

    async def _watch_disconnect():
        while not cancel_event.is_set():
            if await request.is_disconnected():
                logger.info(f"Client disconnected for task {task_id}, cancelling")
                task_manager.cancel_task(task_id)
                return
            await asyncio.sleep(0.5)

    disconnect_watcher = asyncio.create_task(_watch_disconnect())

    try:
        file_path = await _save_upload(file, task_id)

        if cancel_event.is_set():
            raise asyncio.CancelledError("Task cancelled")

        if ext == ".pdf":
            result_path = await process_pdf(file_path, task_id, progress, cancel_event, method=method, confirmed=confirmed)
        else:
            result_path = await process_image(file_path, task_id, progress, cancel_event)

        if cancel_event.is_set():
            raise asyncio.CancelledError("Task cancelled")

        with open(result_path, "r", encoding="utf-8") as f:
            markdown_content = f.read()

        return JSONResponse(content={
            "task_id": task_id,
            "status": "completed",
            "output_path": result_path,
            "markdown": markdown_content,
        })

    except asyncio.CancelledError:
        task_manager.remove_task(task_id)
        return JSONResponse(
            status_code=499,
            content={"task_id": task_id, "status": "cancelled"},
        )

    except LargeFileWarning as e:
        task_manager.remove_task(task_id)
        return JSONResponse(
            status_code=422,
            content={
                "detail": f"此文件共 {e.page_count} 页。大文件处理建议关闭其他应用。",
                "page_count": e.page_count,
                "requires_confirmation": True,
            },
        )

    except HTTPException:
        task_manager.remove_task(task_id)
        raise

    except Exception as e:
        task_manager.remove_task(task_id)
        logger.exception(f"OCR failed for task {task_id}")
        raise HTTPException(status_code=500, detail=str(e))

    finally:
        disconnect_watcher.cancel()
        try:
            await disconnect_watcher
        except asyncio.CancelledError:
            pass
        if task_manager.current_task_id == task_id:
            task_manager.current_task_id = None


@router.get("/tasks/{task_id}")
async def get_task_status(task_id: str):
    progress = task_manager.get_task(task_id)
    if progress is None:
        raise HTTPException(status_code=404, detail="Task not found")
    return progress.latest.to_dict()


@router.delete("/tasks/{task_id}")
async def cancel_task(task_id: str):
    cancelled = task_manager.cancel_task(task_id)
    if not cancelled:
        raise HTTPException(status_code=404, detail="Task not found or already completed")
    return {"task_id": task_id, "status": "cancelling"}
