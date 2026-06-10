import asyncio
import uuid
from dataclasses import dataclass, field  # noqa: F811
from enum import Enum
from typing import Callable, Optional


class TaskStatus(str, Enum):
    PENDING = "pending"
    PROCESSING = "processing"
    COMPLETED = "completed"
    FAILED = "failed"
    CANCELLED = "cancelled"


class ProcessingStage(str, Enum):
    LAYOUT_DETECTION = "layout_detection"
    FORMULA_RECOGNITION = "formula_recognition"
    TABLE_PARSING = "table_parsing"
    TEXT_EXTRACTION = "text_extraction"
    EXPORT = "export"


@dataclass
class ProgressUpdate:
    task_id: str
    status: TaskStatus
    progress: float = 0.0
    current_page: int = 0
    total_pages: int = 0
    stage: Optional[str] = None
    message: str = ""
    error: Optional[str] = None
    completed_pages: int = 0
    latest_content: str = ""

    def to_dict(self) -> dict:
        return {
            "task_id": self.task_id,
            "status": self.status.value,
            "progress": self.progress,
            "current_page": self.current_page,
            "total_pages": self.total_pages,
            "stage": self.stage,
            "message": self.message,
            "error": self.error,
            "completed_pages": self.completed_pages,
            "latest_content": self.latest_content,
        }


class ProgressTracker:
    def __init__(self, task_id: str):
        self.task_id = task_id
        self._callbacks: list[Callable] = []
        self._latest = ProgressUpdate(
            task_id=task_id,
            status=TaskStatus.PENDING,
        )

    @property
    def latest(self) -> ProgressUpdate:
        return self._latest

    def on_update(self, callback: Callable):
        self._callbacks.append(callback)

    async def _notify(self):
        for cb in self._callbacks:
            try:
                if asyncio.iscoroutinefunction(cb):
                    await cb(self._latest)
                else:
                    cb(self._latest)
            except Exception:
                pass

    async def update(self, **kwargs):
        for k, v in kwargs.items():
            if hasattr(self._latest, k):
                setattr(self._latest, k, v)
        await self._notify()

    async def set_processing(self, total_pages: int):
        await self.update(
            status=TaskStatus.PROCESSING,
            progress=0.0,
            total_pages=total_pages,
            current_page=0,
            stage=ProcessingStage.LAYOUT_DETECTION.value,
            message=f"Starting OCR on {total_pages} pages...",
        )

    async def set_page_progress(self, current: int, stage: str):
        progress = (current / max(self._latest.total_pages, 1)) * 100
        await self.update(
            progress=progress,
            current_page=current,
            stage=stage,
            message=f"Processing page {current}/{self._latest.total_pages} - {stage}",
        )

    async def set_completed(self, output_path: str):
        await self.update(
            status=TaskStatus.COMPLETED,
            progress=100.0,
            current_page=self._latest.total_pages,
            message=f"OCR complete. Output: {output_path}",
        )

    async def set_failed(self, error: str):
        await self.update(
            status=TaskStatus.FAILED,
            error=error,
            message=f"OCR failed: {error}",
        )

    async def set_cancelled(self):
        await self.update(
            status=TaskStatus.CANCELLED,
            message="OCR cancelled by user",
        )
