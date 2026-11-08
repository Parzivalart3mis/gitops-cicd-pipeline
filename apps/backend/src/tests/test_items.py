"""
test_items.py — Tests for the /api/v1/items CRUD endpoints.

Covers the happy path and common error scenarios for list, create,
get-by-id, and delete operations.
"""

from fastapi.testclient import TestClient

# ---------------------------------------------------------------------------
# list_items
# ---------------------------------------------------------------------------

def test_list_items_empty(client: TestClient) -> None:
    """GET /api/v1/items returns an empty list when the store is fresh."""
    response = client.get("/api/v1/items")
    assert response.status_code == 200
    assert response.json() == []


def test_list_items_after_creation(client: TestClient) -> None:
    """Items added via POST should appear in subsequent GET /api/v1/items calls."""
    client.post("/api/v1/items", json={"name": "Widget", "quantity": 5})
    response = client.get("/api/v1/items")
    assert response.status_code == 200
    assert len(response.json()) == 1
    assert response.json()[0]["name"] == "Widget"


# ---------------------------------------------------------------------------
# create_item
# ---------------------------------------------------------------------------

def test_create_item_returns_201(client: TestClient) -> None:
    """POST /api/v1/items must return HTTP 201 Created."""
    response = client.post("/api/v1/items", json={"name": "Gadget", "quantity": 3})
    assert response.status_code == 201


def test_create_item_body(client: TestClient) -> None:
    """Created item body must echo submitted fields and include server-generated id/created_at."""
    payload = {"name": "Gizmo", "description": "A cool gizmo", "quantity": 10}
    response = client.post("/api/v1/items", json=payload)
    body = response.json()
    assert body["name"] == "Gizmo"
    assert body["description"] == "A cool gizmo"
    assert body["quantity"] == 10
    assert "id" in body
    assert "created_at" in body


def test_create_item_missing_name_returns_422(client: TestClient) -> None:
    """POSTing without a required 'name' field must return 422 Unprocessable Entity."""
    response = client.post("/api/v1/items", json={"quantity": 1})
    assert response.status_code == 422


def test_create_item_negative_quantity_returns_422(client: TestClient) -> None:
    """Negative quantity violates the ge=0 constraint — expect 422."""
    response = client.post("/api/v1/items", json={"name": "Bad", "quantity": -1})
    assert response.status_code == 422


# ---------------------------------------------------------------------------
# get_item
# ---------------------------------------------------------------------------

def test_get_item_by_id(client: TestClient) -> None:
    """GET /api/v1/items/{id} should return the item that was created."""
    create_resp = client.post("/api/v1/items", json={"name": "Doohickey", "quantity": 2})
    item_id = create_resp.json()["id"]
    get_resp = client.get(f"/api/v1/items/{item_id}")
    assert get_resp.status_code == 200
    assert get_resp.json()["id"] == item_id


def test_get_item_not_found_returns_404(client: TestClient) -> None:
    """Requesting a non-existent UUID must return 404 Not Found."""
    response = client.get("/api/v1/items/00000000-0000-0000-0000-000000000000")
    assert response.status_code == 404


# ---------------------------------------------------------------------------
# delete_item
# ---------------------------------------------------------------------------

def test_delete_item_returns_204(client: TestClient) -> None:
    """DELETE /api/v1/items/{id} must return 204 No Content on success."""
    create_resp = client.post("/api/v1/items", json={"name": "Thingamajig", "quantity": 1})
    item_id = create_resp.json()["id"]
    delete_resp = client.delete(f"/api/v1/items/{item_id}")
    assert delete_resp.status_code == 204


def test_delete_item_removes_from_store(client: TestClient) -> None:
    """After deletion, the item must no longer be retrievable."""
    create_resp = client.post("/api/v1/items", json={"name": "Whatchamacallit", "quantity": 7})
    item_id = create_resp.json()["id"]
    client.delete(f"/api/v1/items/{item_id}")
    get_resp = client.get(f"/api/v1/items/{item_id}")
    assert get_resp.status_code == 404


def test_delete_nonexistent_item_returns_404(client: TestClient) -> None:
    """Deleting a UUID that was never created must return 404."""
    response = client.delete("/api/v1/items/00000000-0000-0000-0000-000000000000")
    assert response.status_code == 404
