import os
import time
from fastapi import APIRouter
from fastapi.responses import JSONResponse

router = APIRouter(prefix="/dr", tags=["disaster-recovery"])

# _degraded is process-local state. Each replica has its own copy — setting it on one
# replica does NOT affect other replicas. For a clean DR simulation, either:
#   (a) set min_replicas=1 before calling /dr/degrade, or
#   (b) call /dr/degrade on every replica using the replica's direct internal address.
# Azure Front Door only removes a region from rotation when ALL replicas fail the health
# probe, so a partial degrade will NOT trigger failover.
_degraded: bool = False
_start_time: float = time.time()


@router.get("/region")
def get_region():
    """Return the region identity of this deployment instance."""
    return {
        "region": os.getenv("REGION_NAME", "unknown"),
        "role": os.getenv("INSTANCE_ROLE", "primary"),
    }


@router.get("/status")
def dr_status():
    """Return extended health and region status used for DR monitoring and validation."""
    return {
        "region": os.getenv("REGION_NAME", "unknown"),
        "role": os.getenv("INSTANCE_ROLE", "primary"),
        "healthy": not _degraded,
        "degraded": _degraded,
        "uptime_seconds": int(time.time() - _start_time),
    }


@router.post("/degrade")
def degrade():
    """
    Simulate region degradation.

    Sets /health to return 503. Azure Front Door health probes will detect
    the failure within ~1 minute and automatically reroute all traffic to
    the secondary region.

    Note: this flag is per-process. In a multi-replica deployment, call
    this endpoint on every replica (or set min_replicas=1 before testing).
    """
    global _degraded
    _degraded = True
    return {
        "status": "degraded",
        "message": (
            "/health now returns 503. "
            "Azure Front Door health probes will detect this and reroute traffic to the secondary region."
        ),
    }


@router.post("/recover")
def recover():
    """
    Recover from simulated degradation.

    Sets /health back to 200. Azure Front Door health probes will detect
    recovery and gradually restore traffic to this region (failback).
    """
    global _degraded
    _degraded = False
    return {
        "status": "recovered",
        "message": (
            "/health now returns 200. "
            "Azure Front Door health probes will detect recovery and restore traffic to this region."
        ),
    }
