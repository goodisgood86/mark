# 프리뷰 비율 왜곡 방지 구조 분석

## 현재 구조

```dart
Positioned(
  left: offsetX,
  top: offsetY,
  width: actualPreviewW,   // 계산된 크기
  height: actualPreviewH,  // 계산된 크기
  child: ClipRect(
    child: AspectRatio(
      aspectRatio: cameraAspectRatio,  // 실제 카메라 비율
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
```

## 구조적 분석

### ✅ 올바른 부분

1. **크기 계산 로직**
   ```dart
   if (cameraAspectRatio > 1.0) {
     // 가로가 더 긴 비율: 가로를 기준으로 계산
     actualPreviewW = maxWidth;
     actualPreviewH = actualPreviewW / cameraAspectRatio;
   } else {
     // 세로가 더 긴 비율: 세로를 기준으로 계산
     actualPreviewH = maxHeight;
     actualPreviewW = actualPreviewH * cameraAspectRatio;
   }
   ```
   - 이 로직은 **올바릅니다** ✅
   - `actualPreviewW / actualPreviewH = cameraAspectRatio` 보장

2. **AspectRatio 사용**
   - `AspectRatio(aspectRatio: cameraAspectRatio)` 사용
   - 비율 왜곡 방지 ✅

### ⚠️ 잠재적 문제점

1. **Positioned의 명시적 크기 vs AspectRatio**
   - `Positioned`가 `width: actualPreviewW, height: actualPreviewH`로 명시적 크기 지정
   - `AspectRatio`는 부모의 제약을 받아서 비율을 유지하려고 함
   - **이론적으로는 일치해야 하지만**, 부동소수점 오차로 인한 미세한 차이가 발생할 수 있음

2. **AspectRatio의 동작 방식**
   - `AspectRatio`는 부모의 제약을 받아서 비율을 유지
   - 부모가 `width: actualPreviewW, height: actualPreviewH`로 제약을 주면
   - `AspectRatio`는 이 제약 내에서 `cameraAspectRatio` 비율을 유지하려고 함
   - 하지만 `actualPreviewW / actualPreviewH`가 이미 `cameraAspectRatio`와 일치하므로
   - `AspectRatio`는 부모 크기와 정확히 일치하게 됨 ✅

3. **CameraPreview의 실제 비율**
   - `CameraPreview`는 자체적으로 비율을 가지고 있음
   - `AspectRatio`로 감싸면 그 비율을 강제할 수 있음
   - `CameraPreview`의 실제 비율과 `cameraAspectRatio`가 다를 수 있음
   - 이 경우 `AspectRatio`가 비율을 강제하므로, `CameraPreview`가 약간 왜곡될 수 있음 ⚠️

## 결론

### 현재 구조는 이론적으로 작동해야 합니다:

1. ✅ `actualPreviewW/actualPreviewH` 계산이 `cameraAspectRatio`를 기반으로 정확함
2. ✅ 가로/세로 비율에 따라 올바른 기준으로 계산됨
3. ✅ `AspectRatio`가 부모 크기와 정확히 일치하게 됨
4. ✅ 비율 왜곡 방지

### 하지만 실제 기기에서 테스트가 필요합니다:

1. **CameraPreview의 실제 비율 확인**
   - `_cameraController!.value.aspectRatio`가 실제 카메라 비율을 정확히 반영하는지
   - 다양한 기기에서 테스트 필요

2. **부동소수점 오차 확인**
   - `actualPreviewW / actualPreviewH`와 `cameraAspectRatio`의 미세한 차이
   - `AspectRatio`가 이를 어떻게 처리하는지

3. **다양한 시나리오 테스트**
   - 화면 회전
   - 카메라 전환 (전면/후면)
   - 다양한 화면 크기

## 최종 답변

**현재 구조는 이론적으로 완벽하게 작동해야 합니다:**
- ✅ 크기 계산 로직이 정확함
- ✅ `AspectRatio`가 비율을 유지
- ✅ 왜곡 방지 메커니즘 작동

**하지만 실제 기기 테스트가 필수입니다:**
- `CameraPreview`의 실제 비율과 `cameraAspectRatio`가 정확히 일치하는지 확인 필요
- 부동소수점 오차로 인한 미세한 불일치 가능성
- 다양한 기기에서 정상 작동하는지 확인 필요

**100% 확실하게 하려면:**
- 실제 기기에서 테스트
- 다양한 카메라 비율에서 테스트
- 화면 회전, 카메라 전환 시나리오 확인

