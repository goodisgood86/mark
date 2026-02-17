# 프리뷰 비율 구조 분석

## 현재 구조

```dart
Positioned.fill(
  child: LayoutBuilder(
    builder: (context, constraints) {
      final double maxWidth = constraints.maxWidth;
      final double maxHeight = constraints.maxHeight;
      
      // 1. 카메라 비율에 맞는 프리뷰 크기 계산
      double actualPreviewW;
      double actualPreviewH;
      
      if (cameraAspectRatio > 1.0) {
        // 가로가 더 긴 비율: 가로를 기준으로 계산
        actualPreviewW = maxWidth;
        actualPreviewH = actualPreviewW / cameraAspectRatio;
        if (actualPreviewH > maxHeight) {
          actualPreviewH = maxHeight;
          actualPreviewW = actualPreviewH * cameraAspectRatio;
        }
      } else {
        // 세로가 더 긴 비율: 세로를 기준으로 계산
        actualPreviewH = maxHeight;
        actualPreviewW = actualPreviewH * cameraAspectRatio;
        if (actualPreviewW > maxWidth) {
          actualPreviewW = maxWidth;
          actualPreviewH = actualPreviewW / cameraAspectRatio;
        }
      }
      
      // 2. 중앙 정렬을 위한 오프셋
      final double offsetY = (maxHeight - actualPreviewH) / 2;
      final double offsetX = (maxWidth - actualPreviewW) / 2;
      
      // 3. Positioned로 프리뷰 배치
      Positioned(
        left: offsetX,
        top: offsetY,
        width: actualPreviewW,      // 명시적 크기 지정
        height: actualPreviewH,    // 명시적 크기 지정
        child: ClipRect(
          child: Center(
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
      )
    }
  )
)
```

## 구조적 분석

### ✅ 올바른 부분

1. **카메라 비율 계산 로직**
   - `cameraAspectRatio > 1.0` (가로가 더 긴 경우): 가로를 기준으로 계산 ✅
   - `cameraAspectRatio < 1.0` (세로가 더 긴 경우): 세로를 기준으로 계산 ✅
   - 이 로직은 **올바릅니다**.

2. **중앙 정렬 오프셋**
   - `offsetX = (maxWidth - actualPreviewW) / 2`
   - `offsetY = (maxHeight - actualPreviewH) / 2`
   - 중앙 정렬 계산도 **올바릅니다**.

### ⚠️ 잠재적 문제점

1. **Positioned의 명시적 크기 vs AspectRatio**
   - `Positioned`가 `width: actualPreviewW, height: actualPreviewH`로 명시적 크기 지정
   - `AspectRatio`는 부모의 제약을 받아서 비율을 유지하려고 함
   - **충돌 가능성**: `AspectRatio`가 `Positioned`의 크기 제약 내에서 비율을 유지하려고 할 때, 계산된 `actualPreviewW/actualPreviewH`와 `AspectRatio`의 비율이 정확히 일치해야 함

2. **이중 계산**
   - `actualPreviewW/actualPreviewH`는 이미 `cameraAspectRatio`를 기반으로 계산됨
   - `AspectRatio`도 같은 `cameraAspectRatio`를 사용
   - 이론적으로는 일치해야 하지만, 부동소수점 오차로 인한 미세한 차이가 발생할 수 있음

3. **CameraPreview의 실제 비율**
   - `CameraPreview`는 자체적으로 비율을 가지고 있음
   - `AspectRatio`로 감싸면 그 비율을 강제할 수 있지만, `Positioned`의 크기가 이미 정해져 있으면 제대로 작동하지 않을 수 있음

## 해결 방법

### 옵션 1: Positioned의 명시적 크기 제거 (권장)

```dart
Positioned(
  left: offsetX,
  top: offsetY,
  right: maxWidth - offsetX - actualPreviewW,  // 오른쪽 여백
  bottom: maxHeight - offsetY - actualPreviewH, // 아래쪽 여백
  child: ClipRect(
    child: AspectRatio(
      aspectRatio: cameraAspectRatio,
      child: Stack(...)
    )
  )
)
```

**장점**: `AspectRatio`가 자유롭게 크기를 결정할 수 있음
**단점**: `right`와 `bottom` 계산이 복잡할 수 있음

### 옵션 2: FittedBox 사용

```dart
Positioned(
  left: offsetX,
  top: offsetY,
  width: actualPreviewW,
  height: actualPreviewH,
  child: ClipRect(
    child: FittedBox(
      fit: BoxFit.contain,
      child: AspectRatio(
        aspectRatio: cameraAspectRatio,
        child: Stack(...)
      )
    )
  )
)
```

**장점**: 비율을 유지하면서 크기 조정
**단점**: 이전에 hit test 오류 발생했음

### 옵션 3: 현재 구조 유지 + 검증

현재 구조가 실제로 작동하는지 확인:
- `actualPreviewW/actualPreviewH`와 `cameraAspectRatio`가 정확히 일치하는지
- `AspectRatio`가 `Positioned`의 크기 제약 내에서 비율을 유지할 수 있는지

## 결론

**현재 구조는 이론적으로는 작동해야 하지만**, `Positioned`의 명시적 크기와 `AspectRatio`의 비율 유지 사이에 충돌 가능성이 있습니다.

**100% 확실하게 하려면:**
1. `Positioned`의 명시적 크기를 제거하고 `right`/`bottom` 사용
2. 또는 `FittedBox` 사용 (hit test 오류 해결 필요)
3. 실제 기기에서 테스트하여 검증

**현재 구조의 문제점:**
- `Positioned`의 `width/height`가 `AspectRatio`의 자유도를 제한할 수 있음
- 부동소수점 오차로 인한 미세한 불일치 가능성
- `CameraPreview`의 실제 비율과 계산된 크기가 정확히 일치해야 함

