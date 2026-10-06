from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Configuración solo por variables de entorno (docs/07-deploy.md)."""

    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    supabase_url: str = ""
    supabase_anon_key: str = ""
    supabase_service_role_key: str = ""  # solo servidor
    supabase_jwt_secret: str = ""
    public_redirect_base_url: str = ""
    ip_hash_salt: str = ""
    # Proxies confiables delante de la API (x-forwarded-for). 0 = ignorarlo; Vercel = 1.
    trusted_proxy_hops: int = 0
    # Rate limiting (DQR-T050). Token bucket: capacidad = ráfaga, recarga = límite/min.
    rate_limit_enabled: bool = True
    rate_limit_redirect_per_min: int = 60
    rate_limit_redirect_burst: int = 20
    rate_limit_api_per_min: int = 120
    rate_limit_api_burst: int = 40
    rate_limit_strict_per_min: int = 30  # POST /v1/orgs y POST /v1/links
    rate_limit_strict_burst: int = 10
    # Backend compartido opcional (Upstash Redis REST); sin ellas, memoria por instancia.
    upstash_redis_rest_url: str = ""
    upstash_redis_rest_token: str = ""


@lru_cache
def get_settings() -> Settings:
    return Settings()
