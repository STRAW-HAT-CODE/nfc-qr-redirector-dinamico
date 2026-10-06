import pytest
from fastapi.testclient import TestClient

import app.main as main_module
from app.main import app

client = TestClient(app)


@pytest.fixture(autouse=True)
def _reset_db_ping_cache() -> None:
    main_module._db_ping_cache = None


def test_healthz() -> None:
    # Sin lifespan ni BD: sigue 200, con db degradada.
    response = client.get("/healthz")
    assert response.status_code == 200
    assert response.json() == {"status": "ok", "version": "unknown", "db": "degraded"}
