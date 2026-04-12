"""
main.py — FastAPI application entry point for the GitOps CI/CD demo backend.

This service exposes a simple REST API for managing items, along with
Kubernetes-compatible health/readiness endpoints and a Prometheus metrics endpoint.
The /healthz endpoint returns the current GIT_SHA and ENVIRONMENT, which proves
in live demos that a new image version was successfully deployed.
"""

import os
import logging
from contextlib import asynccontextmanager
from typing import AsyncGenerator

import structlog
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from prometheus_fastapi_instrumentator import Instrumentator

from .routes import items as items_router

# ---------------------------------------------------------------------------
# Structured logging setup
# ---------------------------------------------------------------------------
structlog.configure(
    processors=[
        structlog.stdlib.add_log_level,
        structlog.stdlib.add_logger_name,
        structlog.processors.TimeStamper(fmt="iso"),
        structlog.processors.JSONRenderer(),
    ],
    wrapper_class=structlog.stdlib.BoundLogger,
    logger_factory=structlog.stdlib.LoggerFactory(),
)

log = structlog.get_logger()

# ---------------------------------------------------------------------------
# Application-level configuration (injected via env vars / ConfigMap)
# ---------------------------------------------------------------------------
GIT_SHA: str = os.getenv("GIT_SHA", "unknown")
ENVIRONMENT: str = os.getenv("ENVIRONMENT", "local")
LOG_LEVEL: str = os.getenv("LOG_LEVEL", "info").upper()

logging.basicConfig(level=getattr(logging, LOG_LEVEL, logging.INFO))

# ---------------------------------------------------------------------------
# App startup / shutdown lifecycle
# ---------------------------------------------------------------------------
_app_ready: bool = False


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncGenerator[None, None]:
    """
    Lifespan context manager — runs startup logic before yield and
    teardown after. Flip _app_ready to True once initialisation is done
    so /readyz begins returning 200 only when the service is actually ready.
    """
    global _app_ready
    log.info("startup", git_sha=GIT_SHA, environment=ENVIRONMENT)
    _app_ready = True
    yield
    _app_ready = False
    log.info("shutdown")


# ---------------------------------------------------------------------------
# FastAPI app
# ---------------------------------------------------------------------------
app = FastAPI(
    title="GitOps Demo Backend",
    description=(
        "Demo REST API for the GitOps CI/CD pipeline portfolio project. "
        "Designed to showcase automated deployment, health probes, and "
        "Prometheus-compatible metrics."
    ),
    version=GIT_SHA,
    lifespan=lifespan,
)

# ---------------------------------------------------------------------------
# CORS — permissive for local dev; tighten in production via env var
# ---------------------------------------------------------------------------
app.add_middleware(
    CORSMiddleware,
    allow_origins=os.getenv("ALLOWED_ORIGINS", "*").split(","),
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# ---------------------------------------------------------------------------
# Prometheus instrumentation — exposes /metrics automatically
# ---------------------------------------------------------------------------
Instrumentator().instrument(app).expose(app)

# ---------------------------------------------------------------------------
# Routers
# ---------------------------------------------------------------------------
app.include_router(items_router.router, prefix="/api/v1", tags=["items"])


# ---------------------------------------------------------------------------
# Health / readiness probes
# ---------------------------------------------------------------------------
@app.get("/healthz", tags=["health"])
async def healthz() -> dict:
    """
    Liveness probe.
    Returns the git SHA and environment so demos can visually confirm
    that Kubernetes is running the expected image version.
    """
    return {
        "status": "healthy",
        "version": GIT_SHA,
        "environment": ENVIRONMENT,
    }


@app.get("/readyz", tags=["health"])
async def readyz() -> dict:
    """
    Readiness probe.
    Returns 200 only after the application has finished initialising.
    Kubernetes will not route traffic here until this returns 200.
    """
    if not _app_ready:
        raise HTTPException(status_code=503, detail="not ready")
    return {"status": "ready"}
