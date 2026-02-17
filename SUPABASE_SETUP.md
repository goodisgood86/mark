# Supabase 설정 가이드

## 1) 프로젝트 생성
- Supabase에서 새 프로젝트 생성
- `Project URL`, `anon public key` 확인

## 2) Auth Provider
- Authentication > Providers
- Google, Apple 활성화
- Redirect URL에 아래 추가
  - `io.supabase.flutter://login-callback/`

## 3) SQL 실행
아래 SQL을 Supabase SQL Editor에서 실행

```sql
create table if not exists public.user_backups (
  user_id uuid primary key references auth.users(id) on delete cascade,
  backup_json jsonb not null,
  updated_at timestamptz not null default now()
);

alter table public.user_backups enable row level security;

create policy if not exists "read own backup"
on public.user_backups
for select
using (auth.uid() = user_id);

create policy if not exists "upsert own backup"
on public.user_backups
for insert
with check (auth.uid() = user_id);

create policy if not exists "update own backup"
on public.user_backups
for update
using (auth.uid() = user_id)
with check (auth.uid() = user_id);

create policy if not exists "delete own backup"
on public.user_backups
for delete
using (auth.uid() = user_id);
```

추가로 "진짜 회원탈퇴(Auth 사용자 삭제 + 백업 삭제)"는 Edge Function으로 처리합니다.
앱은 `delete-account` 함수를 호출하도록 되어 있습니다.

```bash
# 함수 시크릿 설정
supabase secrets set \
  SUPABASE_URL=https://YOUR_PROJECT_REF.supabase.co \
  SUPABASE_SERVICE_ROLE_KEY=YOUR_SERVICE_ROLE_KEY

# 탈퇴 함수 배포
supabase functions deploy delete-account
```

## 4) 앱 실행 설정(dart-define)
- 사용자 입력 없이 앱에 Supabase 값을 주입해서 실행합니다.
- 실행 예시:

```bash
flutter run \
  --dart-define=SUPABASE_URL=https://YOUR_PROJECT_REF.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=YOUR_ANON_KEY
```

- 릴리즈/CI도 동일하게 `SUPABASE_URL`, `SUPABASE_ANON_KEY`를 주입해야 합니다.

## 5) 동작
- Google/Apple 로그인 후
- `Supabase 업로드` : 현재 한줄일기/태그/사진메타 업로드
- `Supabase 복원` : 서버 데이터 복원

## 참고
- Naver 로그인은 Supabase 기본 OAuth provider에 직접 없음 (추후 OIDC 커스텀 연동 필요)
