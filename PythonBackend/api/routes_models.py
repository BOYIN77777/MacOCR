from fastapi import APIRouter, HTTPException

from ..services.model_manager import check_models_available
from ..core.config import get_models_dir

router = APIRouter(prefix="/api/v1/models", tags=["models"])


@router.get("/status")
async def models_status():
    status = check_models_available()
    return {
        "downloaded": status.downloaded,
        "models_dir": status.models_dir,
    }


@router.get("/config")
async def get_config():
    from ..core.config import load_or_create_config
    config = load_or_create_config()
    safe_config = {k: v for k, v in config.items() if k not in ("models-dir",)}
    return safe_config
