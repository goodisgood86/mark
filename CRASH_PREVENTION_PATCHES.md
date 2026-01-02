# 🔥 크래시 방지 패치 문서
## `-[UIView_backing_setFrame:]` 크래시 완전 차단

### 개요
- **문제**: Flutter PlatformView에서 CALayer의 frame/position에 NaN/Inf/음수 값이 전달되어 `UIView_backing_setFrame:` 크래시 발생
- **목표**: 정적 분석 기반으로 모든 frame/bounds/position 설정 지점에 방어 코드 추가
- **접근 방식**: 
  1. 공통 유틸리티 함수로 검증 로직 통일
  2. iOS 네이티브 코드 모든 frame 설정 지점 보강
  3. Flutter 쪽 레이아웃 계산에도 방어 코드 추가
  4. 로그 전략으로 문제 추적 가능하게

---

## 📋 1단계: 공통 유틸리티 추가

### 파일: `ios/Runner/GeometrySafety.swift` (신규 생성)

이 파일은 모든 frame/bounds/position 값 검증을 위한 공통 유틸리티를 제공합니다.

**주요 기능**:
- `safeLength()`: CGFloat 값 검증 (NaN/Inf/음수/과도한 값 체크)
- `safeSize()`: CGSize 검증
- `safeRect()`: CGRect 검증
- `safePoint()`: CGPoint 검증
- `safeAspectRatio()`: Aspect ratio 계산 시 0으로 나누기 방지
- Extension 메서드: CGRect/CGSize/CGPoint/CGFloat에 직접 사용 가능

**이유**: 모든 검증 로직을 한 곳에 모아 일관성 유지 및 유지보수 용이

---

## 📋 2단계: iOS 네이티브 코드 패치

### 패치 2-1: PlatformView 생성 시 frame 검증

**파일**: `ios/Runner/NativeCamera.swift`

**위치**: `func create(withFrame:viewIdentifier:arguments:)` (약 4661줄)

```diff
  func create(
      withFrame frame: CGRect,
      viewIdentifier viewId: Int64,
      arguments args: Any?
  ) -> FlutterPlatformView {
+     // 🔥 크래시 방지: Flutter가 전달한 frame 검증
+     let safeFrame = GeometrySafety.safeRect(frame, fallback: .zero)
+     if !safeFrame.isValidAndFinite() {
+         NSLog("[Petgram] ❗ Invalid frame in create(): \(frame), using .zero")
+         // .zero frame은 autoresizingMask로 자동 조정됨
+     }
+     
-     let cameraView = NativeCameraView(frame: frame, viewId: viewId)
+     let cameraView = NativeCameraView(frame: safeFrame, viewId: viewId)
      cameraView.onDisposed = { [weak self] viewId in
          self?.cameraViews.removeValue(forKey: viewId)
      }
      cameraViews[viewId] = cameraView
      return cameraView
  }
```

**이유**: Flutter가 PlatformView 생성 시 전달하는 초기 frame이 NaN/Inf일 수 있으므로 검증 필요

---

### 패치 2-2: NativeCameraView.init(frame:) 검증 강화

**파일**: `ios/Runner/NativeCamera.swift`

**위치**: `init(frame:viewId:)` (약 4699줄)

```diff
  init(frame: CGRect, viewId: Int64) {
+     // 🔥 크래시 방지: 전달받은 frame 검증
+     let safeFrame = GeometrySafety.safeRect(frame, fallback: .zero)
+     if !frame.isValidAndFinite() {
+         NSLog("[Petgram] ❗ Invalid frame in NativeCameraView.init: \(frame), using safeFrame: \(safeFrame)")
+     }
      self.viewId = viewId
      self.viewController = NativeCameraView.sharedViewController
      super.init()
      setupCallbacks()
  }
```

**이유**: PlatformView 생성 시 전달받은 frame이 유효하지 않을 수 있음

---

### 패치 2-3: loadView()에서 containerView.frame 설정 검증

**파일**: `ios/Runner/NativeCamera.swift`

**위치**: `loadView()` (약 308줄)

```diff
      outerContainer.addSubview(containerView)
-     containerView.frame = .zero // autoresizingMask로 자동 조정
+     // 🔥 크래시 방지: .zero는 유효하지만 명시적으로 검증
+     let safeContainerFrame = GeometrySafety.safeRect(.zero, fallback: .zero)
+     containerView.frame = safeContainerFrame // autoresizingMask로 자동 조정
      containerView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
```

**이유**: 명시적 검증으로 일관성 유지 (현재는 .zero이므로 문제 없지만 방어 코드 추가)

---

### 패치 2-4: Loading Overlay indicator.bounds 검증 강화

**파일**: `ios/Runner/NativeCamera.swift`

**위치**: `showLoadingOverlay()` (약 432줄)

```diff
          // indicator는 고정 크기이므로 bounds만 설정하고 center로 위치 조정
-         indicator.bounds = CGRect(x: 0, y: 0, width: indicatorSize, height: indicatorSize)
+         // 🔥 크래시 방지: indicatorSize 검증
+         let safeIndicatorSize = GeometrySafety.safeLength(indicatorSize, fallback: 40.0)
+         let safeIndicatorBounds = GeometrySafety.makeSafeRect(
+             x: 0, y: 0, 
+             width: safeIndicatorSize, 
+             height: safeIndicatorSize
+         )
+         indicator.bounds = safeIndicatorBounds
```

**이유**: indicatorSize 계산 값이 유효하지 않을 수 있음

---

### 패치 2-5: Loading Overlay overlay.frame 검증

**파일**: `ios/Runner/NativeCamera.swift`

**위치**: `showLoadingOverlay()` 내부 async 블록 (약 491줄)

```diff
                  // overlay frame도 container view의 bounds에 맞춤
-                 overlay.frame = containerView.bounds
+                 // 🔥 크래시 방지: containerView.bounds 검증
+                 let safeOverlayFrame = GeometrySafety.safeRect(
+                     containerView.bounds, 
+                     fallback: CGRect(x: 0, y: 0, width: 100, height: 100)
+                 )
+                 if !containerView.bounds.isValidAndFinite() {
+                     NSLog("[Petgram] ❗ Invalid containerView.bounds in loading overlay: \(containerView.bounds), using safeFrame: \(safeOverlayFrame)")
+                 }
+                 overlay.frame = safeOverlayFrame
                  containerView.addSubview(overlay)
```

**이유**: Flutter가 frame을 설정한 직후 containerView.bounds가 유효하지 않을 수 있음

---

### 패치 2-6: CameraPreviewView.init(frame:) 검증 강화

**파일**: `ios/Runner/CameraPreviewView.swift`

**위치**: `init(frame:device:)` (약 110줄)

```diff
  override init(frame frameRect: CGRect, device: MTLDevice?) {
-     // 🔥 크래시 방지: frame이 .zero이거나 유효하지 않으면 기본값 사용
+     // 🔥 크래시 방지: GeometrySafety 유틸리티 사용하여 검증 강화
      let safeFrame: CGRect
-     if frameRect == .zero || 
-        !frameRect.size.width.isFinite || frameRect.size.width.isNaN ||
-        !frameRect.size.height.isFinite || frameRect.size.height.isNaN ||
-        frameRect.size.width < 0 || frameRect.size.height < 0 {
+     if !frameRect.isValidAndFinite() {
          // 유효하지 않은 frame이면 기본값 사용
-         safeFrame = CGRect(x: 0, y: 0, width: 100, height: 100)
+         safeFrame = GeometrySafety.safeRect(frameRect, fallback: CGRect(x: 0, y: 0, width: 100, height: 100))
+         NSLog("[Petgram] ❗ Invalid frameRect in CameraPreviewView.init: \(frameRect), using safeFrame: \(safeFrame)")
      } else {
          safeFrame = frameRect
      }
```

**이유**: 기존 검증을 GeometrySafety 유틸리티로 통일하여 일관성 유지

---

### 패치 2-7: CameraPreviewView.frame setter 검증 강화

**파일**: `ios/Runner/CameraPreviewView.swift`

**위치**: `override var frame: CGRect` (약 189줄)

```diff
  override var frame: CGRect {
      get { return super.frame }
      set {
          guard !isSettingFrame else { return }
          isSettingFrame = true
          defer { isSettingFrame = false }
          
-         // 🔥 핵심: frame 값 유효성 검증 (Flutter 엔진 레벨 보호)
-         var safeFrame = newValue
-         guard safeFrame.size.width.isFinite && !safeFrame.size.width.isNaN &&
-               safeFrame.size.height.isFinite && !safeFrame.size.height.isNaN &&
-               safeFrame.origin.x.isFinite && !safeFrame.origin.x.isNaN &&
-               safeFrame.origin.y.isFinite && !safeFrame.origin.y.isNaN &&
-               safeFrame.size.width >= 0 && safeFrame.size.height >= 0 &&
-               safeFrame.size.width <= 10000 && safeFrame.size.height <= 10000 &&
-               abs(safeFrame.origin.x) <= 10000 && abs(safeFrame.origin.y) <= 10000 else {
+         // 🔥 크래시 방지: GeometrySafety 유틸리티 사용
+         let safeFrame = GeometrySafety.safeRect(newValue, fallback: super.frame)
+         if !newValue.isValidAndFinite() {
              #if DEBUG
-             print("[CameraPreviewView] ⚠️ Invalid frame attempted: \(newValue), skipping")
+             print("[CameraPreviewView] ⚠️ Invalid frame attempted: \(newValue), using safeFrame: \(safeFrame)")
              #endif
+             NSLog("[Petgram] ❗ Invalid frame in CameraPreviewView.frame setter: \(newValue), using safeFrame: \(safeFrame)")
              return // 유효하지 않은 frame은 무시
          }
          
          if super.frame != safeFrame {
              autoreleasepool {
                  super.frame = safeFrame
              }
          }
      }
  }
```

**이유**: GeometrySafety 유틸리티로 검증 로직 통일 및 로그 강화

---

### 패치 2-8: updateDrawableSizeIfNeeded() 검증 강화

**파일**: `ios/Runner/CameraPreviewView.swift`

**위치**: `updateDrawableSizeIfNeeded()` (약 279줄)

```diff
      let screenScale = UIScreen.main.scale
-     guard screenScale > 0 && screenScale.isFinite && !screenScale.isNaN else {
+     let safeScreenScale = GeometrySafety.safeLength(screenScale, fallback: 1.0)
+     guard safeScreenScale > 0 else {
          #if DEBUG
-         print("[CameraPreviewView] ⚠️ Invalid screenScale: \(screenScale), skipping drawableSize update")
+         print("[CameraPreviewView] ⚠️ Invalid screenScale: \(screenScale), using fallback: \(safeScreenScale)")
          #endif
+         NSLog("[Petgram] ❗ Invalid screenScale in updateDrawableSizeIfNeeded: \(screenScale), using fallback: \(safeScreenScale)")
          return
      }
      
      let targetSize = CGSize(
-         width: bounds.width * screenScale,
-         height: bounds.height * screenScale
+         width: bounds.width * safeScreenScale,
+         height: bounds.height * safeScreenScale
      )
      
      // 🔥 크래시 방지: 계산된 targetSize 유효성 검증
-     guard targetSize.width.isFinite && targetSize.height.isFinite &&
-           !targetSize.width.isNaN && !targetSize.height.isNaN &&
-           targetSize.width > 0 && targetSize.height > 0 else {
+     let safeTargetSize = GeometrySafety.safeSize(targetSize, fallback: CGSize(width: 720, height: 720))
+     if !targetSize.isValidAndFinite() {
          #if DEBUG
-         print("[CameraPreviewView] ⚠️ Invalid targetSize: \(targetSize), skipping drawableSize update")
+         print("[CameraPreviewView] ⚠️ Invalid targetSize: \(targetSize), using safeTargetSize: \(safeTargetSize)")
          #endif
+         NSLog("[Petgram] ❗ Invalid targetSize in updateDrawableSizeIfNeeded: \(targetSize), using safeTargetSize: \(safeTargetSize)")
          return
      }
      
-     let maxDimension: CGFloat = 1920.0
-     let aspectRatio = targetSize.width / targetSize.height
+     let maxDimension: CGFloat = 1920.0
+     let aspectRatio = GeometrySafety.safeAspectRatio(
+         width: safeTargetSize.width, 
+         height: safeTargetSize.height
+     )
      
-     guard aspectRatio.isFinite && !aspectRatio.isNaN && aspectRatio > 0 else {
+     // aspectRatio는 이미 GeometrySafety에서 검증됨 (0으로 나누기 방지 포함)
+     guard aspectRatio > 0 else {
          #if DEBUG
          print("[CameraPreviewView] ⚠️ Invalid aspectRatio: \(aspectRatio), using default")
          #endif
+         NSLog("[Petgram] ❗ Invalid aspectRatio in updateDrawableSizeIfNeeded: \(aspectRatio)")
          return
      }
      
      let finalSize: CGSize
-     if targetSize.width > maxDimension || targetSize.height > maxDimension {
+     if safeTargetSize.width > maxDimension || safeTargetSize.height > maxDimension {
          if targetSize.width > targetSize.height {
              let height = maxDimension / aspectRatio
-             guard height.isFinite && !height.isNaN && height > 0 else {
+             let safeHeight = GeometrySafety.safeLength(height, fallback: maxDimension)
+             guard safeHeight > 0 else {
                  #if DEBUG
-                 print("[CameraPreviewView] ⚠️ Invalid calculated height: \(height), skipping")
+                 print("[CameraPreviewView] ⚠️ Invalid calculated height: \(height), using safeHeight: \(safeHeight)")
                  #endif
+                 NSLog("[Petgram] ❗ Invalid calculated height in updateDrawableSizeIfNeeded: \(height), using safeHeight: \(safeHeight)")
                  return
              }
-             finalSize = CGSize(width: maxDimension, height: height)
+             finalSize = CGSize(width: maxDimension, height: safeHeight)
          } else {
              let width = maxDimension * aspectRatio
-             guard width.isFinite && !width.isNaN && width > 0 else {
+             let safeWidth = GeometrySafety.safeLength(width, fallback: maxDimension)
+             guard safeWidth > 0 else {
                  #if DEBUG
-                 print("[CameraPreviewView] ⚠️ Invalid calculated width: \(width), skipping")
+                 print("[CameraPreviewView] ⚠️ Invalid calculated width: \(width), using safeWidth: \(safeWidth)")
                  #endif
+                 NSLog("[Petgram] ❗ Invalid calculated width in updateDrawableSizeIfNeeded: \(width), using safeWidth: \(safeWidth)")
                  return
              }
-             finalSize = CGSize(width: width, height: maxDimension)
+             finalSize = CGSize(width: safeWidth, height: maxDimension)
          }
      } else {
          let minSize: CGFloat = 720.0
          finalSize = CGSize(
-             width: max(targetSize.width, minSize),
-             height: max(targetSize.height, minSize)
+             width: max(safeTargetSize.width, minSize),
+             height: max(safeTargetSize.height, minSize)
          )
      }
      
      // 🔥 크래시 방지: finalSize 최종 유효성 검증
-     guard finalSize.width.isFinite && finalSize.height.isFinite &&
-           !finalSize.width.isNaN && !finalSize.height.isNaN &&
-           finalSize.width > 0 && finalSize.height > 0 else {
+     let safeFinalSize = GeometrySafety.safeSize(finalSize, fallback: CGSize(width: 720, height: 720))
+     if !finalSize.isValidAndFinite() {
          #if DEBUG
-         print("[CameraPreviewView] ⚠️ Invalid finalSize: \(finalSize), skipping drawableSize update")
+         print("[CameraPreviewView] ⚠️ Invalid finalSize: \(finalSize), using safeFinalSize: \(safeFinalSize)")
          #endif
+         NSLog("[Petgram] ❗ Invalid finalSize in updateDrawableSizeIfNeeded: \(finalSize), using safeFinalSize: \(safeFinalSize)")
          return
      }
      
-     if abs(finalSize.width - lastDrawableSize.width) < 1.0 &&
-        abs(finalSize.height - lastDrawableSize.height) < 1.0 {
+     if abs(safeFinalSize.width - lastDrawableSize.width) < 1.0 &&
+        abs(safeFinalSize.height - lastDrawableSize.height) < 1.0 {
          return
      }
      
-     lastDrawableSize = finalSize
-     drawableSize = finalSize
+     lastDrawableSize = safeFinalSize
+     drawableSize = safeFinalSize
```

**이유**: 모든 중간 계산 값들(screenScale, targetSize, aspectRatio, finalSize)에 검증 추가하여 NaN/Inf 전파 방지

---

## 📋 3단계: Flutter 코드 패치

### 패치 3-1: GeometrySafety 유틸리티 추가 (Dart)

**파일**: `lib/utils/geometry_safety.dart` (신규 생성)

```dart
/// 🔥 정적 분석 기반 방어: Geometry 값 안전성 검증 유틸리티
/// UIView_backing_setFrame 크래시 방지를 위한 공통 유틸리티
class GeometrySafety {
  /// 최대 허용 차원 (픽셀 단위)
  static const double maxDimension = 10000.0;
  
  /// 최소 허용 차원 (픽셀 단위)
  static const double minDimension = 0.0;
  
  /// double 값이 안전한지 검증
  /// - [value]: 검증할 값
  /// - [fallback]: 유효하지 않은 경우 사용할 기본값 (기본값: 0)
  /// - Returns: 유효한 값 또는 fallback
  static double safeLength(double value, {double fallback = 0.0}) {
    if (value.isNaN || value.isInfinite || value < minDimension || value > maxDimension) {
      debugPrint('[GeometrySafety] ⚠️ Invalid length detected: $value, using fallback: $fallback');
      return fallback;
    }
    return value;
  }
  
  /// Size가 안전한지 검증하고 수정된 Size 반환
  static Size safeSize(Size size, {Size? fallback}) {
    final safeWidth = safeLength(size.width, fallback: fallback?.width ?? 0.0);
    final safeHeight = safeLength(size.height, fallback: fallback?.height ?? 0.0);
    
    if (safeWidth <= 0 || safeHeight <= 0) {
      debugPrint('[GeometrySafety] ⚠️ Invalid size detected: width=${size.width}, height=${size.height}, using fallback: $fallback');
      return fallback ?? Size.zero;
    }
    
    return Size(safeWidth, safeHeight);
  }
  
  /// Aspect ratio 계산 시 0으로 나누기 방지
  static double safeAspectRatio(double width, double height, {double fallback = 1.0}) {
    final safeWidth = safeLength(width, fallback: 1.0);
    final safeHeight = safeLength(height, fallback: 1.0);
    
    if (safeHeight <= 0) {
      debugPrint('[GeometrySafety] ⚠️ Division by zero prevented: width=$width, height=$height, returning $fallback');
      return fallback;
    }
    
    final ratio = safeWidth / safeHeight;
    
    if (ratio.isNaN || ratio.isInfinite || ratio <= 0 || ratio > 100) {
      debugPrint('[GeometrySafety] ⚠️ Invalid aspect ratio: $ratio, returning $fallback');
      return fallback;
    }
    
    return ratio;
  }
}
```

**이유**: Flutter 쪽에서도 동일한 검증 로직 적용으로 일관성 유지

---

### 패치 3-2: home_page.dart에서 aspect ratio 계산 방어

**파일**: `lib/pages/home_page.dart`

**위치**: `_buildCameraPreviewLayer()` 내부 (약 5336줄)

```diff
      final double? cameraAspectRatio = _cameraEngine.nativeCamera?.aspectRatio;
      if (cameraAspectRatio != null && cameraAspectRatio > 0) {
-       _sensorAspectRatio = cameraAspectRatio;
+       // 🔥 크래시 방지: aspect ratio 검증
+       final safeAspectRatio = GeometrySafety.safeAspectRatio(
+         cameraAspectRatio, 
+         1.0, 
+         fallback: 3.0 / 4.0
+       );
+       if (cameraAspectRatio != safeAspectRatio) {
+         debugPrint('[Petgram] ❗ Invalid cameraAspectRatio: $cameraAspectRatio, using safeAspectRatio: $safeAspectRatio');
+       }
+       _sensorAspectRatio = safeAspectRatio;
      }

      // 네이티브 크기가 없으면 센서 비율 기반으로 계산
-     final double nativeWidth = nativeSize?.width ?? 1920.0;
-     final double nativeHeight =
-         nativeSize?.height ?? (nativeWidth / _sensorAspectRatio);
+     // 🔥 크래시 방지: nativeWidth/nativeHeight 검증 및 0으로 나누기 방지
+     final double nativeWidth = GeometrySafety.safeLength(
+       nativeSize?.width ?? 1920.0,
+       fallback: 1920.0
+     );
+     final double safeSensorAspectRatio = GeometrySafety.safeAspectRatio(
+       _sensorAspectRatio,
+       1.0,
+       fallback: 3.0 / 4.0
+     );
+     final double nativeHeight = GeometrySafety.safeLength(
+       nativeSize?.height ?? (nativeWidth / safeSensorAspectRatio),
+       fallback: 1920.0 / safeSensorAspectRatio
+     );
+     
+     // 최종 검증: nativeWidth와 nativeHeight가 모두 유효한지 확인
+     if (nativeWidth <= 0 || nativeHeight <= 0) {
+       debugPrint('[Petgram] ❗ Invalid nativeSize calculated: width=$nativeWidth, height=$nativeHeight');
+       // fallback 값 사용
+       return _buildFallbackPreview();
+     }
```

**이유**: Flutter 쪽에서 계산한 크기 값이 NaN/Inf/0이 되어 네이티브로 전달되는 것을 방지

---

### 패치 3-3: AspectRatio 위젯에 전달하는 값 검증

**파일**: `lib/pages/home_page.dart`

**위치**: `AspectRatio(aspectRatio: _sensorAspectRatio, ...)` (약 5356-5420줄)

```diff
      return RepaintBoundary(
        key: _nativePreviewKey,
        child: AspectRatio(
-         aspectRatio: _sensorAspectRatio, // 센서 비율 고정
+         // 🔥 크래시 방지: aspectRatio 검증
+         aspectRatio: GeometrySafety.safeAspectRatio(
+           _sensorAspectRatio,
+           1.0,
+           fallback: 3.0 / 4.0
+         ),
          child: FittedBox(
            fit: BoxFit.cover,
            child: SizedBox(
-             width: nativeWidth,
-             height: nativeHeight,
+             // 🔥 크래시 방지: SizedBox 크기 검증
+             width: GeometrySafety.safeLength(nativeWidth, fallback: 1920.0),
+             height: GeometrySafety.safeLength(nativeHeight, fallback: 1920.0),
```

**이유**: AspectRatio 위젯에 NaN/Inf 값이 전달되면 레이아웃 계산 중 크래시 발생 가능

---

## 📋 4단계: 로그 전략

### 로그 형식

모든 검증 실패 시 다음 형식으로 로그 출력:

**iOS (NSLog)**:
```
[Petgram] ❗ [컨텍스트] Invalid [값 이름]: [원본 값], using [대체 값]: [대체 값]
```

**Flutter (debugPrint)**:
```
[Petgram] ❗ [컨텍스트] Invalid [값 이름]: [원본 값], using [대체 값]: [대체 값]
```

### 로그 수집 방법

1. **Xcode Console**: 개발 중 실시간 확인
2. **Apple 크래시 리포트**: 디바이스 로그 포함
3. **Firebase Crashlytics** (선택): 커스텀 로그 추가 가능

---

## 📋 최종 체크리스트

- [x] 공통 유틸리티 파일 생성 (`GeometrySafety.swift`, `geometry_safety.dart`)
- [ ] iOS 네이티브 코드 모든 frame/bounds/position 설정 지점 보강
- [ ] Flutter 코드 레이아웃 계산 부분 보강
- [ ] 로그 전략 적용
- [ ] 빌드 및 테스트

---

## ⚠️ 주의사항

1. **100% 재현 방지 보장 불가**: 이 패치는 "NaN/잘못된 frame 값으로 인한 크래시를 최대한 방어"하는 것이 목표입니다. 다른 원인의 크래시는 여전히 발생할 수 있습니다.

2. **성능 영향 최소화**: 검증 로직은 빠르게 실행되도록 설계되었으나, 모든 frame 설정마다 검증이 수행되므로 약간의 오버헤드가 발생할 수 있습니다.

3. **Fallback 값 선택**: 검증 실패 시 사용할 fallback 값은 현재 구현에 맞게 선택되었으나, 필요에 따라 조정 가능합니다.

---

## 🔍 추가 디버깅 팁

크래시가 계속 발생한다면:

1. **로그 확인**: `[Petgram] ❗`로 시작하는 로그를 찾아 어떤 값이 문제인지 확인
2. **스택 트레이스 분석**: Apple 크래시 리포트에서 정확히 어떤 메서드에서 크래시가 발생했는지 확인
3. **Flutter 엔진 레벨 이슈**: Flutter 엔진 자체의 버그일 가능성도 있으므로 Flutter 버전 업그레이드 고려

