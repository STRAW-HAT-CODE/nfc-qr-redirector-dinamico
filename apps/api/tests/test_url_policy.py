import pytest

from app.services.url_policy import (
    MAX_URL_LENGTH,
    UrlPolicyError,
    validate_destination,
)

BASE = "https://go.monky.dev"


def check(url: str, **kw: object) -> str:
    kw.setdefault("redirector_base_url", BASE)
    return validate_destination(url, **kw)  # type: ignore[arg-type]


def code_of(url: str, **kw: object) -> str:
    with pytest.raises(UrlPolicyError) as exc:
        check(url, **kw)
    assert exc.value.message
    return exc.value.code


@pytest.mark.parametrize(
    ("url", "expected"),
    [
        ("https://example.com", "https://example.com"),
        ("http://example.com/a/b?x=1#f", "http://example.com/a/b?x=1#f"),
        ("HTTPS://Example.COM/Path", "https://example.com/Path"),
        ("HtTp://example.com", "http://example.com"),
        ("  https://example.com/  ", "https://example.com/"),
        ("https://example.com.", "https://example.com"),
        ("https://example.com:8443/x", "https://example.com:8443/x"),
        ("https://8.8.8.8/", "https://8.8.8.8/"),
        ("https://[2606:4700:4700::1111]/", "https://[2606:4700:4700::1111]/"),
        ("https://münchen.de/straße", "https://xn--mnchen-3ya.de/straße"),
        ("https://sub.example.com", "https://sub.example.com"),
        ("https://notmonky.dev", "https://notmonky.dev"),
    ],
)
def test_valid(url: str, expected: str) -> None:
    assert check(url) == expected


@pytest.mark.parametrize(
    "url",
    [
        "javascript:alert(1)",
        "JAVASCRIPT:alert(1)",
        "data:text/html,<script>alert(1)</script>",
        "ftp://example.com",
        "file:///etc/passwd",
        "mailto:a@b.com",
        "//example.com",
        "example.com",
        "gopher://example.com",
        "ws://example.com",
    ],
)
def test_scheme_not_allowed(url: str) -> None:
    assert code_of(url) == "url_scheme_not_allowed"


@pytest.mark.parametrize(
    "url",
    [
        "http://user@evil.com",
        "http://user:pass@evil.com",
        "https://:pass@evil.com",
        "https://example.com@evil.com",
        "https://evil.com\\@example.com",
    ],
)
def test_credentials_rejected(url: str) -> None:
    assert code_of(url) in {"url_credentials_not_allowed", "url_invalid"}


def test_credentials_code() -> None:
    assert code_of("http://user:pass@example.com") == "url_credentials_not_allowed"


@pytest.mark.parametrize(
    "url",
    [
        "http://localhost",
        "http://LOCALHOST:3000/x",
        "http://localhost./",
        "http://foo.localhost",
        "http://127.0.0.1",
        "http://127.1",
        "http://127.0.1",
        "http://2130706433",
        "http://0x7f000001",
        "http://0X7F.0.0.1",
        "http://0177.0.0.1",
        "http://017700000001",
        "http://0x7f.1",
        "http://0",
        "http://0.0.0.0",
        "http://10.0.0.1",
        "http://10.1",
        "http://172.16.0.1",
        "http://172.31.255.255",
        "http://192.168.1.1",
        "http://169.254.169.254",
        "http://100.64.0.1",
        "http://224.0.0.1",
        "http://255.255.255.255",
        "http://[::1]",
        "http://[::1]:8080/",
        "http://[::]",
        "http://[::ffff:127.0.0.1]",
        "http://[::ffff:7f00:1]",
        "http://[::ffff:10.0.0.1]",
        "http://[fe80::1]",
        "http://[fc00::1]",
        "http://[fd12:3456::1]",
        "http://[2002:7f00:1::]",
        "http://[ff02::1]",
        "http://printer.local",
        "http://db.internal",
        "http://a.b.INTERNAL",
        "http://intranet",
        "http://127.0.0.1.",
    ],
)
def test_private_host(url: str) -> None:
    assert code_of(url) == "url_private_host"


@pytest.mark.parametrize(
    "url",
    [
        "http://",
        "https://",
        "http:///path",
        "http://:80",
        "http://example.com:99999",
        "http://example.com:abc",
        "http://256.256.256.256",
        "http://1.2.3.4.5",
        "http://089.1.1.1",
        "http://[::1",
        "http://[zzz]",
        "http://[fe80::1%25eth0]",
        "http://exa mple.com",
        "http://exa\x00mple.com",
        "http://example.com/a b",
        "http://a..b",
        "http://-.com/" + "\u0000",
    ],
)
def test_invalid(url: str) -> None:
    assert code_of(url) == "url_invalid"


@pytest.mark.parametrize("url", ["", "   ", "\t"])
def test_empty(url: str) -> None:
    assert code_of(url) == "url_invalid"


def test_too_long() -> None:
    prefix = "https://example.com/"
    assert check(prefix + "a" * (MAX_URL_LENGTH - len(prefix))).startswith(prefix)
    assert code_of(prefix + "a" * (MAX_URL_LENGTH - len(prefix) + 1)) == "url_too_long"


@pytest.mark.parametrize(
    "url",
    [
        "https://go.monky.dev",
        "https://go.monky.dev/abc1234",
        "https://GO.MONKY.DEV/abc1234",
        "http://go.monky.dev:8080/x",
        "https://go.monky.dev./x",
        "https://a.go.monky.dev/x",
    ],
)
def test_self_redirect(url: str) -> None:
    assert code_of(url) == "url_self_redirect"


def test_self_redirect_other_hosts_allowed() -> None:
    assert check("https://monky.dev/x") == "https://monky.dev/x"
    assert check("https://evilgo.monky.dev") == "https://evilgo.monky.dev"


def test_self_redirect_uses_settings(monkeypatch: pytest.MonkeyPatch) -> None:
    from app.core.config import Settings, get_settings

    get_settings.cache_clear()
    monkeypatch.setattr(
        "app.services.url_policy.get_settings",
        lambda: Settings(public_redirect_base_url="https://r.example.org"),
    )
    with pytest.raises(UrlPolicyError) as exc:
        validate_destination("https://r.example.org/x")
    assert exc.value.code == "url_self_redirect"
    assert validate_destination("https://example.org/") == "https://example.org/"


def test_self_redirect_skipped_when_unconfigured() -> None:
    assert check("https://go.monky.dev/x", redirector_base_url="") == "https://go.monky.dev/x"


@pytest.mark.parametrize(
    "url",
    [
        "https://evil.com",
        "https://EVIL.com/x",
        "https://www.evil.com",
        "https://a.b.evil.com/x",
        "https://evil.com.",
        "https://xn--mnchen-3ya.de",
        "https://münchen.de",
    ],
)
def test_blocked_domain(url: str) -> None:
    blocked = frozenset({"evil.com", " .XN--MNCHEN-3YA.de. "})
    assert code_of(url, blocked_domains=blocked) == "url_blocked_domain"


@pytest.mark.parametrize("url", ["https://notevil.com", "https://evil.com.mx", "https://evil.co"])
def test_blocklist_no_false_positive(url: str) -> None:
    assert check(url, blocked_domains=frozenset({"evil.com"})) == url


def test_default_blocklist_does_not_block() -> None:
    assert check("https://evil.com") == "https://evil.com"


def test_error_attributes() -> None:
    err = UrlPolicyError("url_invalid", "msg")
    assert (err.code, err.message, str(err)) == ("url_invalid", "msg", "msg")
    assert isinstance(err, ValueError)


def test_idempotent() -> None:
    once = check("HTTPS://münchen.de:443/x?y=1")
    assert check(once) == once


@pytest.mark.parametrize(
    ("entry", "url"),
    [
        ("ejemplo-ñ.com", "https://ejemplo-ñ.com/x"),
        ("EJEMPLO-Ñ.com", "https://sub.xn--ejemplo--k3a.com"),
        ("xn--ejemplo--k3a.com", "https://ejemplo-ñ.com"),
        (".ejemplo-ñ.com.", "https://www.ejemplo-ñ.com"),
    ],
)
def test_blocked_domain_idn_entries(entry: str, url: str) -> None:
    assert code_of(url, blocked_domains=frozenset({entry})) == "url_blocked_domain"


def test_blocklist_ignores_unencodable_entries() -> None:
    bad = frozenset({"a" * 64 + ".com", "a..b", "", "  ", "evil.com"})
    assert code_of("https://evil.com", blocked_domains=bad) == "url_blocked_domain"
    assert check("https://example.com", blocked_domains=bad) == "https://example.com"


def test_self_redirect_idn_base_url() -> None:
    assert code_of("https://ejemplo-ñ.com/x", redirector_base_url="https://ejemplo-ñ.com") == (
        "url_self_redirect"
    )
