import os
import argparse
import logging
from contextlib import asynccontextmanager

# Ensure working directory is writable (app bundle is read-only)
_writable_dir = os.path.expanduser("~/Library/Application Support/MacOCR")
os.makedirs(_writable_dir, exist_ok=True)
os.chdir(_writable_dir)

# Log startup diagnostics to /tmp (always writable, even in sandbox)
import sys, tempfile
_log_path = os.path.join(tempfile.gettempdir(), "macocr_backend.log")
sys.stderr = open(_log_path, "a")
print(f"MacOCR backend starting, cwd={os.getcwd()}, home={os.path.expanduser('~')}", flush=True)

from .core.config import get_config_path, load_or_create_config
os.environ["MINERU_TOOLS_CONFIG_JSON"] = str(get_config_path())
load_or_create_config()

import uvicorn
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from .api.routes_ocr import router as ocr_router
from .api.routes_models import router as models_router
from .api.routes_health import router as health_router

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
logger = logging.getLogger("macocr-backend")


@asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info("MacOCR backend starting up")
    yield
    logger.info("MacOCR backend shutting down")


app = FastAPI(
    title="MacOCR Backend",
    description="OCR engine service for MacOCR.app",
    version="0.1.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(ocr_router)
app.include_router(models_router)
app.include_router(health_router)


def main():
    parser = argparse.ArgumentParser(description="MacOCR Backend Server")
    parser.add_argument(
        "--socket",
        type=str,
        help="Unix domain socket path",
    )
    parser.add_argument(
        "--host",
        type=str,
        default="127.0.0.1",
        help="Host to bind to (ignored if --socket is provided)",
    )
    parser.add_argument(
        "--port",
        type=int,
        default=8765,
        help="Port to bind to (default: 8765, ignored if --socket is provided)",
    )
    args = parser.parse_args()

    if args.socket:
        logger.info(f"Starting on Unix socket: {args.socket}")
        uvicorn.run(
            app,
            uds=args.socket,
            log_level="info",
        )
    else:
        logger.info(f"Starting on {args.host}:{args.port}")
        uvicorn.run(
            app,
            host=args.host,
            port=args.port,
            log_level="info",
        )


if __name__ == "__main__":
    main()
