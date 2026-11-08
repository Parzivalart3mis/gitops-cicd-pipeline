# Dockerfile — single-stage development image for the backend.
# Use this for fast local iteration (`make demo` builds it); tests run in CI
# and in the test stage of Dockerfile.multistage, which is what CI ships.

FROM python:3.12-slim

LABEL org.opencontainers.image.source="https://github.com/Parzivalart3mis/gitops-cicd-pipeline"
LABEL org.opencontainers.image.description="GitOps demo backend (development)"
LABEL org.opencontainers.image.licenses="MIT"

WORKDIR /app

# Fixed UID/GID 1000 to match the Deployment's runAsUser/runAsGroup.
RUN groupadd --gid 1000 appgroup \
    && useradd --uid 1000 --gid 1000 --no-create-home --shell /usr/sbin/nologin appuser

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY src/ ./src/

ARG GIT_SHA=unknown
ENV GIT_SHA=${GIT_SHA} \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

USER 1000:1000

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/healthz')" || exit 1

CMD ["uvicorn", "src.main:app", "--host", "0.0.0.0", "--port", "8000"]
