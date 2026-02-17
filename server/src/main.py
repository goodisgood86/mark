from datetime import datetime, timedelta, timezone
import json
import hashlib
import secrets
from typing import Any, Dict, Optional

import requests
from fastapi import Depends, FastAPI, Header, HTTPException
from jose import jwt
from pydantic import BaseModel, Field

from config import Settings, load_settings
from db import Database


settings: Settings = load_settings()
db = Database(settings.database_url)
app = FastAPI(title="Petgram Backup API", version="1.0.0")


class SocialAuthRequest(BaseModel):
    provider: str = Field(pattern="^(google|apple|naver)$")
    provider_user_id: str
    id_token: Optional[str] = None
    access_token: Optional[str] = None
    email: Optional[str] = None
    display_name: Optional[str] = None


class SocialAuthResponse(BaseModel):
    user_id: str
    access_token: str
    backup_key: str
    refresh_token: Optional[str] = None
    expires_at: str


class UploadRequest(BaseModel):
    user_id: str
    backup_version: int
    created_at: str
    encryption: Dict[str, Any]


def _utc_now() -> datetime:
    return datetime.now(timezone.utc)


def _make_app_user_id(provider: str, provider_user_id: str) -> str:
    digest = hashlib.sha256(f"{provider}:{provider_user_id}".encode("utf-8")).hexdigest()
    return f"u_{digest[:24]}"


def _make_backup_key(provider: str, provider_user_id: str) -> str:
    seed = f"bk|{provider}|{provider_user_id}|{secrets.token_urlsafe(24)}"
    return hashlib.sha256(seed.encode("utf-8")).hexdigest()


def _verify_google(identity: SocialAuthRequest) -> None:
    if not identity.id_token:
        raise HTTPException(status_code=401, detail="google id_token is required")
    res = requests.get(
        "https://oauth2.googleapis.com/tokeninfo",
        params={"id_token": identity.id_token},
        timeout=8,
    )
    if res.status_code != 200:
        raise HTTPException(status_code=401, detail="invalid google id_token")
    payload = res.json()
    sub = str(payload.get("sub", "")).strip()
    if not sub or sub != identity.provider_user_id:
        raise HTTPException(status_code=401, detail="google provider_user_id mismatch")


def _verify_naver(identity: SocialAuthRequest) -> None:
    if not identity.access_token:
        raise HTTPException(status_code=401, detail="naver access_token is required")
    res = requests.get(
        "https://openapi.naver.com/v1/nid/me",
        headers={"Authorization": f"Bearer {identity.access_token}"},
        timeout=8,
    )
    if res.status_code != 200:
        raise HTTPException(status_code=401, detail="invalid naver access_token")
    body = res.json()
    response = body.get("response", {})
    naver_id = str(response.get("id", "")).strip()
    if not naver_id or naver_id != identity.provider_user_id:
        raise HTTPException(status_code=401, detail="naver provider_user_id mismatch")


def _verify_apple(identity: SocialAuthRequest) -> None:
    # Apple 서버 검증은 JWKS/nonce/aud 검증이 필요하다.
    # 1차에서는 최소 검증(토큰 존재)만 수행하고, 운영 배포 전 JWKS 검증으로 교체 권장.
    if not identity.id_token:
        raise HTTPException(status_code=401, detail="apple id_token is required")


def _verify_social(identity: SocialAuthRequest) -> None:
    if not settings.strict_social_verify:
        return
    if identity.provider == "google":
        _verify_google(identity)
    elif identity.provider == "naver":
        _verify_naver(identity)
    elif identity.provider == "apple":
        _verify_apple(identity)


def _upsert_user(identity: SocialAuthRequest) -> Dict[str, Any]:
    app_user_id = _make_app_user_id(identity.provider, identity.provider_user_id)
    with db.cursor() as cur:
        cur.execute(
            """
            INSERT INTO users (
              app_user_id, provider, provider_user_id, email, display_name, backup_key
            ) VALUES (%s, %s, %s, %s, %s, %s)
            ON CONFLICT (provider, provider_user_id)
            DO UPDATE SET
              email = EXCLUDED.email,
              display_name = EXCLUDED.display_name,
              updated_at = NOW()
            RETURNING id, app_user_id, backup_key
            """,
            (
                app_user_id,
                identity.provider,
                identity.provider_user_id,
                identity.email,
                identity.display_name,
                _make_backup_key(identity.provider, identity.provider_user_id),
            ),
        )
        row = cur.fetchone()
        if not row:
            raise HTTPException(status_code=500, detail="failed to upsert user")
        return dict(row)


def _issue_access_token(user_id: str) -> tuple[str, str]:
    now = _utc_now()
    exp = now + timedelta(hours=settings.app_token_exp_hours)
    token = jwt.encode(
        {
            "sub": user_id,
            "iat": int(now.timestamp()),
            "exp": int(exp.timestamp()),
        },
        settings.app_token_secret,
        algorithm="HS256",
    )
    return token, exp.isoformat()


def _require_user_id(auth_header: Optional[str] = Header(default=None, alias="Authorization")) -> str:
    if not auth_header or not auth_header.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="missing bearer token")
    token = auth_header.removeprefix("Bearer ").strip()
    if not token:
        raise HTTPException(status_code=401, detail="empty bearer token")

    try:
        payload = jwt.decode(token, settings.app_token_secret, algorithms=["HS256"])
    except Exception as exc:
        raise HTTPException(status_code=401, detail="invalid bearer token") from exc

    user_id = str(payload.get("sub", "")).strip()
    if not user_id:
        raise HTTPException(status_code=401, detail="invalid token payload")
    return user_id


@app.get("/health")
def health() -> Dict[str, str]:
    return {"status": "ok"}


@app.post("/auth/social", response_model=SocialAuthResponse)
def auth_social(req: SocialAuthRequest) -> SocialAuthResponse:
    if not req.provider_user_id.strip():
        raise HTTPException(status_code=400, detail="provider_user_id is required")

    _verify_social(req)
    user = _upsert_user(req)
    access_token, expires_at = _issue_access_token(user["app_user_id"])

    return SocialAuthResponse(
        user_id=user["app_user_id"],
        access_token=access_token,
        backup_key=user["backup_key"],
        refresh_token=None,
        expires_at=expires_at,
    )


@app.post("/backup/upload")
def backup_upload(req: UploadRequest, token_user_id: str = Depends(_require_user_id)) -> Dict[str, str]:
    if req.user_id.strip() != token_user_id:
        raise HTTPException(status_code=403, detail="token user mismatch")

    with db.cursor() as cur:
        cur.execute("SELECT id FROM users WHERE app_user_id = %s", (req.user_id.strip(),))
        user = cur.fetchone()
        if not user:
            raise HTTPException(status_code=404, detail="user not found")

        try:
            created_at = datetime.fromisoformat(req.created_at.replace("Z", "+00:00"))
        except ValueError as exc:
            raise HTTPException(status_code=400, detail="invalid created_at") from exc

        cur.execute(
            """
            INSERT INTO backups (user_id, backup_version, created_at, encryption, uploaded_at)
            VALUES (%s, %s, %s, %s::jsonb, NOW())
            ON CONFLICT (user_id)
            DO UPDATE SET
              backup_version = EXCLUDED.backup_version,
              created_at = EXCLUDED.created_at,
              encryption = EXCLUDED.encryption,
              uploaded_at = NOW()
            """,
            (
                user["id"],
                req.backup_version,
                created_at,
                json.dumps(req.encryption),
            ),
        )

    return {"status": "ok"}


@app.get("/backup/latest")
def backup_latest(user_id: str, token_user_id: str = Depends(_require_user_id)) -> Dict[str, Any]:
    if user_id.strip() != token_user_id:
        raise HTTPException(status_code=403, detail="token user mismatch")

    with db.cursor() as cur:
        cur.execute(
            """
            SELECT b.backup_version, b.created_at, b.encryption
            FROM backups b
            JOIN users u ON u.id = b.user_id
            WHERE u.app_user_id = %s
            LIMIT 1
            """,
            (user_id.strip(),),
        )
        row = cur.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="backup not found")

        return {
            "backup_version": row["backup_version"],
            "created_at": row["created_at"].isoformat(),
            "encryption": row["encryption"],
        }
