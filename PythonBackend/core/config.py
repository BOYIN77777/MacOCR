import os
import json
import platform
from pathlib import Path


def get_app_support_dir() -> Path:
    base = Path.home() / "Library" / "Application Support" / "MacOCR"
    base.mkdir(parents=True, exist_ok=True)
    return base


def get_models_dir() -> Path:
    path = get_app_support_dir() / "models"
    path.mkdir(parents=True, exist_ok=True)
    return path


def get_config_path() -> Path:
    return get_app_support_dir() / "magic-pdf.json"


def get_cache_dir() -> Path:
    path = get_app_support_dir() / "cache"
    path.mkdir(parents=True, exist_ok=True)
    return path


def generate_magic_pdf_config() -> dict:
    models_dir = str(get_models_dir() / "PDF-Extract-Kit")
    device = "mps" if platform.processor() == "arm" else "cpu"

    return {
        "models-dir": models_dir,
        "device-mode": device,
        "table-config": {
            "model": "rapid_table",
            "enable": True,
            "max_time": 400,
        },
        "layout-config": {
            "model": "layoutlmv3",
        },
        "formula-config": {
            "mfd_model": "yolo_v8_mfd",
            "mfr_model": "unimernet_base",
            "enable": True,
        },
    }


def load_or_create_config() -> dict:
    config_path = get_config_path()
    # Ensure magic-pdf can always find the config via env var
    os.environ["MINERU_TOOLS_CONFIG_JSON"] = str(config_path)
    if config_path.exists():
        with open(config_path) as f:
            return json.load(f)
    config = generate_magic_pdf_config()
    with open(config_path, "w") as f:
        json.dump(config, f, indent=2)
    return config
