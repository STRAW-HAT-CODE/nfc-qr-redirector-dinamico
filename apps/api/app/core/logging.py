"""Observabilidad (DQR-T056): logs JSON, middleware de acceso, Sentry opcional.

Reglas de privacidad: nunca se loguean tokens, `apikey`, cabeceras, IP cruda ni la sal.
El middleware de acceso solo registra método, ruta (plantilla), status y duración.
"""

import importlib
import json
import logging
import random
import re
import time
import uuid
from contextvars import ContextVar
from typing import Any

from starlette.datastructures import MutableHeaders
from starlette.types import ASGIApp, Message, Receive, Scope, Send

from app.core.config import Settings, get_settings

request_id_var: ContextVar[str | None] = ContextVar("request_id", default=None)

_REQUEST_ID_RE = re.compile(r"^[A-Za-z0-9._-]{1,64}$")
_SECRET_RE = re.compile(
    r"(eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]*"  # JWT
    r"|(?i:bearer)\s+\S+"
    r"|(?i:apikey)\W{0,3}\s*\S+)"
)
# Atributos estándar de LogRecord: no se copian como campos extra.
_STD_ATTRS = frozenset(logging.LogRecord("", 0, "", 0, "", (), None).__dict__) | {
    "message",
    "asctime",
    "taskName",
}
_SENSITIVE_HEADERS = frozenset({"authorization", "apikey", "cookie", "set-cookie"})


def scrub(text: str) -> str:
    return _SECRET_RE.sub("[redacted]", text)


class JsonFormatter(logging.Formatter):
    """Una línea JSON por registro; campos extra (`extra={...}`) se incluyen."""

    def format(self, record: logging.LogRecord) -> str:
        data: dict[str, Any] = {
            "ts": time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(record.created))
            + f".{int(record.msecs):03d}Z",
            "level": record.levelname,
            "logger": record.name,
            "message": scrub(record.getMessage()),
            "request_id": request_id_var.get(),
        }
        for key, value in record.__dict__.items():
            if key not in _STD_ATTRS and key not in data and not key.startswith("_"):
                data[key] = scrub(value) if isinstance(value, str) else value
        if record.exc_info and record.exc_info[0] is not None:
            # Solo el tipo: el texto de la excepción puede traer URLs o credenciales.
            data["exc_type"] = record.exc_info[0].__name__
        return json.dumps(data, ensure_ascii=False, default=str)


def setup_logging(settings: Settings | None = None) -> None:
    """Instala el formatter JSON en el logger raíz (idempotente)."""
    settings = settings or get_settings()
    root = logging.getLogger()
    root.setLevel(settings.log_level.upper())
    for handler in root.handlers:
        if getattr(handler, "_dqr_json", False):
            return
    for handler in list(root.handlers):
        root.removeHandler(handler)
    handler = logging.StreamHandler()
    handler.setFormatter(JsonFormatter())
    handler._dqr_json = True  # type: ignore[attr-defined]
    root.addHandler(handler)
    # uvicorn ya imprime su propio access log con IP; el nuestro lo sustituye.
    logging.getLogger("uvicorn.access").disabled = True


access_logger = logging.getLogger("dqr.access")


class AccessLogMiddleware:
    """ASGI puro: request_id, cabecera `x-request-id` y log de acceso con duración."""

    def __init__(self, app: ASGIApp) -> None:
        self.app = app

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        incoming = MutableHeaders(scope=scope).get("x-request-id", "")
        rid = incoming if _REQUEST_ID_RE.match(incoming) else uuid.uuid4().hex
        token = request_id_var.set(rid)
        status = 500
        start = time.perf_counter()

        async def send_wrapper(message: Message) -> None:
            nonlocal status
            if message["type"] == "http.response.start":
                status = message["status"]
                MutableHeaders(scope=message)["x-request-id"] = rid
            await send(message)

        try:
            await self.app(scope, receive, send_wrapper)
        finally:
            duration_ms = round((time.perf_counter() - start) * 1000, 2)
            self._log(scope, status, duration_ms)
            request_id_var.reset(token)

    @staticmethod
    def _log(scope: Scope, status: int, duration_ms: float) -> None:
        route = scope.get("route")
        path = getattr(route, "path", None) or str(scope.get("path", ""))[:200]
        if path.startswith("/r/") and status < 500:
            rate = get_settings().log_redirect_sample_rate
            if rate < 1.0 and random.random() >= rate:
                return
        level = logging.ERROR if status >= 500 else logging.INFO
        access_logger.log(
            level,
            "request",
            extra={
                "method": scope.get("method"),
                "path": path,
                "status": status,
                "duration_ms": duration_ms,
            },
        )


def _before_send(event: dict[str, Any], hint: dict[str, Any]) -> dict[str, Any] | None:
    request = event.get("request")
    if isinstance(request, dict):
        headers = request.get("headers")
        if isinstance(headers, dict):
            request["headers"] = {
                k: v for k, v in headers.items() if k.lower() not in _SENSITIVE_HEADERS
            }
        request.pop("cookies", None)
        request.pop("env", None)  # REMOTE_ADDR
    event.pop("user", None)  # ip_address
    return event


def init_sentry(settings: Settings | None = None) -> bool:
    """Activa Sentry si hay SENTRY_DSN y `sentry-sdk` está instalado (extra `sentry`)."""
    settings = settings or get_settings()
    if not settings.sentry_dsn:
        return False
    try:
        sentry_sdk: Any = importlib.import_module("sentry_sdk")  # extra opcional
    except ImportError:
        logging.getLogger(__name__).warning("SENTRY_DSN definido pero sentry-sdk no instalado")
        return False
    sentry_sdk.init(
        dsn=settings.sentry_dsn,
        environment=settings.sentry_environment or None,
        release=settings.vercel_git_commit_sha or None,
        send_default_pii=False,
        before_send=_before_send,
    )
    return True
