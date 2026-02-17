# 카메라 상태 관리 재설계 - 코드 변경 지시

## 전체 변경 요약

이 문서는 단계별로 실제 코드 변경을 적용하기 위한 구체적인 지시입니다.

## Phase 1: 상태 필드 제거 및 _isCameraHealthy 추가 ✅

### 변경 1: 필드 선언 부분

**위치:** `lib/pages/home_page.dart` 약 Line 800-810

**변경 전:**
```dart
bool? _nativeSessionRunning;
bool? _nativeVideoConnected;
bool _nativeHasFirstFrame = false;
bool? _nativeIsPinkFallback;
bool? _lastSessionRunning;
bool? _lastVideoConnected;
bool? _lastPinkFallback;
String? _lastNativeInstancePtr;
```

**변경 후:**
```dart
// 🔥 REFACTORING: 중복 상태 필드 제거 - CameraDebugState만 Single Source of Truth로 사용
// 모든 상태는 _cameraEngine.lastDebugState에서 읽음
```

### 변경 2: _nativeHealthy → _isCameraHealthy

**위치:** `lib/pages/home_page.dart` 약 Line 655-660

**변경 전:**
```dart
bool get _nativeHealthy =>
    (_nativeSessionRunning ?? false) &&
    (_nativeVideoConnected ?? false) &&
    (_nativeHasFirstFrame == true) &&
    (_nativeIsPinkFallback != true);
```

**변경 후:**
```dart
bool get _isCameraHealthy {
  final state = _cameraEngine.lastDebugState;
  if (state == null) return false;
  
  final currentViewId = _cameraEngine.viewId;
  if (currentViewId != null && 
      state.viewId >= 0 && 
      state.viewId != currentViewId) {
    return false;
  }
  
  return state.sessionRunning && 
         state.videoConnected && 
         state.hasFirstFrame && 
         !state.isPinkFallback;
}
```

## Phase 2: _pollDebugState() 단순화

### 변경 3: 자동 재초기화 로직 제거

**위치:** `lib/pages/home_page.dart` 약 Line 428-570

**변경 전:**
전체 sessionLost 감지 및 _forceReinitCamera() 호출 로직

**변경 후:**
```dart
// 🔥 REFACTORING: 자동 재초기화 로직 제거
// - sessionLost 감지 제거
// - pinkFallbackDetected 감지 제거
// - 상태 캐시 업데이트 제거
// 이유: 자동 재초기화가 상태 불일치 유발

// 디버그 로그만 남김
if (kEnableCameraDebugOverlay) {
  final isHealthy = _isCameraHealthy;
  if (!isHealthy) {
    _addDebugLog(
      '[CameraDebug] ⚠️ Camera not healthy: sessionRunning=${state.sessionRunning}, '
      'videoConnected=${state.videoConnected}, hasFirstFrame=${state.hasFirstFrame}, '
      'isPinkFallback=${state.isPinkFallback}',
    );
  }
}
```

## Phase 3: canUseCamera 및 오버레이 조건 단순화

### 변경 4: canUseCamera 단순화

**위치:** `lib/pages/home_page.dart` 약 Line 662-757

**변경 후:**
```dart
bool get canUseCamera {
  if (_shouldUseMockCamera) return true;
  if (_isReinitializing) return false;
  if (_isProcessing || _cameraEngine.isCapturingPhoto) return false;
  
  return _isCameraHealthy; // 단일 소스 사용
}
```

### 변경 5: 오버레이 표시 조건

**위치:** `lib/pages/home_page.dart` _buildPreviewContent() 내부

**변경 후:**
```dart
bool get _shouldShowPinkOverlay {
  if (_shouldUseMockCamera) return false;
  if (_isReinitializing) return true;
  return !_isCameraHealthy;
}
```

## Phase 4: _forceReinitCamera() → _manualRestartCamera()

### 변경 6: 자동 호출 제거, 수동 호출만

**위치:** `lib/pages/home_page.dart` _pollDebugState(), _takePhoto() 등

**변경:**
- 모든 `_forceReinitCamera()` 자동 호출 제거
- 수동 재시작 버튼에만 연결

## Phase 5: 촬영 보호 강화

### 변경 7: _takePhoto() 내부 가드

**위치:** `lib/pages/home_page.dart` _takePhoto() 함수

**변경 후:**
```dart
// 네이티브 상태 직접 확인
final state = _cameraEngine.lastDebugState;
if (state == null || 
    !state.sessionRunning || 
    !state.videoConnected || 
    !state.hasFirstFrame) {
  // 에러 처리
  return;
}
```

