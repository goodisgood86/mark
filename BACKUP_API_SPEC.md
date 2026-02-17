# Petgram Backup API Spec (v1)

앱의 서버 백업/복원은 아래 3개 엔드포인트를 사용합니다.

## 공통
- Header
  - `Authorization: Bearer <token>`
  - `Content-Type: application/json`
  - `Accept: application/json`
- 암호화
  - 클라이언트는 `user_id + backup_key` 기반으로 AES-GCM 키를 생성해 payload를 암호화함
  - 서버는 `encryption` 필드를 그대로 저장/반환하면 됨 (복호화 불필요)

## 0) 소셜 로그인
- Method: `POST`
- Path: `/auth/social`

### Request Body
```json
{
  "provider": "google|apple|naver",
  "provider_user_id": "provider_user_id",
  "id_token": "optional_id_token",
  "access_token": "optional_access_token",
  "email": "optional@email.com",
  "display_name": "optional_name"
}
```

### Response Body
```json
{
  "user_id": "app_user_123",
  "access_token": "jwt_or_random_token",
  "backup_key": "stable_encryption_key_for_user",
  "refresh_token": "optional_refresh_token",
  "expires_at": "2026-02-16T13:00:00.000Z"
}
```

---

## 1) 백업 업로드
- Method: `POST`
- Path: `/backup/upload`

### Request Body
```json
{
  "user_id": "app_user_123",
  "backup_version": 1,
  "created_at": "2026-02-16T12:34:56.000Z",
  "encryption": {
    "alg": "AES_GCM_256",
    "nonce_b64": "...",
    "ciphertext_b64": "...",
    "mac_b64": "..."
  }
}
```

### Response
- 성공: `2xx`
- 실패: `4xx/5xx` + `{ "message": "..." }` 또는 `{ "error": "..." }`

---

## 2) 최신 백업 조회
- Method: `GET`
- Path: `/backup/latest?user_id=<id>`

### Response Body (권장)
```json
{
  "encryption": {
    "alg": "AES_GCM_256",
    "nonce_b64": "...",
    "ciphertext_b64": "...",
    "mac_b64": "..."
  }
}
```

암호화 payload 복호화 후의 평문 구조는 아래입니다.
```json
{
  "app": "petgram",
  "backup_version": 1,
  "created_at": "2026-02-16T12:34:56.000Z",
  "photos": [],
  "drafts": {},
  "prefs": {}
}
```

하위 호환:
- 서버가 기존 방식으로 `backup`(평문) 필드를 내려줘도 앱은 복원 가능
