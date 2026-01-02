# Petgram 카메라 모듈 A 구조 리팩토링 보고서

**작성일**: 2025-01-XX  
**목표**: 네이티브 FSM 완전 전담, Flutter는 리모컨+상태뷰만

---

## 1. 구조 요약

### ✅ 현재 구현된 부분 (A 구조 준수)

1. **네이티브 FSM 구현**

   - `ios/Runner/NativeCamera.swift`에 `CameraState` enum 구현됨 (idle, initializing, ready, capturing, error, recovering)
   - `cameraState` 프로퍼티에 `didSet`으로 상태 변경 시 `notifyStateChange()` 호출
   - 촬영 완료 시 `capturing → ready` 자동 복귀

2. **Flutter 생명주기 개입 제거**

   - `home_page.dart:2357-2371`: `didChangeAppLifecycleState()`에서 카메라 재시작 코드 제거됨
   - `_pauseCameraSession()`, `_resumeCameraSession()` 메서드 제거됨

3. **상태 판단 로직 단순화**

   - `home_page.dart:599-613`: `canUseCamera`가 네이티브 상태를 읽기만 함
   - `home_page.dart:547-563`: `_isCameraHealthy`도 읽기 전용

4. **촬영 중 보호**
   - `camera_engine.dart:85-86`: `_isCapturingPhoto`, `_captureFenceUntil` 플래그 존재
   - `camera_engine.dart:314-319`: 촬영 중 `initializeNativeCameraOnce` 차단
   - `native_camera.swift:905-912`: 네이티브에서도 촬영 중 초기화 차단

### ❌ 아직 남아있는 B 구조 잔재 (수정 필요)

1. **Flutter에서 직접 초기화 호출**

   - `home_page.dart:6125-6140`: `onPlatformViewCreated`에서 `initializeNativeCameraOnce()` 직접 호출
   - `camera_engine.dart:289-401`: `initializeNativeCameraOnce()` 메서드가 여전히 존재하고 호출됨
   - `camera_engine.dart:722-849`: `initialize()` 메서드가 네이티브 초기화를 직접 호출

2. **Flutter 내부 상태 플래그 관리**

   - `camera_engine.dart:87`: `_hasInitializedOnce` 플래그로 Flutter가 초기화를 "제어"함
   - `camera_engine.dart:80-83`: `_isInitializing`, `_isInitializingNative`, `_isResuming` 등 Flutter가 관리하는 상태

3. **네이티브 초기화 조건 판단을 Flutter에서 수행**

   - `camera_engine.dart:445-480`: Flutter에서 "healthy 상태"를 판단하여 초기화 여부 결정
   - `camera_engine.dart:482-507`: Flutter에서 "hasFrameButStopped"를 판단하여 resume 결정

4. **@Deprecated 메서드가 여전히 존재**
   - `home_page.dart:1864-1941`: `_manualRestartCamera()` 메서드 존재 (호출되는지 확인 필요)
   - `home_page.dart:1946-2334`: `_initCameraPipeline()` 메서드 존재 (호출되는지 확인 필요)

---

## 2. 위험/걱정 포인트 리스트

### 🔴 심각 (즉시 수정 필요)

#### [1] `home_page.dart:6125-6140` - Flutter가 직접 초기화를 트리거

**문제**: `onPlatformViewCreated`에서 `initializeNativeCameraOnce()`를 직접 호출  
**위험 시나리오**:

- PlatformView가 재생성될 때마다 Flutter가 초기화를 시도
- 네이티브 FSM이 이미 `initializing` 상태인데 Flutter가 또 초기화 요청 → race condition
- 촬영 중에 View가 rebuild되면 초기화가 들어갈 가능성

**수정 필요**: 네이티브가 `autoInitialize()` 또는 `viewDidLoad`에서 자동으로 초기화하도록 변경, Flutter는 `attachNativeView(viewId)`만 호출

---

#### [2] `camera_engine.dart:289-401` - `initializeNativeCameraOnce()`의 "한 번만" 로직

**문제**: Flutter가 `_hasInitializedOnce` 플래그로 초기화를 "제어"함  
**위험 시나리오**:

- 네이티브에서 세션이 죽었을 때 Flutter가 재초기화를 막음
- 네이티브 FSM이 `error → recovering`을 시도하지만 Flutter 플래그가 false라서 Flutter에서 재초기화를 막음
- 네이티브와 Flutter의 "초기화" 개념이 불일치

**수정 필요**: 이 메서드를 완전히 제거하거나, 단순히 네이티브에 "initializeIfNeeded()" 명령만 보내도록 변경

---

#### [3] `camera_engine.dart:722-849` - `initialize()` 메서드의 네이티브 상태 판단

**문제**: Flutter가 네이티브 상태를 확인하고 "이미 초기화되었으면 스킵" 로직을 가짐  
**위험 시나리오**:

- 네이티브가 `ready` 상태인데 Flutter가 내부 플래그만 보고 재초기화 시도
- 네이티브와 Flutter의 상태 불일치로 인한 이중 초기화

**수정 필요**: `initialize()` 메서드 제거 또는 단순히 네이티브 명령만 전달하도록 변경

---

#### [4] `camera_engine.dart:445-507` - Flutter에서 "healthy 상태" 판단

**문제**: Flutter가 `isHealthy()` 헬퍼로 세션 상태를 판단하고 초기화 여부 결정  
**위험 시나리오**:

- 네이티브 FSM이 `error` 상태로 전환되었는데 Flutter가 "healthy"로 판단하여 초기화 스킵
- 네이티브와 Flutter의 상태 동기화 지연으로 인한 판단 오류

**수정 필요**: 이 판단 로직 제거, 네이티브 FSM에 맡김

---

### 🟡 중간 (주의 필요)

#### [5] `home_page.dart:1946-2334` - `_initCameraPipeline()` @Deprecated

**상태**: 메서드는 존재하지만 호출되는지 확인 필요  
**확인 사항**:

- 이 메서드가 실제로 호출되는지 grep으로 확인
- 호출되지 않는다면 완전 삭제

---

#### [6] `home_page.dart:1864-1941` - `_manualRestartCamera()` @Deprecated

**상태**: 메서드는 존재하지만 호출되는지 확인 필요  
**확인 사항**:

- UI에서 "카메라 재시작" 버튼이 있는지 확인
- 있다면 네이티브 `restartSession()` 명령으로 변경 필요

---

#### [7] `camera_engine.dart:503-507` - Flutter에서 `resumeSession()` 직접 호출

**문제**: `hasFrameButStopped` 상황에서 Flutter가 네이티브 `resumeSession()` 직접 호출  
**위험 시나리오**:

- 네이티브 FSM이 이미 `recovering` 상태인데 Flutter가 `resumeSession()` 호출 → 충돌
- 네이티브 FSM이 `error` 상태에서 자동 복구를 시도 중인데 Flutter가 개입

**수정 필요**: 이 로직 제거, 네이티브 FSM의 `recoverIfNeeded()`에 맡김

---

### 🟢 경미 (정리 필요)

#### [8] 네이티브 FSM 메서드 불완전

**현재 상태**:

- `ios/Runner/NativeCamera.swift`에 `initializeIfNeeded()`, `recoverIfNeeded()`, `restartSession()` 메서드가 구현되어 있는지 확인 필요
- `autoInitialize()`가 `viewDidLoad`에서 호출되는지 확인 필요

**확인 사항**: 네이티브 코드에서 이 메서드들의 구현 상태 확인

---

#### [9] viewId 관리

**현재 상태**:

- `NativeCameraController.setViewId()` 존재
- `NativeCameraViewController.viewId` 프로퍼티 존재
- `NativeCameraRegistry`를 통한 인스턴스 매핑 존재

**확인 사항**: viewId mismatch 에러가 발생하는 경로가 있는지 확인

---

## 3. 수정해야 할 부분 – 구체 코드 제안

### (1) Flutter 쪽

#### ✅ 수정 1: `home_page.dart:6125-6140` - onCreated에서 초기화 제거

**현재 코드**:

```dart
// 2) initializeNativeCameraOnce: 네이티브에 한 번만 초기화 요청
_cameraEngine.initializeNativeCameraOnce(
  viewId: viewId,
  cameraPosition: _cameraLensDirection == CameraLensDirection.back ? 'back' : 'front',
  aspectRatio: aspectRatioOf(_aspectMode),
);
```

**수정 후**:

```dart
// 🔥 A 구조: 네이티브가 자동으로 초기화하므로 Flutter는 attachNativeView만 호출
// 네이티브의 autoInitialize() 또는 viewDidLoad에서 자동으로 초기화됨
_cameraEngine.attachNativeView(viewId);

// 네이티브에 초기화 "명령"을 보내는 대신, 네이티브가 알아서 initializeIfNeeded() 호출
// 필요하다면 네이티브에 "초기화 요청" 이벤트만 전달 (선택사항)
```

---

#### ✅ 수정 2: `camera_engine.dart:289-401` - `initializeNativeCameraOnce()` 제거 또는 단순화

**현재 코드**: 복잡한 로직으로 Flutter가 초기화를 "제어"함

**수정 후** (옵션 1: 완전 제거):

```dart
// 🔥 제거됨: initializeNativeCameraOnce
// 네이티브 FSM이 자동으로 초기화를 처리하므로 Flutter에서 호출 불필요
```

**수정 후** (옵션 2: 단순 명령 전달):

```dart
/// 네이티브에 초기화 요청만 전달 (실제 초기화는 네이티브 FSM이 결정)
Future<void> requestInitializeIfNeeded({
  required int viewId,
  required String cameraPosition,
  double? aspectRatio,
}) async {
  if (_nativeCamera == null) {
    throw StateError('NativeCameraController is null. Call attachNativeView() first.');
  }

  // 네이티브에 "초기화가 필요하면 해달라"는 명령만 전달
  if (_nativeCamera is NativeCameraController) {
    final controller = _nativeCamera as NativeCameraController;
    await controller.requestInitializeIfNeeded(
      viewId: viewId,
      cameraPosition: cameraPosition,
      aspectRatio: aspectRatio,
    );
  }
}
```

---

#### ✅ 수정 3: `camera_engine.dart:722-849` - `initialize()` 메서드 단순화

**현재 코드**: Flutter가 네이티브 상태를 확인하고 초기화 여부 결정

**수정 후**:

```dart
/// 카메라 초기화 (네이티브 FSM에 명령만 전달)
Future<void> initialize({
  required String cameraPosition,
  double? aspectRatio,
}) async {
  if (_isCapturingPhoto) {
    _emitDebugLog('[CameraEngine] ⚠️ initialize blocked: photo capture in progress');
    return;
  }

  if (_nativeCamera == null) {
    throw StateError('NativeCameraController is null. Call attachNativeView() first.');
  }

  // 🔥 A 구조: 네이티브 FSM에 초기화 명령만 전달 (FSM이 상태 확인 후 처리)
  if (_nativeCamera is NativeCameraController) {
    final controller = _nativeCamera as NativeCameraController;
    await controller.initializeIfNeeded(
      cameraPosition: cameraPosition,
      aspectRatio: aspectRatio,
    );
  }

  // Flutter는 상태를 읽기만 하고, 네이티브가 초기화 완료를 알려줄 때까지 대기
  // (onCameraInitialized 콜백 또는 getDebugState 폴링)
}
```

---

#### ✅ 수정 4: `camera_engine.dart:445-507` - healthy 상태 판단 로직 제거

**현재 코드**:

```dart
bool isHealthy(Object? state) { ... }
// ...
if (isHealthy(currentState)) {
  return false; // 이미 건강한 세션 (재시도 없음)
}
```

**수정 후**:

```dart
// 🔥 제거됨: Flutter에서 healthy 상태 판단
// 네이티브 FSM이 상태를 관리하므로, Flutter는 무조건 네이티브에 명령만 전달
// 네이티브 FSM이 initializeIfNeeded() 내부에서 상태를 확인하고 처리
```

---

#### ✅ 수정 5: `camera_engine.dart:482-507` - resumeSession 직접 호출 제거

**현재 코드**:

```dart
if (hasFrameButStopped) {
  await (_nativeCamera as NativeCameraController).resumeSession();
  return false;
}
```

**수정 후**:

```dart
// 🔥 제거됨: Flutter에서 resumeSession 직접 호출
// 네이티브 FSM의 recoverIfNeeded()가 자동으로 처리
// Flutter는 상태를 읽기만 하고, 네이티브가 자동 복구를 수행
```

---

#### ✅ 수정 6: `home_page.dart:1946-2334` - `_initCameraPipeline()` 완전 삭제

**확인 후 작업**:

1. 이 메서드가 호출되는지 grep으로 확인
2. 호출되지 않는다면 완전 삭제
3. 호출된다면 호출부도 제거

---

#### ✅ 수정 7: `home_page.dart:1864-1941` - `_manualRestartCamera()` 완전 삭제 또는 네이티브 명령으로 변경

**확인 후 작업**:

1. UI에서 이 메서드를 호출하는지 확인
2. 호출되지 않는다면 완전 삭제
3. 호출된다면 네이티브 `restartSession()` 명령으로 변경:

```dart
// 수정 후
Future<void> _requestCameraRestart() async {
  if (_cameraEngine.nativeCamera is NativeCameraController) {
    final controller = _cameraEngine.nativeCamera as NativeCameraController;
    await controller.restartSession(); // 네이티브 FSM에 명령만 전달
  }
}
```

---

### (2) 네이티브(Swift) 쪽

#### ✅ 수정 8: `ios/Runner/NativeCamera.swift` - `autoInitialize()` 구현 확인 및 보완

**확인 필요**:

1. `viewDidLoad()`에서 `autoInitialize()` 호출되는지
2. `autoInitialize()` 메서드가 존재하는지

**수정 후** (없다면 추가):

```swift
override func viewDidLoad() {
    super.viewDidLoad()

    // 🔥 A 구조: ViewController가 로드되면 자동으로 초기화 시도
    autoInitialize()
}

private func autoInitialize() {
    guard cameraState == .idle || cameraState == .error else {
        log("[Native] ⏸️ autoInitialize skipped: cameraState=\(cameraState.description)")
        return
    }

    guard !isRunningOperationInProgress else {
        log("[Native] ⏸️ autoInitialize skipped: operation in progress")
        return
    }

    log("[Native] 🔄 autoInitialize: calling initializeIfNeeded()")
    initializeIfNeeded()
}
```

---

#### ✅ 수정 9: `ios/Runner/NativeCamera.swift` - `initializeIfNeeded()` 구현 확인

**확인 필요**:

1. 메서드가 존재하는지
2. FSM 상태를 확인하고 적절히 처리하는지

**수정 후** (없다면 추가, 있다면 보완):

```swift
/// 네이티브 FSM: 필요할 때만 초기화 (Flutter에서 호출 가능)
func initializeIfNeeded() {
    sessionQueue.async { [weak self] in
        guard let self else { return }

        // 🔥 FSM 상태 확인: idle 또는 error 상태에서만 초기화
        guard self.cameraState == .idle || self.cameraState == .error else {
            self.log("[FSM] ⏸️ initializeIfNeeded skipped: already \(self.cameraState.description)")
            return
        }

        // 촬영 중이면 초기화 차단
        guard !self.isCapturingPhoto else {
            self.log("[FSM] ⏸️ initializeIfNeeded blocked: photo capture in progress")
            return
        }

        // operation in progress 체크
        guard !self.isRunningOperationInProgress else {
            self.log("[FSM] ⏸️ initializeIfNeeded blocked: operation in progress")
            return
        }

        self.log("[FSM] ✅ initializeIfNeeded: starting initialization")
        self.initialize(position: self.currentPosition) { result in
            switch result {
            case .success:
                self.log("[FSM] ✅ initializeIfNeeded: initialization completed")
            case .failure(let error):
                self.log("[FSM] ❌ initializeIfNeeded: initialization failed: \(error.localizedDescription)")
                // FSM이 자동으로 error 상태로 전환됨
            }
        }
    }
}
```

---

#### ✅ 수정 10: `ios/Runner/NativeCamera.swift` - `restartSession()` 구현 확인

**확인 필요**:

1. 메서드가 존재하는지
2. FSM 상태를 고려하여 처리하는지

**수정 후** (없다면 추가):

```swift
/// 네이티브 FSM: 세션 재시작 (Flutter에서 명령으로 호출 가능)
func restartSession() {
    sessionQueue.async { [weak self] in
        guard let self else { return }

        // 촬영 중이면 재시작 차단
        guard !self.isCapturingPhoto else {
            self.log("[FSM] ⏸️ restartSession blocked: photo capture in progress")
            return
        }

        self.log("[FSM] 🔄 restartSession: stopping session")

        if self.session.isRunning {
            self.session.stopRunning()
        }

        self.log("[FSM] 🔄 restartSession: restarting session")
        self.session.startRunning()

        // 상태 확인 및 FSM 전이
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if self.session.isRunning && self.hasFirstFrame {
                self.cameraState = .ready
            } else {
                self.cameraState = .error
                self.recoverIfNeeded()
            }
        }
    }
}
```

---

#### ✅ 수정 11: `ios/Runner/NativeCamera.swift` - MethodChannel에 `initializeIfNeeded`, `restartSession` 추가

**수정 후**:

```swift
// handleMethodCall 메서드에 추가
case "initializeIfNeeded":
    guard let args = call.arguments as? [String: Any] else {
        result(FlutterError(code: "INVALID_ARGS", message: "Invalid arguments", details: nil))
        return
    }
    let position = (args["cameraPosition"] as? String) == "front" ? AVCaptureDevice.Position.front : .back
    initializeIfNeeded()
    result(nil)

case "restartSession":
    restartSession()
    result(nil)
```

---

## 4. 최종 체크리스트

### ✅ Flutter 쪽

- [ ] `home_page.dart:6125-6140`: `onCreated`에서 `initializeNativeCameraOnce()` 호출 제거
- [ ] `camera_engine.dart:289-401`: `initializeNativeCameraOnce()` 제거 또는 단순 명령 전달로 변경
- [ ] `camera_engine.dart:722-849`: `initialize()` 메서드 단순화 (네이티브 명령만 전달)
- [ ] `camera_engine.dart:445-507`: healthy 상태 판단 로직 제거
- [ ] `camera_engine.dart:482-507`: `resumeSession()` 직접 호출 제거
- [ ] `home_page.dart:1946-2334`: `_initCameraPipeline()` 호출 확인 후 삭제
- [ ] `home_page.dart:1864-1941`: `_manualRestartCamera()` 호출 확인 후 삭제 또는 네이티브 명령으로 변경
- [ ] `didChangeAppLifecycleState()`: 카메라 재시작 코드 없음 확인 (이미 완료됨)

### ✅ 네이티브 쪽

- [ ] `ios/Runner/NativeCamera.swift`: `autoInitialize()` 메서드 구현 및 `viewDidLoad()`에서 호출
- [ ] `ios/Runner/NativeCamera.swift`: `initializeIfNeeded()` 메서드 구현 및 FSM 상태 확인
- [ ] `ios/Runner/NativeCamera.swift`: `restartSession()` 메서드 구현
- [ ] `ios/Runner/NativeCamera.swift`: MethodChannel에 `initializeIfNeeded`, `restartSession` 추가
- [ ] `ios/Runner/NativeCamera.swift`: `recoverIfNeeded()` 메서드가 제대로 동작하는지 확인

### ✅ 공통

- [ ] Flutter에서 `canUseCamera`, `_isCameraHealthy`는 네이티브 상태 read-only 확인
- [ ] 촬영 중 재시작/초기화 경로 차단 확인 (네이티브와 Flutter 양쪽에서)
- [ ] viewId mismatch / NO_CAMERA_VIEW 발생 가능성 제거
- [ ] 디버그/폴링은 상태 조회 전용 확인 (`_pollDebugState` 등)

---

## 5. 추가 확인 사항

### 네이티브 FSM 상태 전이 다이어그램 (현재 구현 기준)

```
idle
  → initialize() 호출 또는 autoInitialize()
  → initializing
    → 성공
    → ready
      → capturePhoto()
      → capturing
        → 촬영 완료
        → ready
      → setZoom, setFilter 등 (ready 상태 유지)
    → 실패
    → error
      → recoverIfNeeded()
      → recovering
        → 성공
        → ready
        → 실패
        → error (재시도 횟수 초과 시 idle 또는 유지)

ready
  → 세션 끊김 감지
  → error
  → recoverIfNeeded()
  → recovering
```

### 허용되는 Flutter → Native 명령

1. `capturePhoto()` - ready 상태에서만 허용 (네이티브에서 체크)
2. `setZoom()` - ready 상태에서 허용
3. `setFilter()` - ready 상태에서 허용
4. `setExposureBias()` - ready 상태에서 허용
5. `switchCamera()` - ready 상태에서 허용 (내부적으로 재초기화)
6. `initializeIfNeeded()` - idle/error 상태에서만 허용 (네이티브에서 체크)
7. `restartSession()` - ready/error 상태에서 허용 (네이티브에서 체크)
8. `getDebugState()` - 항상 허용 (읽기 전용)

---

## 6. 테스트 시나리오

리팩토링 후 다음 시나리오를 테스트:

1. **앱 시작**: 네이티브가 자동으로 초기화하는지 확인
2. **PlatformView 재생성**: Flutter에서 재초기화를 호출하지 않는지 확인
3. **촬영 중 View rebuild**: 촬영이 중단되지 않는지 확인
4. **백그라운드/포그라운드 전환**: 네이티브가 자동으로 처리하는지 확인
5. **네트워크 끊김/카메라 오류**: 네이티브 FSM이 자동 복구하는지 확인
6. **viewId 변경**: 인스턴스 매핑이 올바르게 동작하는지 확인

---

## 7. 참고 파일 목록

- `lib/pages/home_page.dart` (9383 lines)
- `lib/services/camera_engine.dart` (1823 lines)
- `lib/camera/native_camera_controller.dart` (796 lines)
- `ios/Runner/NativeCamera.swift` (7593 lines)
