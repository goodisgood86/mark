# 카메라 재설계 - 추가 보완 포인트 반영 요약

## ✅ 반영 완료된 보완 포인트

### 1. `_pollDebugState()`에서 setState 완전 제거 금지 ✅

**문제점:**

- setState를 완전히 제거하면 `lastDebugState`가 업데이트되어도 UI가 자동으로 리빌드되지 않음
- 프리뷰/핑크 오버레이 상태가 화면에서 갱신되지 않는 문제 발생

**해결 방법:**

- 상태 캐시 업데이트는 제거했지만, UI 리빌드를 위한 최소한의 `setState` 유지
- `_debugStateVersion` 카운터를 추가하여 빌드 트리거 역할 수행
- 디버그 오버레이 전용 필드는 `kEnableCameraDebugOverlay`일 때만 업데이트

**변경 사항:**

```dart
// 필드 추가
int _debugStateVersion = 0;

// _pollDebugState() 내부
if (mounted) {
  setState(() {
    _debugStateVersion++; // UI 리빌드 트리거
    // 디버그 필드 업데이트 (kEnableCameraDebugOverlay일 때만)
  });
}
```

**이유:** `lastDebugState`는 게터로 읽지만, Flutter의 리액티브 시스템이 이를 감지하지 못하므로 명시적 `setState` 필요

---

### 2. `_manualRestartCamera()`에서 Native dispose 이중 호출 금지 ✅

**문제점:**

- UI 레이어에서 `nativeCamera.dispose()` 직접 호출
- 그 다음 `CameraEngine.dispose()` 호출
- `CameraEngine.dispose()` 내부에서도 `nativeCamera.dispose()` 호출
- → 이중 dispose → race condition → 크래시 위험

**해결 방법:**

- UI 레이어에서 `nativeCamera.dispose()` 직접 호출 제거
- `CameraEngine.dispose()`만 호출하도록 통일
- 모든 dispose 책임을 CameraEngine 내부로 몰기

**변경 사항:**

```dart
// 변경 전 (이중 호출 위험)
if (_cameraEngine.nativeCamera != null) {
  await _cameraEngine.nativeCamera!.dispose(); // ❌ 제거
}
await _cameraEngine.dispose(); // 내부에서 이미 dispose 호출

// 변경 후 (안전)
await _cameraEngine.dispose(); // ✅ 모든 dispose 책임은 CameraEngine 내부로
```

**이유:** 단일 책임 원칙 - dispose는 CameraEngine의 책임이며, UI 레이어는 관여하지 않음

---

### 3. 자동 재초기화 완전 제거는 OK, 하지만 추후 확장 고려해 훅은 남겨둘 것 ✅

**현재 상태:**

- 자동 재초기화 로직 완전 제거 (개발 안정화 단계에 적합)
- 하지만 실제 서비스 릴리즈에서는 사용자 UX 문제 가능성

**해결 방법:**

- 현재는 자동 reinit 경로를 완전히 제거
- 향후 확장을 위한 `_maybeAutoRecover()` 훅 추가 (현재는 비활성)
- 명백한 하드 에러 상황에서만 1회 자동 복구하는 로직 추가 가능하도록 구조 유지

**변경 사항:**

```dart
/// 향후 확장을 위한 자동 복구 훅 (현재는 비활성)
void _maybeAutoRecover() {
  // 현재는 비활성
  // 향후 확장 시 여기에 자동 복구 로직 추가
  // 예: sessionRunning=false && videoConnected=false && hasFirstFrame=false 인 경우
  // 일정 시간(예: 5초) 이상 지속되는 경우만 1회 호출
}
```

**향후 확장 예시:**

```dart
// 향후 확장 시 (예시)
void _maybeAutoRecover() {
  final state = _cameraEngine.lastDebugState;
  if (state == null) return;

  // 명백한 하드 에러 상황만 감지
  final isHardError = !state.sessionRunning &&
                      !state.videoConnected &&
                      !state.hasFirstFrame;

  if (isHardError && !_hasAutoRecovered) {
    _hasAutoRecovered = true; // 1회만 실행
    _manualRestartCamera(); // 자동 복구 시도
  }
}
```

**이유:** 개발 단계에서는 안정성을 위해 자동 복구를 비활성화하되, 서비스 단계에서는 UX를 위해 선택적 자동 복구가 필요할 수 있음

---

## 📋 반영 상태 체크리스트

- [x] ✅ 1. `_pollDebugState()`에서 UI 리빌드를 위한 최소 setState 유지
- [x] ✅ 2. `_manualRestartCamera()`에서 이중 dispose 호출 제거
- [x] ✅ 3. 향후 확장을 위한 `_maybeAutoRecover()` 훅 추가

---

## 🔍 추가 확인 사항

### CameraEngine.dispose() 내부 구조 확인

`lib/services/camera_engine.dart`의 `dispose()` 메서드:

```dart
Future<void> dispose() async {
  if (_nativeCamera != null) {
    await _nativeCamera!.dispose(); // ✅ 내부에서 이미 호출
    _nativeCamera = null;
  }
  _isInitializing = false;
  // ... 기타 정리 작업
}
```

**결론:** CameraEngine.dispose()가 이미 모든 정리 작업을 수행하므로, UI 레이어에서 추가 dispose 호출 불필요

---

## 🎯 최종 구조

### 상태 관리 흐름

```
CameraDebugState (네이티브)
  ↓
CameraEngine.lastDebugState (Single Source)
  ↓
HomePage 게터들 (_isCameraHealthy, canUseCamera, _shouldShowPinkOverlay)
  ↓
UI 빌드 (setState로 리빌드 트리거)
```

### 재시작 흐름

```
사용자 수동 재시작 버튼
  ↓
_manualRestartCamera()
  ↓
CameraEngine.dispose() (모든 정리 책임)
  ↓
PlatformView 재생성 (key 변경)
  ↓
onCreated 재호출
  ↓
자동 재초기화
```

### 향후 확장 가능성

```
명백한 하드 에러 감지
  ↓
_maybeAutoRecover() 훅 (현재는 비활성)
  ↓
선택적 자동 복구 (향후 확장 시)
```
