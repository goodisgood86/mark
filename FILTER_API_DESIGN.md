# 필터 페이지 MethodChannel API 설계

## 📋 새로운 MethodChannel API

### 1. `generateFilterThumbnails`
**목적**: 원본 이미지에 여러 필터를 적용한 썸네일을 일괄 생성

**파라미터**:
```dart
{
  'sourcePath': String,           // 원본 이미지 파일 경로
  'filterKeys': List<String>,     // 필터 키 목록 (예: ['basic_none', 'basic_soft', ...])
  'thumbnailMaxSize': int,        // 최대 해상도 (예: 320 또는 512)
  'config': {                     // 공통 필터 설정 (선택적)
    'intensity': double,          // 필터 강도 (기본값: 0.8)
    'editBrightness': double,     // 밝기 (-50 ~ +50, 기본값: 0.0)
    'editContrast': double,       // 대비 (-50 ~ +50, 기본값: 0.0)
    'editSharpness': double,      // 선명도 (0 ~ 100, 기본값: 0.0)
    'petToneId': String?,         // 펫톤 ID (선택적)
    'enablePetToneOnSave': bool,  // 펫톤 적용 여부 (기본값: false)
  },
  'aspectMode': String?,          // 화면 비율 모드 ('oneOne', 'threeFour', 'nineSixteen', null)
}
```

**반환값**:
```dart
List<Map<String, dynamic>> // 각 필터별 썸네일 정보
[
  {
    'filterKey': 'basic_none',
    'thumbnailPath': '/tmp/petgram/xxx_basic_none.jpg',
    'width': 320,
    'height': 320,
  },
  {
    'filterKey': 'basic_soft',
    'thumbnailPath': '/tmp/petgram/xxx_basic_soft.jpg',
    'width': 320,
    'height': 320,
  },
  ...
]
```

**에러 처리**:
- 일부 필터 썸네일 생성 실패 시 해당 필터만 제외하고 성공한 것만 반환
- 모든 필터 실패 시 빈 리스트 반환

### 2. `applyFilterToImage`
**목적**: 원본 이미지에 필터를 적용하여 최종 이미지 생성

**파라미터**:
```dart
{
  'sourcePath': String,           // 원본 이미지 파일 경로
  'config': {                     // 필터 설정
    'filterKey': String,          // 필터 키
    'intensity': double,          // 필터 강도
    'editBrightness': double,     // 밝기
    'editContrast': double,       // 대비
    'editSharpness': double,      // 선명도
    'petToneId': String?,         // 펫톤 ID
    'enablePetToneOnSave': bool,  // 펫톤 적용 여부
  },
  'aspectMode': String?,          // 화면 비율 모드
}
```

**반환값**:
```dart
{
  'resultPath': String,           // 생성된 이미지 파일 경로
  'width': int,                   // 이미지 너비
  'height': int,                  // 이미지 높이
}
```

**에러 처리**:
- 이미지 로드 실패: `FilterPipelineError.failedToLoadImage`
- 인코딩 실패: `FilterPipelineError.failedToEncode`
- 필터 적용 실패: `FilterPipelineError.failedToApplyFilter` (새로운 에러 타입)

## 🔧 구현 세부사항

### iOS 네이티브 (`FilterPipeline.swift`)

#### `generateFilterThumbnails()` 메서드
```swift
static func generateFilterThumbnails(
    sourcePath: String,
    filterKeys: [String],
    thumbnailMaxSize: Int,
    config: FilterConfigDict?,
    aspectMode: String?
) throws -> [[String: Any]]
```

**처리 순서**:
1. 원본 이미지 로드 (EXIF orientation 적용)
2. 각 필터 키에 대해:
   - 필터 매트릭스 적용
   - 공통 설정 (밝기/대비/선명도/펫톤) 적용
   - Aspect ratio 크롭 (선택적)
   - 썸네일 크기로 다운샘플링
   - JPEG 인코딩
   - 임시 파일로 저장
3. 성공한 썸네일 정보 반환

**최적화**:
- 원본 이미지는 한 번만 로드
- 필터 적용은 순차적으로 수행 (메모리 절약)
- 임시 파일은 앱 캐시 디렉토리에 저장

#### `applyFilterToImage()` 메서드
```swift
static func applyFilterToImage(
    sourcePath: String,
    config: FilterConfigDict,
    aspectMode: String?
) throws -> [String: Any]
```

**처리 순서**:
1. 원본 이미지 로드 (EXIF orientation 적용)
2. Aspect ratio 크롭 (선택적)
3. 필터 적용 (기존 `renderFullSize()` 로직 재사용)
4. 고해상도 유지 (2K 규칙 적용)
5. JPEG 인코딩
6. 임시 파일로 저장
7. 결과 정보 반환

### Flutter 서비스 (`NativeFilterService`)

#### `generateFilterThumbnails()` 메서드
```dart
Future<List<FilterThumbnailResult>> generateFilterThumbnails(
  String sourcePath,
  List<String> filterKeys, {
  int thumbnailMaxSize = 320,
  FilterConfig? baseConfig,
  AspectRatioMode? aspectMode,
})
```

**반환 타입**:
```dart
class FilterThumbnailResult {
  final String filterKey;
  final String thumbnailPath;
  final int width;
  final int height;
}
```

#### `applyFilterToImage()` 메서드
```dart
Future<FilterResult> applyFilterToImage(
  String sourcePath,
  FilterConfig config, {
  AspectRatioMode? aspectMode,
})
```

**반환 타입**:
```dart
class FilterResult {
  final String resultPath;
  final int width;
  final int height;
}
```

## 📌 주요 고려사항

1. **성능**:
   - 썸네일 생성은 백그라운드 스레드에서 수행
   - 진행 상태 표시 (선택적)

2. **메모리**:
   - 원본 이미지는 한 번만 로드
   - 썸네일 생성 후 즉시 해제

3. **일관성**:
   - 라이브 프리뷰, 썸네일, 최종 저장 모두 동일한 필터 로직 사용
   - `FilterPipeline.processImage()` 재사용

4. **에러 처리**:
   - 일부 실패 허용 (썸네일 생성 시)
   - 명확한 에러 메시지 제공

5. **임시 파일 관리**:
   - 앱 캐시 디렉토리 사용
   - 필요 시 정리 로직 제공

