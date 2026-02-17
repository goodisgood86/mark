# 카메라 프리뷰 비율 로직 분석

## 현재 구조 (수정 후)

### 1. 카메라 비율 가져오기 ✅
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

### 2. 프리뷰 크기 계산 ✅
```dart
double actualPreviewW = maxWidth;
double actualPreviewH = actualPreviewW / cameraAspectRatio;

if (actualPreviewH > maxHeight) {
  actualPreviewH = maxHeight;
  actualPreviewW = actualPreviewH * cameraAspectRatio;
}
```
**정상**: 카메라 비율에 맞춰 프리뷰 크기를 계산합니다.

### 3. CameraPreview 배치 (수정 후) ✅
```dart
Positioned(
  left: offsetX,
  top: offsetY,
  width: actualPreviewW,
  height: actualPreviewH,
  child: ClipRect(
    child: Stack(
      children: [
        Positioned.fill(
          child: CameraPreview(_cameraController!)
        )
      ]
    )
  )
)
```

## ⚠️ 잠재적 문제점

### 문제: Positioned.fill로 인한 강제 크기
- `Positioned.fill`은 `CameraPreview`를 부모의 크기(actualPreviewW x actualPreviewH)에 맞춰 강제로 늘립니다
- `CameraPreview`는 내부적으로 카메라의 실제 비율을 유지하려고 하지만, 외부에서 크기를 강제하면 왜곡이 발생할 수 있습니다

### 해결 방법
`CameraPreview`가 자체 비율을 유지하도록 `Center`로 감싸고, `AspectRatio`를 사용하거나, `FittedBox`를 사용해야 합니다.

## ✅ 권장 수정 사항

### 옵션 1: AspectRatio 사용 (권장)
```dart
Positioned(
  left: offsetX,
  top: offsetY,
  width: actualPreviewW,
  height: actualPreviewH,
  child: ClipRect(
    child: Center(
      child: AspectRatio(
        aspectRatio: cameraAspectRatio, // 실제 카메라 비율
        child: Stack(
          children: [
            Positioned.fill(
              child: CameraPreview(_cameraController!)
            )
          ]
        )
      )
    )
  )
)
```

### 옵션 2: FittedBox 사용
```dart
Positioned(
  left: offsetX,
  top: offsetY,
  width: actualPreviewW,
  height: actualPreviewH,
  child: ClipRect(
    child: FittedBox(
      fit: BoxFit.contain, // 비율 유지하면서 크기 조정
      child: SizedBox(
        width: actualPreviewW,
        height: actualPreviewW / cameraAspectRatio,
        child: CameraPreview(_cameraController!)
      )
    )
  )
)
```

## 📝 결론

현재 구조는 **이론적으로는 정상**이지만, `Positioned.fill`로 인해 `CameraPreview`의 비율이 강제될 수 있습니다.

**권장 사항**: `Center`와 `AspectRatio`를 사용하여 `CameraPreview`가 카메라의 실제 비율을 유지하도록 수정하는 것이 가장 안전합니다.

