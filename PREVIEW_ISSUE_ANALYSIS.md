# 프리뷰 비율 문제 분석

## 현재 구조

```dart
Positioned(
  left: offsetX,
  top: offsetY,
  width: actualPreviewW,      // 명시적 크기 지정
  height: actualPreviewH,     // 명시적 크기 지정
  child: ClipRect(
    child: Center(
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
    )
  )
)
```

## 잠재적 문제점

### 1. Positioned의 명시적 크기 vs AspectRatio
- `Positioned`가 `width: actualPreviewW, height: actualPreviewH`로 명시적 크기를 지정
- `AspectRatio`는 부모의 제약을 받아서 비율을 유지하려고 함
- 하지만 `Positioned`의 크기가 이미 정해져 있어서, `AspectRatio`가 그 안에서 비율을 유지하려고 할 때 충돌 가능

### 2. actualPreviewW/actualPreviewH 계산
```dart
double actualPreviewW = maxWidth;
double actualPreviewH = actualPreviewW / cameraAspectRatio;

if (actualPreviewH > maxHeight) {
  actualPreviewH = maxHeight;
  actualPreviewW = actualPreviewH * cameraAspectRatio;
}
```
- 이 계산은 `cameraAspectRatio`를 기반으로 함
- 하지만 `AspectRatio` 위젯도 같은 비율을 사용하므로 중복 계산

### 3. CameraPreview의 실제 비율
- `CameraPreview`는 자체적으로 비율을 가지고 있음
- `AspectRatio`로 감싸면 그 비율을 강제할 수 있지만, `Positioned`의 크기가 이미 정해져 있으면 제대로 작동하지 않을 수 있음

## 해결 방법

### 옵션 1: Positioned의 크기 제거 (권장)
```dart
Positioned(
  left: offsetX,
  top: offsetY,
  // width, height 제거
  child: ClipRect(
    child: AspectRatio(
      aspectRatio: cameraAspectRatio,
      child: Stack(...)
    )
  )
)
```
- `AspectRatio`가 자유롭게 크기를 결정
- 하지만 `offsetX`, `offsetY` 계산이 달라져야 함

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
- `FittedBox`가 비율을 유지하면서 크기 조정
- 하지만 이전에 hit test 오류 발생했음

### 옵션 3: 현재 구조 유지 + 검증
- 현재 구조가 실제로 작동하는지 확인
- `AspectRatio`가 `Positioned`의 크기 제약 내에서 비율을 유지할 수 있는지 확인

## 테스트 필요 사항

1. **실제 기기에서 프리뷰 비율 확인**
   - 다양한 기기에서 테스트
   - 실제 카메라 비율과 프리뷰 비율이 일치하는지 확인

2. **다양한 화면 비율에서 테스트**
   - 세로 모드
   - 가로 모드 (있다면)
   - 다양한 화면 크기

3. **카메라 전환 시 테스트**
   - 전면/후면 카메라 전환
   - 각 카메라의 비율이 다를 수 있음

4. **비율 모드 변경 시 테스트**
   - 1:1, 3:4, 9:16 모드 전환
   - 각 모드에서 프리뷰 비율 확인

## 결론

현재 구조는 **이론적으로는 작동해야 하지만**, `Positioned`의 명시적 크기와 `AspectRatio`의 비율 유지 사이에 충돌 가능성이 있습니다.

**100% 확실하게 해결하려면:**
1. 실제 기기에서 테스트 필요
2. 다양한 시나리오에서 검증 필요
3. 필요시 구조 개선 필요

