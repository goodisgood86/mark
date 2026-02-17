import os
from dataclasses import dataclass


@dataclass
class Settings:
    database_url: str
    app_token_secret: str
    app_token_exp_hours: int
    strict_social_verify: bool


def _env_bool(name: str, default: bool) -> bool:
    raw = os.getenv(name)
    if raw is None:
        return default
    return raw.strip().lower() in {"1", "true", "yes", "y", "on"}


def load_settings() -> Settings:
    database_url = os.getenv("DATABASE_URL", "").strip()
    if not database_url:
        raise RuntimeError("DATABASE_URL is required")

    app_token_secret = os.getenv("APP_TOKEN_SECRET", "").strip()
    if not app_token_secret:
        raise RuntimeError("APP_TOKEN_SECRET is required")

    exp_hours_raw = os.getenv("APP_TOKEN_EXP_HOURS", "24").strip()
    try:
        exp_hours = int(exp_hours_raw)
    except ValueError as exc:
        raise RuntimeError("APP_TOKEN_EXP_HOURS must be integer") from exc

    return Settings(
        database_url=database_url,
        app_token_secret=app_token_secret,
        app_token_exp_hours=exp_hours,
        strict_social_verify=_env_bool("STRICT_SOCIAL_VERIFY", False),
    )
