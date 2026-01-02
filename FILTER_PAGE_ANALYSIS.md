# 필터 페이지 구조 분석 결과

## 📋 현재 필터 페이지 구조

### 1. 필터 목록 UI
- **위치**: `lib/pages/filter_page.dart` - `_buildFilterButtonsForPanel()` 메서드
- **현재 구조**:
  - 필터 버튼은 **아이콘과 라벨만** 표시 (썸네일 없음)
  - 각 필터 버튼: 72x60 크기, 아이콘 + 텍스트
  - 필터 선택 시 메인 프리뷰에만 적용

### 2. 메인 프리뷰
- **위치**: `lib/pages/filter_page.dart` - `_startPreviewLoad()` 메서드
- **현재 로직**:
  - `_nativeFilterService.renderPreview()` 사용
  - 필터 키, 강도, 펫톤 설정 등 적용
  - 1200px 이하 해상도로 최적화

### 3. 썸네일 생성
- **위치**: `lib/pages/filter_page.dart` - `_getImageSize()` 메서드
- **현재 사용**:
  - `_nativeFilterService.createThumbnail()` 사용
  - **이미지 크기 확인용으로만 사용** (2048px 이하)
  - **필터별 썸네일 생성은 없음**

### 4. 필터 데이터
- **위치**: `lib/models/filter_data.dart`
- **구조**:
  - `allFilters`: Map<String, PetFilter> - 필터 정의 (키, 라벨, 아이콘, 매트릭스)
  - `filtersByCategory`: Map<String, List<PetFilter>> - 카테고리별 필터 목록
  - 필터 매트릭스는 4x5 컬러 매트릭스 (20개 요소)

### 5. 네이티브 필터 파이프라인
- **위치**: `ios/Runner/FilterPipeline.swift`
- **기능**:
  - `renderPreview()`: 프리뷰 렌더링 (1200px 이하)
  - `renderFullSize()`: 최종 저장 렌더링 (2K 규칙 적용)
  - `createThumbnail()`: 썸네일 생성 (2048px 이하, EXIF rotation 적용)
  - 필터 매트릭스 적용, 펫톤 보정, 밝기/대비/선명도 적용

## 🎯 새로 필요한 기능

### 1. 필터별 썸네일 생성
- **목적**: 필터 목록 UI에서 각 필터의 미리보기 제공
- **요구사항**:
  - 원본 이미지에 각 필터를 적용한 썸네일 생성
  - 작은 크기 (예: 320x320 또는 512px 이하)로 최적화
  - 일괄 생성 (페이지 진입 시 한 번에)

### 2. 최종 필터 적용
- **목적**: 선택한 필터를 최종 이미지에 적용하여 저장
- **요구사항**:
  - 원본 이미지에 필터 적용
  - 고해상도 유지 (기존 `renderFullSize()` 로직 재사용)
  - EXIF 메타데이터 보존

## 📝 데이터 플로우

### 현재 플로우:
1. 필터 페이지 진입
   - 원본 이미지 경로 받음
   - `_nativeFilterService.renderPreview()` 호출하여 메인 프리뷰 생성
2. 필터 선택
   - 필터 키 변경
   - `_debouncePreviewUpdate()` → `renderPreview()` 재호출
3. 저장
   - `_nativeFilterService.renderFullSize()` 호출
   - 결과 파일 저장

### 목표 플로우:
1. 필터 페이지 진입
   - 원본 이미지 경로 받음
   - **`generateFilterThumbnails()` 호출하여 모든 필터 썸네일 생성**
   - 필터 목록 UI에 썸네일 표시
   - 메인 프리뷰 생성
2. 필터 선택
   - 필터 키 변경
   - 메인 프리뷰 업데이트 (기존 로직 유지)
3. 저장
   - **`applyFilterToImage()` 호출하여 최종 이미지 생성**
   - 결과 파일 저장

## 🔧 구현 계획

### Phase 1: iOS 네이티브 구현
1. `FilterPipeline.swift`에 `generateFilterThumbnails()` 메서드 추가
2. `FilterPipeline.swift`에 `applyFilterToImage()` 메서드 추가 (기존 `renderFullSize()` 재사용)
3. `FilterPipelineBridge.swift`에 MethodChannel 핸들러 추가

### Phase 2: Flutter 서비스 업데이트
1. `NativeFilterService`에 `generateFilterThumbnails()` 메서드 추가
2. `NativeFilterService`에 `applyFilterToImage()` 메서드 추가

### Phase 3: 필터 페이지 리팩터링
1. 필터 목록 UI에 썸네일 이미지 표시
2. 페이지 진입 시 썸네일 생성
3. 저장 시 `applyFilterToImage()` 사용

## 📌 주의사항

1. **성능**: 썸네일 생성은 백그라운드에서 수행하고 로딩 상태 표시
2. **일관성**: 라이브 프리뷰, 썸네일, 최종 저장 모두 동일한 필터 로직 사용
3. **에러 처리**: 썸네일 생성 실패 시 아이콘만 표시
4. **캐싱**: 동일한 이미지/필터 조합의 썸네일은 재사용

