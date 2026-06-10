import asyncio
import uuid
import logging
from typing import Optional

from ..core.progress import ProgressTracker, TaskStatus

logger = logging.getLogger(__name__)


class TaskManager:
    def __init__(self):
        self._tasks: dict[str, ProgressTracker] = {}
        self._cancel_events: dict[str, asyncio.Event] = {}
        self._current_task: Optional[str] = None

    def create_task(self) -> tuple[str, ProgressTracker, asyncio.Event]:
        task_id = str(uuid.uuid4())
        progress = ProgressTracker(task_id)
        cancel_event = asyncio.Event()

        self._tasks[task_id] = progress
        self._cancel_events[task_id] = cancel_event

        return task_id, progress, cancel_event

    def get_task(self, task_id: str) -> Optional[ProgressTracker]:
        return self._tasks.get(task_id)

    def cancel_task(self, task_id: str) -> bool:
        if task_id in self._cancel_events:
            self._cancel_events[task_id].set()
            return True
        return False

    def remove_task(self, task_id: str):
        self._tasks.pop(task_id, None)
        self._cancel_events.pop(task_id, None)
        if self._current_task == task_id:
            self._current_task = None

    @property
    def current_task_id(self) -> Optional[str]:
        return self._current_task

    @current_task_id.setter
    def current_task_id(self, value: Optional[str]):
        self._current_task = value


task_manager = TaskManager()
