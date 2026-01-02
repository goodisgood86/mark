# 비율 변경 시 프리뷰 동기화 검증

## 현재 구현 상태

### Flutter 측 (home_page.dart)

1. **비율 변경 시 (`_changeAspectMode`):**
   - ✅ `_lastSyncedPreviewRect = null`로 초기화
   - ✅ 100ms 후 `setState` 호출하여 `_buildCameraStack` 재빌드 유도
   - ⚠️ **문제 가능성**: `_buildCameraStack`이 재빌드되기 전에 비율이 변경될 수 있음

2. **프리뷰 동기화 (`_buildCameraStack`):**
   - ✅ `postFrameCallback`을 3번 중첩하여 레이아웃 완료 보장
   - ✅ `_getPreviewRectFromKey()`로 새 rect 계산
   - ✅ `_syncPreviewRectWithRetry()`로 네이티브에 전달
   - ⚠️ **문제 가능성**: `_getPreviewRectFromKey()`가 null을 반환하거나 잘못된 rect를 반환할 수 있음

### 네이티브 측 (NativeCamera.swift)

1. **프리뷰 레이아웃 업데이트 (`updatePreviewLayout`):**
   - ✅ `cameraContainer.frame` 업데이트
   - ✅ `autoresizingMask = []`로 설정하여 frame 유지
   - ✅ `cameraContainer.isHidden = false`, `alpha = 1.0` 강제 설정
   - ⚠️ **문제 가능성**: `cameraContainer`가 `RootViewController.view`의 자식이므로, frame이 업데이트되면 외부 영역이 자동으로 `RootViewController.view.backgroundColor`로 보여야 함

### RootViewController (RootViewController.swift)

1. **초기 설정:**
   - ✅ `view.backgroundColor = UIColor(red: 1.0, green: 0.941, blue: 0.961, alpha: 1.0)` (핑크색)
   - ✅ `cameraContainerView.backgroundColor = .clear`
   - ✅ `flutterViewController.view.backgroundColor = .clear`
   - ⚠️ **문제**: `setupCameraContainer()`에서 `cameraContainerView.frame = view.bounds`로 전체 화면 크기로 초기화됨

## 잠재적 문제점

### 1. cameraContainer 초기 크기 문제
- `setupCameraContainer()`에서 `cameraContainerView.frame = view.bounds`로 전체 화면 크기로 설정
- 이후 `updatePreviewLayout`에서 frame을 업데이트하지만, 초기에는 전체 화면 크기
- **해결책**: `updatePreviewLayout`이 호출되기 전까지는 `cameraContainer`를 숨기거나, 초기 frame을 설정하지 않음

### 2. 비율 변경 시 타이밍 문제
- `_changeAspectMode`에서 100ms 지연 후 `setState` 호출
- 하지만 `_buildCameraStack`의 `postFrameCallback`은 여러 프레임 후에 실행됨
- **해결책**: 비율 변경 시 즉시 `_getPreviewRectFromKey()`를 호출하여 rect를 계산하고 동기화

### 3. RootViewController.view 배경색 표시 문제
- `cameraContainer.frame`이 업데이트되면, 그 외부 영역은 `RootViewController.view.backgroundColor`로 보여야 함
- 하지만 `cameraContainer`가 `view.sendSubviewToBack`으로 뒤에 있고, `FlutterViewController.view`가 투명하므로, `cameraContainer` 외부 영역이 `RootViewController.view`의 배경색으로 보여야 함
- **확인 필요**: `cameraContainer`가 실제로 frame이 업데이트되었는지, 그리고 외부 영역이 제대로 보이는지

## 권장 수정 사항

### 1. 비율 변경 시 즉시 동기화
```dart
void _changeAspectMode(AspectRatioMode mode) {
  // ... 기존 코드 ...
  
  // 🔥 비율 변경 시 즉시 프리뷰 rect 계산 및 동기화 시도
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (Platform.isIOS && !_shouldUseMockCamera) {
        final Rect? rect = _getPreviewRectFromKey();
        if (rect != null && rect.width > 0 && rect.height > 0) {
          _lastSyncedPreviewRect = rect;
          _syncPreviewRectWithRetry(rect, context);
        }
      }
    });
  });
}
```

### 2. cameraContainer 초기 frame 설정 개선
```swift
private func setupCameraContainer() {
    view.addSubview(cameraContainerView)
    // 🔥 초기 frame을 설정하지 않고, updatePreviewLayout에서 설정하도록 함
    // cameraContainerView.frame = view.bounds // 제거
    cameraContainerView.isHidden = true // 초기에는 숨김
    view.sendSubviewToBack(cameraContainerView)
}
```

### 3. updatePreviewLayout에서 cameraContainer 표시 보장
```swift
func updatePreviewLayout(...) {
    // ... 기존 코드 ...
    
    // 🔥 cameraContainer를 표시하고 frame 업데이트
    rootVC.cameraContainer.isHidden = false
    rootVC.cameraContainer.frame = frame
    
    // 🔥 RootViewController.view의 배경색이 보이도록 보장
    rootVC.view.setNeedsDisplay()
}
```

## 결론

현재 구현은 이론적으로는 작동해야 하지만, 다음 문제들이 있을 수 있습니다:

1. **타이밍 문제**: 비율 변경 시 프리뷰 동기화가 지연될 수 있음
2. **초기 frame 문제**: `cameraContainer`가 초기에 전체 화면 크기로 설정되어 있음
3. **배경색 표시 문제**: `cameraContainer.frame` 업데이트 후 외부 영역이 제대로 보이지 않을 수 있음

**실기기 테스트가 필수**이며, 위의 수정 사항을 적용하면 더 확실하게 작동할 것입니다.

