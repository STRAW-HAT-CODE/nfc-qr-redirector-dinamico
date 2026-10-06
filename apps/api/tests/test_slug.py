import re
import string

import pytest

from app.services.slug import SLUG_ALPHABET, SLUG_LENGTH, generate_slug, is_valid_slug


def test_constants() -> None:
    assert SLUG_LENGTH == 7
    assert len(SLUG_ALPHABET) == 62
    assert len(set(SLUG_ALPHABET)) == 62
    assert set(SLUG_ALPHABET) == set(string.ascii_letters + string.digits)


def test_generate_slug_shape() -> None:
    for _ in range(500):
        slug = generate_slug()
        assert len(slug) == SLUG_LENGTH
        assert re.fullmatch(r"[0-9A-Za-z]{7}", slug)
        assert is_valid_slug(slug)


def test_generate_slug_is_random() -> None:
    assert len({generate_slug() for _ in range(1000)}) > 990


def test_generate_slug_uses_secrets(monkeypatch: pytest.MonkeyPatch) -> None:
    calls: list[str] = []

    def fake_choice(seq: str) -> str:
        calls.append(seq)
        return "a"

    monkeypatch.setattr("app.services.slug.secrets.choice", fake_choice)
    assert generate_slug() == "a" * SLUG_LENGTH
    assert calls == [SLUG_ALPHABET] * SLUG_LENGTH


@pytest.mark.parametrize("slug", ["abc1234", "ABCDEFG", "0000000", "zZ9aA0b"])
def test_valid(slug: str) -> None:
    assert is_valid_slug(slug)


@pytest.mark.parametrize(
    "slug",
    [
        "",
        "abc123",
        "abc12345",
        "abc-123",
        "abc_123",
        "abc 123",
        "abc123\n",
        "ábc1234",
        "abc123é",
        "１２３４５６７",  # dígitos de ancho completo
        "abc/123",
    ],
)
def test_invalid(slug: str) -> None:
    assert not is_valid_slug(slug)


@pytest.mark.parametrize("value", [None, 1234567, b"abc1234", ["a"] * 7])
def test_non_str_is_invalid(value: object) -> None:
    assert not is_valid_slug(value)
