# 필터 페이지 코드 정리 계획

## 정리 대상

### 1. Deprecated 메서드 (안전하게 제거 가능)
- ✅ `_applyColorMatrixToImage()` - GPU 렌더 사용으로 대체됨
- ✅ `_applyColorMatrixToImageDirect()` - 위 메서드의 헬퍼
- ✅ `_applySharpen()` - GPU 렌더 사용으로 대체됨
- ✅ `_applySharpenDirect()` - 위 메서드의 헬퍼
- ✅ `_buildFilteredImageContent()` - `_buildImageView()`로 대체됨
- ✅ `_buildCategoryTabs()` - `_buildCategoryTabsForPanel()`로 대체됨
- ✅ `_buildFilterButtons()` - `_buildFilterButtonsForPanel()`로 대체됨
- ✅ `_buildIntensityControls()` - 패널 내부 슬라이더로 대체됨
- ✅ `_buildPetDetailAdjustSection()` - 개별 슬라이더로 대체됨

### 2. 사용되지 않는 메서드
- ✅ `_getImageSize()` - 더 이상 사용되지 않음
- ✅ `_convertImgImageToUiImage()` - 사용되지 않음
- ✅ `_applyColorMatrixToUiImageGpu()` - 사용되지 않음

### 3. 사용되지 않는 필드
- ✅ `_previewKey` - 사용되지 않음
- ✅ `_cachedPreviewMatrix` - 사용되지 않음
- ✅ `_cachedThumbnailBytes` - 사용되지 않음
- ✅ `_imagePipelineService` - 사용되지 않음 (네이티브 서비스만 사용)

### 4. Deprecated 메서드 (다른 곳에서 참조되는지 확인 필요)
- ⚠️ `_changeImage()` - 다른 메서드에서 호출되는지 확인 필요
- ⚠️ `_initImage()` - 다른 메서드에서 호출되는지 확인 필요
- ⚠️ `_loadThumbnail()` - 다른 메서드에서 호출되는지 확인 필요
- ⚠️ `_applyFilterToPreview()` - 다른 메서드에서 호출되는지 확인 필요

## 정리 전략

1. **안전한 제거**: Deprecated로 표시되고 더 이상 호출되지 않는 메서드/필드
2. **보수적 접근**: 다른 메서드에서 호출될 가능성이 있는 경우 주석 처리
3. **유지**: 정적 메서드(`_applyColorMatrixToImageStatic`, `_applySharpenStatic`)는 isolate에서 사용될 수 있으므로 유지

## 정리 순서

1. 사용되지 않는 필드 제거
2. Deprecated 메서드 제거 (확실히 사용되지 않는 것만)
3. 정적 메서드는 유지 (isolate에서 사용 가능)

