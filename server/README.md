# Petgram Backup Server (FastAPI)

## 왜 이 서버?
- 클라이언트가 이미 커스텀 API(`/auth/social`, `/backup/upload`, `/backup/latest`)를 사용
- Google/Apple/Naver 로그인 결과를 단일 사용자로 매핑 가능
- PostgreSQL 1개 테이블 세트로 백업 저장 단순화

## 추천 배포
- Railway (FastAPI + PostgreSQL)

## 로컬 실행
1. 가상환경
```bash
cd server
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

2. 환경변수
```bash
cp .env.example .env
```

3. DB 스키마 적용
```bash
psql "$DATABASE_URL" -f sql/schema.sql
```

4. 서버 실행
```bash
uvicorn src.main:app --host 0.0.0.0 --port 8080 --reload
```

## API
- `POST /auth/social`
- `POST /backup/upload`
- `GET /backup/latest?user_id=...`
- `GET /health`

## 주의
- `STRICT_SOCIAL_VERIFY=false`는 개발용입니다.
- 운영에서는 `true`로 켜고 provider 토큰 검증 로직을 강화하세요.
