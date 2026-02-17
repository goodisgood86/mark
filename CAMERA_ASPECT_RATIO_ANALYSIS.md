# 카메라 프리뷰 비율 로직 분석

## 현재 구조 분석

### 1. 카메라 비율 가져오기 (3240-3259줄)
```dart
double cameraAspectRatio = (9 / 16); // 기본값
if (!_useMockCamera &&
    _cameraController != null &&
    _cameraController!.value.isInitialized) {
  final actualRatio = _cameraController!.value.aspectRatio;
  if (actualRatio > 0) {
    cameraAspectRatio = actualRatio; // ✅ 실제 카메라 비율 사용
  }
}
```
**✅ 정상**: 카메라 컨트롤러에서 실제 비율을 가져옵니다.

### 2. 프리뷰 크기 계산 (3269-3276줄)
```dart
double actualPreviewW = maxWidth;
double actualPreviewH = actualPreviewW / cameraAspectRatio;

if (actualPreviewH > maxHeight) {
  actualPreviewH = maxHeight;
  actualPreviewW = actualPreviewH * cameraAspectRatio;
}
```
**✅ 정상**: 카메라 비율에 맞춰 프리뷰 크기를 계산합니다.

### 3. AspectRatio 적용 (3336-3337줄)
```dart
child: AspectRatio(
  aspectRatio: cameraAspectRatio,
  child: Stack(
    children: [
      Positioned.fill(
        child: CameraPreview(_cameraController!)
      )
    ]
  )
)
```

## ⚠️ 잠재적 문제점

### 문제 1: 이중 비율 적용
- `CameraPreview`는 **내부적으로** 카메라의 실제 비율을 유지하려고 합니다
- 외부에서 `AspectRatio`로 감싸면, 비율이 **이중으로 적용**될 수 있습니다
- 만약 `cameraAspectRatio` 값이 실제 카메라 비율과 **정확히 일치**한다면 문제없지만, **약간의 차이**가 있으면 왜곡이 발생할 수 있습니다

### 문제 2: 비율 값의 정확성
- `_cameraController!.value.aspectRatio`는 카메라가 초기화된 직후에 정확한 값을 반환합니다
- 하지만 카메라 전환 시나 특정 상황에서 값이 업데이트되지 않을 수 있습니다
- 디버그 로그를 확인하여 실제 비율이 제대로 반영되는지 확인 필요

## ✅ 해결 방법

### 옵션 1: AspectRatio 제거 (권장)
`CameraPreview`가 자체적으로 비율을 유지하므로, `AspectRatio`를 제거하고 `CameraPreview`가 자연스럽게 비율을 유지하도록 합니다.

```dart
child: ClipRect(
  child: Stack(
    // CameraPreview가 자체 비율 유지
    children: [
      Positioned.fill(
        child: CameraPreview(_cameraController!)
      )
    ]
  )
)
```

### 옵션 2: FittedBox 사용
`FittedBox`를 사용하여 비율을 유지하면서 크기를 조정합니다.

```dart
child: ClipRect(
  child: FittedBox(
    fit: BoxFit.cover,
    child: SizedBox(
      width: actualPreviewW,
      height: actualPreviewW / cameraAspectRatio,
      child: CameraPreview(_cameraController!)
    )
  )
)
```

### 옵션 3: 현재 구조 유지 (조건부)
현재 구조를 유지하되, 다음을 확인:
1. `cameraAspectRatio` 값이 실제 카메라 비율과 정확히 일치하는지
2. 디버그 로그에서 비율 값이 올바르게 출력되는지
3. 실기기에서 왜곡이 발생하는지

## 🔍 확인 사항

1. **디버그 로그 확인**:
   - `[Petgram] 📐 카메라 초기화 완료 - 실제 비율: ...`
   - `[Petgram] 📐 _buildCameraStack: 실제 카메라 비율 사용 - ...`
   - 이 값들이 일치하는지 확인

2. **실기기 테스트**:
   - 프리뷰가 왜곡 없이 표시되는지
   - 촬영된 이미지와 프리뷰가 일치하는지

3. **카메라 전환 테스트**:
   - 전면/후면 카메라 전환 시 비율이 올바르게 유지되는지

## 📝 결론

현재 구조는 **이론적으로는 정상**이지만, `AspectRatio`와 `CameraPreview`의 이중 적용으로 인해 **왜곡이 발생할 수 있습니다**.

**권장 사항**: `AspectRatio`를 제거하고 `CameraPreview`가 자체적으로 비율을 유지하도록 수정하는 것이 가장 안전합니다.

