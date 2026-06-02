import logging
import time
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from opentelemetry import trace
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor, ConsoleSpanExporter
from starlette.middleware.base import BaseHTTPMiddleware

from app.logging_config import setup_logging
from app.routers import dr, errors, latency, load, scaling

setup_logging()
logger = logging.getLogger(__name__)
access_logger = logging.getLogger("access")

_resource = Resource.create({"service.name": "azure-event-hub-demo"})
_provider = TracerProvider(resource=_resource)
_provider.add_span_processor(BatchSpanProcessor(ConsoleSpanExporter()))
trace.set_tracer_provider(_provider)


class AccessLogMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        start = time.perf_counter()
        response = await call_next(request)
        duration_ms = round((time.perf_counter() - start) * 1000, 2)

        span = trace.get_current_span()
        ctx = span.get_span_context()
        trace_id = format(ctx.trace_id, "032x") if ctx.is_valid else None
        span_id = format(ctx.span_id, "016x") if ctx.is_valid else None

        access_logger.info(
            "http_request",
            extra={
                "method": request.method,
                "path": request.url.path,
                "query": str(request.url.query),
                "status_code": response.status_code,
                "duration_ms": duration_ms,
                "trace_id": trace_id,
                "span_id": span_id,
                "user_agent": request.headers.get("user-agent"),
                "x_forwarded_for": request.headers.get("x-forwarded-for"),
                "request_id": request.headers.get("x-request-id"),
            },
        )
        return response


@asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info("startup: application initialised")
    yield
    _provider.force_flush(timeout_millis=5000)
    logger.info("shutdown: telemetry flushed")


app = FastAPI(
    title="Azure Container App Monitoring Demo",
    description="Endpoints for generating load, errors, latency, and scaling events to test Azure monitoring.",
    version="1.0.0",
    lifespan=lifespan,
)

app.add_middleware(AccessLogMiddleware)
FastAPIInstrumentor.instrument_app(app)

app.include_router(load.router)
app.include_router(errors.router)
app.include_router(latency.router)
app.include_router(scaling.router)
app.include_router(dr.router)


@app.get("/health", tags=["health"])
def health():
    if dr._degraded:
        return JSONResponse(status_code=503, content={"status": "degraded"})
    return {"status": "ok"}


@app.get("/", tags=["health"])
def root():
    return {
        "service": "azure-event-hub-demo",
        "endpoints": {
            "cpu_load": "POST /load/cpu?duration=30&intensity=80",
            "memory_load": "POST /load/memory?mb=256&duration=30",
            "error": "GET /errors/{code}",
            "latency": "GET /latency?ms=2000",
            "burst": "GET /burst?requests=100",
            "health": "GET /health",
            "dr_region": "GET /dr/region",
            "dr_status": "GET /dr/status",
            "dr_degrade": "POST /dr/degrade",
            "dr_recover": "POST /dr/recover",
            "docs": "GET /docs",
        },
    }
