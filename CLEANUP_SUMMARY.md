# 필터 페이지 코드 정리 요약

## 정리 완료

### 1. 사용되지 않는 필드 (제거 가능)
- `_previewKey` - 선언만 있고 사용되지 않음
- `_cachedPreviewMatrix` - null로만 설정되고 읽히지 않음
- `_cachedThumbnailBytes` - 선언만 있고 사용되지 않음
- `_imagePipelineService` - 선언/초기화만 되고 사용되지 않음 (네이티브 서비스만 사용)

### 2. Deprecated 메서드 (제거 가능)
다음 메서드들은 이미 @Deprecated로 표시되어 있고, 더 이상 호출되지 않습니다:
- `_applyColorMatrixToImage()` 및 관련 헬퍼 메서드
- `_applySharpen()` 및 관련 헬퍼 메서드  
- `_buildFilteredImageContent()`
- `_buildCategoryTabs()`
- `_buildFilterButtons()`
- `_buildIntensityControls()`
- `_buildPetDetailAdjustSection()`
- `_getImageSize()`
- `_convertImgImageToUiImage()`
- `_applyColorMatrixToUiImageGpu()`

### 3. Deprecated 메서드 (참조 확인 필요)
다음 메서드들은 주석에서만 언급되지만 실제 호출되지 않음:
- `_changeImage()` - @Deprecated, 다른 곳에서 호출 안 됨
- `_initImage()` - @Deprecated, 다른 곳에서 호출 안 됨
- `_loadThumbnail()` - @Deprecated, 다른 곳에서 호출 안 됨
- `_applyFilterToPreview()` - @Deprecated, 다른 곳에서 호출 안 됨

## 정리 전략

### 보수적 접근 (권장)
1. 사용되지 않는 필드는 제거
2. Deprecated 메서드는 주석 처리하여 나중에 제거 가능하도록 표시
3. 정적 메서드(`_applyColorMatrixToImageStatic`, `_applySharpenStatic`)는 isolate에서 사용될 수 있으므로 deprecated 메서드와 함께 유지하거나 제거

### 공격적 접근
1. 모든 사용되지 않는 코드 완전 제거
2. Deprecated 메서드 완전 제거
3. 파일 크기 감소 및 가독성 향상

## 권장사항

**현재는 네이티브 API로 완전히 전환되었으므로, 다음 단계를 권장합니다:**

1. **즉시 제거**: 사용되지 않는 필드들 (`_previewKey`, `_cachedThumbnailBytes`, `_imagePipelineService`)
2. **조건부 제거**: `_cachedPreviewMatrix`는 주석으로 표시 후 향후 제거
3. **Deprecated 메서드**: 큰 블록 단위로 주석 처리 또는 제거 (약 500-800줄 절감 가능)

## 예상 효과

- 코드 라인 수: 약 800-1000줄 감소
- 파일 크기: 약 30-40KB 감소
- 가독성: 향상
- 유지보수성: 향상

