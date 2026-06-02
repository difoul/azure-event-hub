import asyncio
import httpx
from fastapi import APIRouter, Query, Request

router = APIRouter(prefix="/burst", tags=["scaling"])


@router.get("")
async def burst(
    request: Request,
    requests: int = Query(default=100, ge=1, le=1000, description="Number of self-requests to fire"),
):
    """Fire rapid concurrent requests against /health to spike the request count and trigger scaling."""
    base_url = str(request.base_url).rstrip("/")
    target = f"{base_url}/health"

    semaphore = asyncio.Semaphore(50)

    async def fetch(client):
        async with semaphore:
            return await client.get(target)

    async with httpx.AsyncClient(timeout=10.0) as client:
        tasks = [fetch(client) for _ in range(requests)]
        results = await asyncio.gather(*tasks, return_exceptions=True)

    success = 0
    timed_out = 0
    connection_errors = 0
    other_errors = 0
    for r in results:
        if isinstance(r, httpx.Response) and r.status_code == 200:
            success += 1
        elif isinstance(r, httpx.TimeoutException):
            timed_out += 1
        elif isinstance(r, httpx.ConnectError):
            connection_errors += 1
        elif isinstance(r, Exception):
            other_errors += 1

    return {
        "fired": requests,
        "success": success,
        "failed": {
            "timeout": timed_out,
            "connection_error": connection_errors,
            "other": other_errors,
        },
    }
