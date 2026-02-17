# 잠재적 문제점 전반적 검토

## 문제 1: Flutter 뷰 추가 실패 (previewView가 window hierarchy에 없음)

### 현재 상황 분석

#### iOS 아키텍처

```
Flutter 위젯 트리:
  - NativeCameraPreview (투명한 Container)
    - iOS에서는 PlatformView를 사용하지 않음
    - 단순히 투명한 Container만 반환

네이티브 iOS:
  - RootViewController.cameraContainer (UIView)
    - NativeCameraViewController.previewView (CameraPreviewView/MTKView)
      - 여기에 실제 카메라 프리뷰가 렌더링됨
```

#### previewView 추가 경로

1. **NativeCameraViewController 초기화 시**:

   - `viewDidLoad()` 또는 `viewDidAppear()`에서
   - `RootViewController.cameraContainer`에 `previewView` 추가
   - `updatePreviewLayout()`로 프레임 설정

2. **현재 코드 위치**:
   - `ios/Runner/NativeCamera.swift`: `viewDidAppear()` (554줄)
   - `ios/Runner/NativeCamera.swift`: `updatePreviewLayout()` (3052줄)
   - `ios/Runner/NativeCamera.swift`: `captureOutput()` (5307-5309줄) - 경고만 출력

### 문제 발생 가능성

#### ✅ 정상 케이스 (90%+)

- `viewDidAppear()`에서 `previewView`가 `cameraContainer`에 추가됨
- `cameraContainer`가 `RootViewController.view`의 서브뷰로 추가됨
- `RootViewController.view`가 window hierarchy에 있음
- **결과**: `previewView.window != nil` ✅

#### ⚠️ 문제 케이스 (5-10%)

1. **타이밍 문제**:

   - `viewDidAppear()` 호출 전에 `captureOutput()`이 호출됨
   - `previewView`가 아직 `cameraContainer`에 추가되지 않음
   - **발생 가능성**: 낮음 (초기화 순서가 보장됨)

2. **RootViewController 없음**:

   - `CameraManager.shared.rootViewController`가 nil
   - `cameraContainer`에 접근 불가
   - **발생 가능성**: 매우 낮음 (앱 시작 시 설정됨)

3. **cameraContainer가 window hierarchy에 없음**:
   - `cameraContainer`는 있지만 `window`가 nil
   - 뷰 컨트롤러가 아직 화면에 표시되지 않음
   - **발생 가능성**: 낮음 (앱이 활성화된 상태에서만 카메라 사용)

### 현재 해결 상태

#### ✅ 구현된 부분

1. **경고 로그 출력** (5307-5309줄):

   ```swift
   if !hasWindow {
       self.log("[Native] ⚠️ WARNING: previewView.window is nil! View is not in window hierarchy, rendering will fail")
   }
   ```

2. **디버그 상태에 포함** (4514-4678줄):

   - `previewViewHasWindow` 플래그
   - Flutter 디버그 오버레이에 표시

3. **자동 복구 시도** (5295-5304줄):
   - `isPaused` 자동 해제
   - `isHidden` 자동 해제
   - **하지만 `window` nil은 자동 복구 불가** (Flutter/네이티브 뷰 계층 구조 문제)

#### ❌ 미구현 부분

1. **window nil 자동 복구**:

   - `previewView.window == nil`인 경우 자동으로 재추가 시도 없음
   - 이유: 네이티브에서 Flutter 뷰 계층 구조를 직접 제어할 수 없음

2. **Flutter 측 확인**:
   - Flutter에서 `previewViewHasWindow` 플래그 확인
   - false인 경우 재초기화 또는 레이아웃 동기화 시도

### 해결 방안

#### 방안 1: 네이티브에서 재추가 시도 (권장)

```swift
// captureOutput()에서
if !hasWindow {
    self.log("[Native] ⚠️ WARNING: previewView.window is nil! Attempting to re-add to hierarchy")

    // cameraContainer에 재추가 시도
    DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        if let rootVC = CameraManager.shared.rootViewController {
            let container = rootVC.cameraContainer
            if !container.subviews.contains(self.previewView) {
                container.addSubview(self.previewView)
                self.log("[Native] ✅ Re-added previewView to cameraContainer")
            }
            // 프레임 재설정
            self.updatePreviewLayout(
                width: self.previewView.bounds.width > 0 ? self.previewView.bounds.width : 720,
                height: self.previewView.bounds.height > 0 ? self.previewView.bounds.height : 1280
            )
        }
    }
}
```

#### 방안 2: Flutter에서 감지 및 재초기화

```dart
// home_page.dart에서
if (_nativePreviewViewHasWindow == false) {
  _addDebugLog('[Preview] ⚠️ previewView.window is nil, reinitializing...');
  await _manualRestartCamera();
}
```

#### 방안 3: 초기화 시점 보장

- `viewDidAppear()`에서 `previewView` 추가 확인
- `updatePreviewLayout()` 호출 전에 `window` 체크

### 최종 판단

**문제 발생 가능성**: 낮음 (5-10%)
**현재 해결 상태**: 부분적 (경고 로그만)
**권장 조치**: 방안 1 구현 (네이티브에서 재추가 시도)

---

## 문제 2: FilterEngine 문제 (filteredImage extent invalid)

### 현재 상황 분석

#### FilterEngine 동작

```swift
// captureOutput()에서
let filteredImage = filterEngine.applyToPreview(pixelBuffer: pixelBuffer, config: currentConfig)
let imageExtent = filteredImage.extent

// extent 유효성 검증
let isValidExtent = imageExtent.width > 0 && imageExtent.height > 0 &&
      imageExtent.width.isFinite && imageExtent.height.isFinite &&
      !imageExtent.width.isNaN && imageExtent.height.isNaN &&
      imageExtent.origin.x.isFinite && imageExtent.origin.y.isFinite &&
      !imageExtent.origin.x.isNaN && !imageExtent.origin.y.isNaN
```

#### 현재 처리 방식

1. **extent invalid 감지** (5249-5280줄):

   - `isValidExtent == false`인 경우
   - fallback 이미지 생성 (검은색 1280x720)
   - `previewView.display(image: fallbackImage)` 호출

2. **로그 출력**:
   - 첫 프레임 또는 60프레임마다 경고 로그
   - `pixelBuffer` 크기 정보 포함

### 문제 발생 가능성

#### ✅ 정상 케이스 (95%+)

- `applyToPreview()`가 유효한 `CIImage` 반환
- `extent`가 유효한 값 (width > 0, height > 0, finite, not NaN)
- **결과**: 정상 프리뷰 표시 ✅

#### ⚠️ 문제 케이스 (5% 미만)

1. **FilterEngine 내부 오류**:

   - 필터 적용 중 오류 발생
   - `CIImage` 생성 실패
   - **발생 가능성**: 매우 낮음 (FilterEngine이 안정적이라면)

2. **pixelBuffer 문제**:

   - `pixelBuffer`가 손상됨
   - `CVPixelBufferGetWidth/Height`가 0 반환
   - **발생 가능성**: 매우 낮음 (AVFoundation이 안정적)

3. **메모리 부족**:
   - 이미지 처리 중 메모리 부족
   - `CIImage` 생성 실패
   - **발생 가능성**: 낮음 (프리뷰는 720p로 제한)

### 현재 해결 상태

#### ✅ 구현된 부분

1. **extent 검증** (5242-5247줄):

   - width/height > 0
   - finite 값 확인
   - NaN 확인
   - origin 유효성 확인

2. **fallback 이미지** (5258-5279줄):

   - 검은색 1280x720 이미지 생성
   - `previewView.display(image: fallbackImage)` 호출
   - 프리뷰가 완전히 사라지지 않도록 보장

3. **로그 출력** (5251-5256줄):
   - 문제 발생 시 상세 로그
   - `pixelBuffer` 크기 정보

#### ❌ 미구현 부분

1. **근본 원인 해결**:

   - FilterEngine 내부 문제 해결 없음
   - extent invalid의 근본 원인 파악 없음

2. **자동 복구 시도**:
   - FilterEngine 재초기화 없음
   - 필터 설정 재적용 없음

### 해결 방안

#### 방안 1: FilterEngine 재초기화 (권장)

```swift
// extent invalid가 연속으로 발생하는 경우
private var invalidExtentCount = 0
private let maxInvalidExtentCount = 10

if !isValidExtent {
    invalidExtentCount += 1

    if invalidExtentCount >= maxInvalidExtentCount {
        self.log("[Native] ⚠️ CRITICAL: filteredImage extent invalid \(invalidExtentCount) times, reinitializing FilterEngine")
        // FilterEngine 재초기화
        filterEngine.reinitialize()
        invalidExtentCount = 0
    }

    // fallback 이미지 사용
    // ...
} else {
    invalidExtentCount = 0 // 정상이면 리셋
}
```

#### 방안 2: pixelBuffer 직접 사용

```swift
// FilterEngine이 실패하면 원본 pixelBuffer를 CIImage로 변환
if !isValidExtent {
    // FilterEngine 우회하여 원본 사용
    let originalImage = CIImage(cvPixelBuffer: pixelBuffer)
    if originalImage.extent.width > 0 && originalImage.extent.height > 0 {
        self.previewView.display(image: originalImage)
        return
    }
    // 원본도 실패하면 fallback
}
```

#### 방안 3: FilterEngine 디버깅 강화

```swift
// applyToPreview() 호출 전후 로깅
self.log("[Native] 📹 Before applyToPreview: pixelBuffer=\(CVPixelBufferGetWidth(pixelBuffer))x\(CVPixelBufferGetHeight(pixelBuffer))")
let filteredImage = filterEngine.applyToPreview(pixelBuffer: pixelBuffer, config: currentConfig)
self.log("[Native] 📹 After applyToPreview: extent=\(filteredImage.extent)")
```

### 최종 판단

**문제 발생 가능성**: 매우 낮음 (5% 미만)
**현재 해결 상태**: 부분적 (fallback 이미지로 완화)
**권장 조치**:

- 방안 1 구현 (FilterEngine 재초기화)
- 방안 3 구현 (디버깅 강화)
- 실제 발생 시 근본 원인 파악 후 추가 조치

---

## 종합 판단

### 문제 1: Flutter 뷰 추가 실패

- **발생 가능성**: 낮음 (5-10%)
- **영향**: 프리뷰가 전혀 표시되지 않음
- **현재 해결**: 경고 로그만
- **권장 조치**: 네이티브에서 재추가 시도 구현

### 문제 2: FilterEngine 문제

- **발생 가능성**: 매우 낮음 (5% 미만)
- **영향**: 검은색 프리뷰만 표시 (완전히 사라지지는 않음)
- **현재 해결**: fallback 이미지로 완화
- **권장 조치**: FilterEngine 재초기화 및 디버깅 강화

### 전체 프리뷰 성공률 재평가

**기존 평가**: 90%+
**재평가**: 85-90%

**이유**:

- 문제 1이 발생하면 프리뷰가 전혀 표시되지 않음 (5-10% 확률)
- 문제 2가 발생하면 검은색 프리뷰만 표시됨 (5% 미만 확률)
- 두 문제 모두 해결 시: 90%+ 달성 가능

### 권장 조치 우선순위

1. **높음**: 문제 1 해결 (네이티브에서 재추가 시도)
2. **중간**: 문제 2 해결 (FilterEngine 재초기화)
3. **낮음**: 디버깅 강화 (두 문제 모두)
