"""
conftest.py — Shared pytest fixtures for the backend test suite.

The TestClient fixture spins up the FastAPI app in-process (no real HTTP
server needed), making tests fast and dependency-free.
"""

import pytest
from fastapi.testclient import TestClient

from src.main import app
from src.routes.items import _store


@pytest.fixture(autouse=True)
def clear_store() -> None:
    """
    Clear the in-memory item store before every test so tests are isolated
    and order-independent.
    """
    _store.clear()


@pytest.fixture
def client() -> TestClient:
    """Return a synchronous test client wrapping the FastAPI app."""
    return TestClient(app)
