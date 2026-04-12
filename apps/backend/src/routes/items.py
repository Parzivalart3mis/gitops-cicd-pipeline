"""
routes/items.py — CRUD endpoints for the Item resource.

Uses an in-memory dictionary as the backing store. In a real application
this would be replaced by an async database client (SQLAlchemy async /
asyncpg / Motor). The in-memory store is intentional here — the goal
is to demo the CI/CD pipeline, not persistence semantics.
"""

from uuid import UUID
from typing import Dict

import structlog
from fastapi import APIRouter, HTTPException, status

from ..models.item import Item, ItemCreate

log = structlog.get_logger()

router = APIRouter()

# In-memory store: { UUID → Item }
_store: Dict[UUID, Item] = {}


@router.get("/items", response_model=list[Item], summary="List all items")
async def list_items() -> list[Item]:
    """Return all items in the store."""
    log.info("list_items", count=len(_store))
    return list(_store.values())


@router.post(
    "/items",
    response_model=Item,
    status_code=status.HTTP_201_CREATED,
    summary="Create a new item",
)
async def create_item(payload: ItemCreate) -> Item:
    """Create a new item and add it to the in-memory store."""
    item = Item(**payload.model_dump())
    _store[item.id] = item
    log.info("create_item", item_id=str(item.id), name=item.name)
    return item


@router.get("/items/{item_id}", response_model=Item, summary="Get a single item")
async def get_item(item_id: UUID) -> Item:
    """Return a single item by its UUID. Raises 404 if not found."""
    item = _store.get(item_id)
    if item is None:
        log.warning("item_not_found", item_id=str(item_id))
        raise HTTPException(status_code=404, detail=f"Item {item_id} not found")
    return item


@router.delete(
    "/items/{item_id}",
    status_code=status.HTTP_204_NO_CONTENT,
    summary="Delete an item",
)
async def delete_item(item_id: UUID) -> None:
    """Delete an item by UUID. Raises 404 if not found."""
    if item_id not in _store:
        raise HTTPException(status_code=404, detail=f"Item {item_id} not found")
    del _store[item_id]
    log.info("delete_item", item_id=str(item_id))
