from collections.abc import Iterator

import pytest

from app.main import app


@pytest.fixture(autouse=True)
def _fresh_rate_limiter() -> Iterator[None]:
    """Cada test parte con buckets vacíos (el limiter vive en app.state)."""
    app.state.rate_limiter = None
    yield
    app.state.rate_limiter = None
