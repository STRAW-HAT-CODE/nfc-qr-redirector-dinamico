"""Límite de cuerpo para la subida de logos (T032-H1).

FastAPI parsea el multipart antes de autenticar, así que el tope se aplica antes: por
Content-Length y, si el cuerpo viene chunked, contando bytes al recibir.
"""

import re

from starlette.responses import JSONResponse
from starlette.types import ASGIApp, Message, Receive, Scope, Send

MAX_BODY_BYTES = 1_100_000  # logo ≤ 1 MB + sobrecarga multipart
_LOGO_PATH = re.compile(r"^/v1/links/[^/]+/design/logo$")

_BODY = {"error": {"code": "payload_too_large", "message": "El cuerpo supera el límite de 1 MB"}}


class _TooLarge(BaseException):  # noqa: N818
    """BaseException a propósito: FastAPI convierte cualquier Exception al parsear en 400."""


class BodyLimitMiddleware:
    def __init__(self, app: ASGIApp, max_bytes: int = MAX_BODY_BYTES) -> None:
        self.app = app
        self.max_bytes = max_bytes

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if (
            scope["type"] != "http"
            or scope["method"] != "POST"
            or not _LOGO_PATH.match(scope["path"])
        ):
            await self.app(scope, receive, send)
            return

        for name, value in scope["headers"]:
            if name == b"content-length":
                try:
                    declared = int(value)
                except ValueError:
                    declared = self.max_bytes + 1
                if declared > self.max_bytes:
                    await self._reject(scope, receive, send)
                    return

        seen = 0
        started = False

        async def limited_receive() -> Message:
            nonlocal seen
            msg = await receive()
            if msg["type"] == "http.request":
                seen += len(msg.get("body", b""))
                if seen > self.max_bytes:
                    raise _TooLarge
            return msg

        async def tracking_send(msg: Message) -> None:
            nonlocal started
            if msg["type"] == "http.response.start":
                started = True
            await send(msg)

        try:
            await self.app(scope, limited_receive, tracking_send)
        except _TooLarge:
            if started:
                raise
            await self._reject(scope, receive, send)

    async def _reject(self, scope: Scope, receive: Receive, send: Send) -> None:
        resp = JSONResponse(_BODY, status_code=413, headers={"Connection": "close"})
        await resp(scope, receive, send)
