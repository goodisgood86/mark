# GitHub 저장소 설정 가이드

## GitHub 저장소 URL 확인 방법

### 1. GitHub 웹사이트에서 확인
1. https://github.com 접속
2. 로그인 후 우측 상단 프로필 클릭
3. "Your repositories" 클릭
4. 저장소 목록에서 해당 저장소 클릭
5. 저장소 페이지에서 초록색 "Code" 버튼 클릭
6. HTTPS 또는 SSH URL 복사

### 2. 새 저장소 만들기 (아직 없다면)
1. https://github.com 접속
2. 우측 상단 "+" 버튼 클릭 → "New repository"
3. Repository name 입력 (예: `mark_v2` 또는 `petgram`)
4. Public 또는 Private 선택
5. "Create repository" 클릭
6. 생성된 페이지에서 URL 복사

## 저장소 URL 형식
- **HTTPS**: `https://github.com/사용자명/저장소명.git`
- **SSH**: `git@github.com:사용자명/저장소명.git`

## 저장소 설정 명령어

### 저장소 URL을 알고 있다면:
```bash
cd /Users/grepp/mark_v2
git remote add origin <저장소_URL>
git push -u origin main
```

### 예시:
```bash
# HTTPS 사용
git remote add origin https://github.com/grepp/mark_v2.git
git push -u origin main

# 또는 SSH 사용 (SSH 키 설정된 경우)
git remote add origin git@github.com:grepp/mark_v2.git
git push -u origin main
```

## 현재 상태
- ✅ 커밋 완료: `Release v1.0.0+7`
- ⏳ Remote 설정 필요: GitHub 저장소 URL 필요

