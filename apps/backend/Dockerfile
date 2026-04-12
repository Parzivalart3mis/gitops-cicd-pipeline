# Dockerfile — single-stage development image for the backend.
# Use this for fast local iteration where test isolation is handled
# by the CI pipeline rather than a multi-stage build.
# For production-optimised builds use Dockerfile.multistage.

FROM python:3.12-slim

LABEL org.opencontainers.image.source="https://github.com/Parzivalart3mis/gitops-cicd-pipeline"
LABEL org.opencontainers.image.description="GitOps demo backend (development)"
LABEL org.opencontainers.image.licenses="MIT"

WORKDIR /app

# Create a non-root user before installing dependencies.
# Running as root inside a container is a container-escape risk.
RUN addgroup --system appgroup && adduser --system --ingroup appgroup appuser

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY src/ ./src/

# Switch to non-root user for all subsequent commands and the final CMD.
USER appuser

EXPOSE 8000

# Kubernetes liveness probe will call this endpoint.
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/healthz')" || exit 1

CMD ["uvicorn", "src.main:app", "--host", "0.0.0.0", "--port", "8000"]
