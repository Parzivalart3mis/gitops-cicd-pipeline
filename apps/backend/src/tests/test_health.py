"""
test_health.py — Tests for the /healthz and /readyz endpoints.

These endpoints are critical because Kubernetes liveness and readiness
probes depend on them returning correct HTTP status codes and payloads.
"""

import pytest
from fastapi.testclient import TestClient


def test_healthz_returns_200(client: TestClient) -> None:
    """Liveness probe must always return 200 with a JSON body."""
    response = client.get("/healthz")
    assert response.status_code == 200


def test_healthz_body_contains_required_fields(client: TestClient) -> None:
    """The /healthz body must contain 'status', 'version', and 'environment'."""
    response = client.get("/healthz")
    body = response.json()
    assert "status" in body
    assert "version" in body
    assert "environment" in body


def test_healthz_status_is_healthy(client: TestClient) -> None:
    """The 'status' field must equal 'healthy'."""
    response = client.get("/healthz")
    assert response.json()["status"] == "healthy"


def test_healthz_reflects_environment_env_var(client: TestClient, monkeypatch: pytest.MonkeyPatch) -> None:
    """
    The 'environment' field should reflect the ENVIRONMENT env var.
    We monkeypatch src.main.ENVIRONMENT directly because the module is
    already imported; reloading would reset the in-memory store.
    """
    import src.main as main_module
    original = main_module.ENVIRONMENT
    main_module.ENVIRONMENT = "test-env"
    try:
        response = client.get("/healthz")
        assert response.json()["environment"] == "test-env"
    finally:
        main_module.ENVIRONMENT = original


def test_readyz_returns_200_after_startup(client: TestClient) -> None:
    """
    /readyz should return 200 once the lifespan startup has completed.
    TestClient triggers the full lifespan, so the app is ready immediately.
    """
    response = client.get("/readyz")
    assert response.status_code == 200
    assert response.json()["status"] == "ready"
