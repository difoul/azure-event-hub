from fastapi import APIRouter, HTTPException, Path

router = APIRouter(prefix="/errors", tags=["errors"])

_DESCRIPTIONS = {
    400: "Bad Request",
    401: "Unauthorized",
    403: "Forbidden",
    404: "Not Found",
    429: "Too Many Requests",
    500: "Internal Server Error",
    502: "Bad Gateway",
    503: "Service Unavailable",
    504: "Gateway Timeout",
}


@router.get("/{code}")
def return_error(
    code: int = Path(description="HTTP status code to return (e.g. 500, 404, 429)", ge=400, le=599),
):
    """Return the requested HTTP error code with a descriptive message."""
    description = _DESCRIPTIONS.get(code, "Error")
    raise HTTPException(
        status_code=code,
        detail={"error": code, "message": description, "simulated": True},
    )
