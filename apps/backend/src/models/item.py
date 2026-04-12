"""
models/item.py — Pydantic data models for the Item resource.

Using Pydantic v2 models (bundled with FastAPI ≥ 0.100) for automatic
request validation, serialisation, and OpenAPI schema generation.
"""

from uuid import UUID, uuid4
from datetime import datetime, timezone

from pydantic import BaseModel, Field


class ItemBase(BaseModel):
    """Shared fields between create / read representations."""

    name: str = Field(..., min_length=1, max_length=128, description="Human-readable item name")
    description: str = Field(default="", max_length=1024, description="Optional item description")
    quantity: int = Field(default=1, ge=0, description="Non-negative item count")


class ItemCreate(ItemBase):
    """Schema accepted on POST /api/v1/items."""
    pass


class Item(ItemBase):
    """Full representation returned by the API, including server-generated fields."""

    id: UUID = Field(default_factory=uuid4, description="Unique item identifier (UUID v4)")
    created_at: datetime = Field(
        default_factory=lambda: datetime.now(timezone.utc),
        description="ISO-8601 creation timestamp (UTC)",
    )

    model_config = {"from_attributes": True}
