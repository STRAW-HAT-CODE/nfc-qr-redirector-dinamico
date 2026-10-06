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


@lru_cache
def get_settings() -> Settings:
    return Settings()
