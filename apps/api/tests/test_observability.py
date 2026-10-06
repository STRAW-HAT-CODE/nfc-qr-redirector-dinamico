import json
import logging
import random
from typing import Any

import httpx
import pytest
import respx
from fastapi.testclient import TestClient

from app.core import logging as dqr_logging
from app.core.config import get_settings
from app.main import app

client = TestClient(app)


def _access(caplog: pytest.LogCaptureFixture) -> list[logging.LogRecord]:
    return [r for r in caplog.records if r.name == "dqr.access"]


def test_request_id_generated_and_returned() -> None:
    r = client.get("/healthz")
    assert len(r.headers["x-request-id"]) == 32


def test_request_id_propagated_and_sanitized() -> None:
    assert (
        client.get("/healthz", headers={"x-request-id": "abc-123"}).headers["x-request-id"]
        == "abc-123"
    )
    bad = client.get("/healthz", headers={"x-request-id": 'a b"<script>'})
    assert bad.headers["x-request-id"] != 'a b"<script>'


def test_access_log_fields(caplog: pytest.LogCaptureFixture) -> None:
    with caplog.at_level(logging.INFO, logger="dqr.access"):
        client.get("/healthz", headers={"x-request-id": "rid-1", "authorization": "Bearer xyz"})
    rec = _access(caplog)[-1]
    assert rec.__dict__["path"] == "/healthz"
    assert rec.__dict__["status"] == 200
    assert rec.__dict__["duration_ms"] >= 0
    line = json.loads(dqr_logging.JsonFormatter().format(rec))
    assert line["level"] == "INFO"
    assert "xyz" not in json.dumps(line)


def test_redirect_path_is_template_not_slug(caplog: pytest.LogCaptureFixture) -> None:
    with caplog.at_level(logging.INFO, logger="dqr.access"):
        client.get("/r/bad!", follow_redirects=False)
    assert _access(caplog)[-1].__dict__["path"] == "/r/{slug}"


def test_redirect_sampling(
    caplog: pytest.LogCaptureFixture, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(get_settings(), "log_redirect_sample_rate", 0.0)
    with caplog.at_level(logging.INFO, logger="dqr.access"):
        client.get("/r/bad!", follow_redirects=False)
        client.get("/healthz")
    paths = [r.__dict__["path"] for r in _access(caplog)]
    assert "/r/{slug}" not in paths
    assert "/healthz" in paths


def test_redirect_sampling_keeps_5xx(
    caplog: pytest.LogCaptureFixture, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(get_settings(), "log_redirect_sample_rate", 0.0)
    monkeypatch.setattr(random, "random", lambda: 0.99)
    dqr_logging.AccessLogMiddleware._log({"method": "GET", "path": "/r/x"}, 503, 1.0)
    # Sin caplog level explícito: comprobar que no lanza y que 5xx no se muestrea.
    with caplog.at_level(logging.INFO, logger="dqr.access"):
        dqr_logging.AccessLogMiddleware._log({"method": "GET", "path": "/r/x"}, 503, 1.0)
    assert _access(caplog)[-1].__dict__["status"] == 503


def test_formatter_redacts_secrets() -> None:
    jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2lnbmF0dXJl"
    rec = logging.LogRecord(
        "x", logging.WARNING, "f", 1, "fallo con Bearer %s y apikey: sk123", (jwt,), None
    )
    out = dqr_logging.JsonFormatter().format(rec)
    assert jwt not in out and "sk123" not in out
    assert json.loads(out)["level"] == "WARNING"


def test_formatter_exception_only_type() -> None:
    try:
        raise ValueError("password=hunter2")
    except ValueError:
        import sys

        rec = logging.LogRecord("x", logging.ERROR, "f", 1, "boom", (), sys.exc_info())
    out = dqr_logging.JsonFormatter().format(rec)
    assert "hunter2" not in out
    assert json.loads(out)["exc_type"] == "ValueError"


def test_healthz_db_ok_and_version(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(get_settings(), "vercel_git_commit_sha", "abc1234")
    with respx.mock(base_url="https://db.test/rest/v1") as mock:
        route = mock.post("/rpc/resolve_link").mock(return_value=httpx.Response(200, json=[]))
        app.state.service_client = httpx.AsyncClient(base_url="https://db.test/rest/v1")
        r = client.get("/healthz")
    assert r.status_code == 200
    assert r.json() == {"status": "ok", "version": "abc1234", "db": "ok"}
    assert route.called


def test_healthz_db_degraded_still_200() -> None:
    with respx.mock(base_url="https://db.test/rest/v1") as mock:
        mock.post("/rpc/resolve_link").mock(return_value=httpx.Response(503))
        app.state.service_client = httpx.AsyncClient(base_url="https://db.test/rest/v1")
        r = client.get("/healthz")
    assert r.status_code == 200
    assert r.json()["db"] == "degraded"


def test_sentry_before_send_strips_sensitive() -> None:
    event: dict[str, Any] = {
        "request": {
            "headers": {"Authorization": "Bearer x", "apikey": "k", "Cookie": "c", "accept": "*/*"},
            "cookies": {"s": "1"},
        },
        "user": {"ip_address": "1.2.3.4"},
    }
    out = dqr_logging._before_send(event, {})
    assert out is not None
    assert out["request"]["headers"] == {"accept": "*/*"}
    assert "cookies" not in out["request"] and "user" not in out


def test_init_sentry_disabled_without_dsn() -> None:
    assert dqr_logging.init_sentry(get_settings()) is False
