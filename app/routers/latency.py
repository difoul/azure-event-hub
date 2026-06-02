import asyncio
from fastapi import APIRouter, Query

router = APIRouter(prefix="/latency", tags=["latency"])


@router.get("")
async def slow_response(
    ms: int = Query(default=2000, ge=0, description="Delay in milliseconds before responding"),
):
    """Wait for the given number of milliseconds before returning a response."""
    await asyncio.sleep(ms / 1000)
    return {"status": "ok", "delay_ms": ms}
