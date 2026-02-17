# Diary 구현 사전 점검 (2026-02-15)

## 1) 현재 메타데이터 저장 흐름

- 촬영 저장:
  - `/Users/mark/Desktop/자료/app/펫그램/lib/pages/home_page.dart`
  - `_buildCurrentPhotoMeta()`로 `PetgramPhotoMeta` 생성
  - EXIF(UserComment) 작성 시도 후, DB `petgram_photos`에 `upsertPhotoRecord` 저장
- 필터 저장:
  - `/Users/mark/Desktop/자료/app/펫그램/lib/pages/filter_page.dart`
  - `buildMetaForFilterSave()`로 원본 메타를 최대한 유지하여 편집본 메타 생성
  - EXIF 작성 후 DB에 `upsertPhotoRecord` 저장
- DB 스키마:
  - `/Users/mark/Desktop/자료/app/펫그램/lib/services/petgram_db.dart`
  - 테이블: `petgram_photos`
  - 핵심 컬럼: `file_path`, `taken_at`, `frame_key`, `meta_json`, `exif_tag`

## 2) 이번 준비 작업

- 다이어리 전용 조회 메서드 추가:
  - `/Users/mark/Desktop/자료/app/펫그램/lib/services/petgram_photo_repository.dart`
  - `listForDiary(limit, petgramOnly)` 추가
  - 정렬 기준을 `taken_at DESC, created_at DESC`로 분리
- 다이어리 UI용 모델 추가:
  - `/Users/mark/Desktop/자료/app/펫그램/lib/models/diary_entry.dart`
- 다이어리 읽기 서비스 추가:
  - `/Users/mark/Desktop/자료/app/펫그램/lib/services/diary_service.dart`
  - DB 레코드에서 `petName`, `petId`, `location`, `frameKey`를 추출
- 조회 정확도 보완:
  - `getByFileNamePattern()`의 LIKE 패턴을 `%PG_xxx.%`로 변경

## 3) 리팩토링 우선 후보 (기능 영향 최소화 순)

1. `home_page.dart`/`filter_page.dart`의 DB 저장 호출 중복을 서비스 레이어로 통합
2. `file_path`가 "파일명" 또는 "절대 경로"가 혼재하는 정책 명문화
3. 다이어리 썸네일 로딩 실패 대비(파일 미존재/권한) fallback UI 공통화
4. 다이어리 정렬/필터 기준(촬영일, 펫별, 프레임별) 쿼리 메서드 분리

## 4) 실제 다이어리 구현 권장 순서

1. `DiaryService.loadRecentEntries()` 기반 목록 UI 연결
2. 썸네일 로딩 정책 확정(갤러리 파일명 vs 임시 파일 경로)
3. 항목 상세(촬영일, 펫 이름, 위치, 프레임 키) 표시
4. 빈 상태/에러 상태/권한 상태 분리
5. 성능 확인(초기 로딩, 스크롤 중 이미지 디코딩)

## 5) 주의사항

- 기존 촬영/필터 저장 파이프라인은 변경하지 말고, 다이어리는 읽기 전용으로 시작
- EXIF 실패 케이스가 있어도 DB에는 메타가 남도록 되어 있으므로 DB를 1차 소스로 사용
- DB 스키마 변경은 이번 단계에서 제외 (기능 안정성 우선)
