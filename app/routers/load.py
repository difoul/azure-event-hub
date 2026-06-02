import time
import threading
import math
from fastapi import APIRouter, Query

router = APIRouter(prefix="/load", tags=["load"])


@router.post("/cpu")
def cpu_load(
    duration: int = Query(default=30, description="Duration in seconds"),
    intensity: int = Query(default=80, ge=1, le=100, description="CPU intensity percentage"),
):
    """Burn CPU at the given intensity % for the given duration."""
    end_time = time.time() + duration
    cycle = intensity / 100.0

    def burn():
        while time.time() < end_time:
            start = time.time()
            # busy loop for `cycle` fraction of each 100ms window
            while time.time() - start < 0.1 * cycle:
                math.sqrt(123456789)
            # sleep the remaining fraction
            sleep_for = 0.1 * (1 - cycle)
            if sleep_for > 0:
                time.sleep(sleep_for)

    t = threading.Thread(target=burn, daemon=True)
    t.start()

    return {"status": "started", "duration_seconds": duration, "intensity_percent": intensity}


@router.post("/memory")
def memory_load(
    mb: int = Query(default=256, ge=1, description="Megabytes to allocate"),
    duration: int = Query(default=30, description="Duration in seconds"),
):
    """Allocate the given amount of memory for the given duration."""
    chunk = bytearray(mb * 1024 * 1024)
    # Write to every page to force the OS to commit physical memory.
    # bytearray() uses lazy allocation — pages are only added to the working
    # set when written, so without this the metric never rises.
    chunk[::4096] = b'\x01' * (len(chunk) // 4096)

    def release(data):
        time.sleep(duration)
        del data

    t = threading.Thread(target=release, args=(chunk,), daemon=True)
    t.start()

    return {"status": "allocated", "mb": mb, "duration_seconds": duration}
