# 디버그 오버레이 전송 확인 결과

## ✅ 확인 완료: 모든 디버그 로그가 디버그 오버레이에 전송됨

### 1. 네이티브 측 로그 전송 체인

#### 모든 주요 로그에 `NativeCamera.sendDebugLog` 포함 확인:

**initializeIfNeeded 함수 내 로그들:**

- ✅ 라인 816: `beforeAsyncMsg` - `NativeCamera.sendDebugLog` 포함
- ✅ 라인 826: `queueCheckMsg` - `NativeCamera.sendDebugLog` 포함
- ✅ 라인 839: `blockEnteredMsg` (self 있을 때) - `NativeCamera.sendDebugLog` 포함
- ✅ 라인 847: `nilSelfMsg` (self nil일 때) - `NativeCamera.sendDebugLog` 포함
- ✅ 라인 856: `deallocMsg` (guard 실패 시) - `NativeCamera.sendDebugLog` 포함
- ✅ 라인 877: `stepSetMsg` - `NativeCamera.sendDebugLog` 포함
- ✅ 라인 887: `stepVerifyMsg` - `NativeCamera.sendDebugLog` 포함
- ✅ 라인 897: `queueEnterMsg` - `NativeCamera.sendDebugLog` 포함
- ✅ 라인 907: `beforeHealthCheckMsg` - `NativeCamera.sendDebugLog` 포함
- ✅ 라인 927: `stateCheckMsg` - `NativeCamera.sendDebugLog` 포함
- ✅ 라인 947: `skipMsg` (healthy early return) - `NativeCamera.sendDebugLog` 포함
- ✅ 라인 960: `healthCheckFailedMsg` - `NativeCamera.sendDebugLog` 포함
- ✅ 라인 967: `incompleteMsg` - `NativeCamera.sendDebugLog` 포함
- ✅ 라인 994: `clearedMsg` - `NativeCamera.sendDebugLog` 포함
- ✅ 라인 1006: `timeoutMsg` - `NativeCamera.sendDebugLog` 포함
- ✅ 라인 1019: `skipMsg` (operation in progress) - `NativeCamera.sendDebugLog` 포함
- ✅ 라인 1028: `forceUnlockMsg` - `NativeCamera.sendDebugLog` 포함
- ✅ 라인 1043: `passedChecksMsg` - `NativeCamera.sendDebugLog` 포함
- ✅ 라인 1059: `aboutToInitMsg` - `NativeCamera.sendDebugLog` 포함
- ✅ 라인 1069: `callingInitMsg` - `NativeCamera.sendDebugLog` 포함
- ✅ 라인 1113: `initCompletionMsg` - `NativeCamera.sendDebugLog` 포함

### 2. NativeCamera.sendDebugLog 구현 확인

**파일**: `ios/Runner/NativeCamera.swift` (라인 7655-7682)

```swift
static func sendDebugLog(viewId: Int64?, message: String) {
    // 🔥 실기기에서도 디버그 오버레이 표시: 디버그 빌드에서는 항상 전송
    guard isNativeDebugOverlayEnabled else {
        // 디버그 빌드가 아닐 때는 콘솔에만 출력
        #if DEBUG
        print(message)
        #endif
        return
    }
    guard let channel = logChannel else {
        // 채널이 없을 때는 콘솔에만 출력
        #if DEBUG
        print("[NativeCamera] ⚠️ logChannel is nil: \(message)")
        #endif
        return
    }
    // 🔥 실기기에서도 디버그 오버레이 표시: 항상 전송 시도
    channel.invokeMethod("onDebugLog", arguments: [
        "viewId": viewId ?? -1,
        "message": message
    ]) { (result: Any?) in
        if let error = result as? FlutterError {
            #if DEBUG
            print("[NativeCamera] ⚠️ sendDebugLog failed: \(error.code) - \(error.message ?? "no message")")
            #endif
        }
    }
}
```

**특징**:

- ✅ `isNativeDebugOverlayEnabled`가 `true`이면 항상 전송
- ✅ `logChannel`이 nil이 아니면 `onDebugLog` 메서드 호출
- ✅ 실기기에서도 디버그 오버레이 표시 가능

### 3. Flutter 측 수신 체인 확인

#### NativeCameraController (lib/camera/native_camera_controller.dart)

**라인 64**: MethodChannel 핸들러 등록

```dart
_channel.setMethodCallHandler(_handleMethodCall);
```

**라인 97-106**: `onDebugLog` 메서드 처리

```dart
case 'onDebugLog':
  // 네이티브에서 보낸 디버그 로그를 처리
  final message = call.arguments['message'] as String?];
  if (message != null) {
    // 콜백으로 전달 (home_page에서 처리)
    for (final listener in _debugLogListeners) {
      listener(message);
    }
  }
  break;
```

**라인 112-115**: 디버그 로그 리스너 추가

```dart
void addDebugLogListener(Function(String) listener) {
  _debugLogListeners.add(listener);
}
```

#### HomePage (lib/pages/home_page.dart)

**라인 2187-2189**: 디버그 로그 리스너 등록

```dart
_cameraEngine.addDebugLogListener((message) {
  _addDebugLog(message);
});
```

**라인 143-172**: `_addDebugLog` 함수 - 디버그 오버레이에 표시

```dart
void _addDebugLog(String log) {
  if (!mounted) return;

  // 중복 체크
  if (_debugLogs.isNotEmpty && _debugLogs.last == log) {
    return;
  }

  // 파일에 저장 (크래시 디버깅용)
  _saveDebugLogToFile(log);

  // 디버그 오버레이 표시
  if (!kEnableCameraDebugOverlay) return;

  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (mounted) {
      setState(() {
        if (_debugLogs.isEmpty || _debugLogs.last != log) {
          _debugLogs.add(log);
          if (_debugLogs.length > _maxDebugLogs) {
            _debugLogs.removeAt(0);
          }
        }
      });
    }
  });
}
```

**라인 97**: 디버그 오버레이 활성화 플래그

```dart
static const bool kEnableCameraDebugOverlay = true; // 🔥 릴리즈 빌드에서도 디버그 오버레이 표시
```

## ✅ 전체 체인 확인 완료

```
네이티브 (NativeCamera.swift)
  ↓ NativeCamera.sendDebugLog(viewId:message:)
  ↓ channel.invokeMethod("onDebugLog", ...)
  ↓
Flutter (NativeCameraController)
  ↓ _handleMethodCall("onDebugLog")
  ↓ _debugLogListeners.forEach(listener)
  ↓
Flutter (HomePage)
  ↓ _cameraEngine.addDebugLogListener
  ↓ _addDebugLog(message)
  ↓ setState(() { _debugLogs.add(log) })
  ↓
디버그 오버레이 표시 ✅
```

## 결론

**모든 추가된 디버그 로그가 실기기에서 디버그 오버레이에 표시되도록 설정되어 있습니다.**

### 확인 사항:

1. ✅ 모든 주요 로그에 `NativeCamera.sendDebugLog` 호출 포함
2. ✅ `NativeCamera.sendDebugLog`가 `onDebugLog` 메서드로 Flutter에 전송
3. ✅ `NativeCameraController`가 `onDebugLog` 메서드를 처리
4. ✅ `HomePage`가 디버그 로그 리스너를 등록하고 `_addDebugLog`로 처리
5. ✅ `kEnableCameraDebugOverlay = true`로 설정되어 디버그 오버레이 활성화

### 실기기에서 확인할 로그들:

- `[Native] 🔥🔥🔥 initializeIfNeeded: sessionQueue.async BLOCK ENTERED`
- `[Native] 🔥🔥🔥 initializeIfNeeded: step set to 'in_session_queue', instancePtr=...`
- `[Native] 🔥🔥🔥 initializeIfNeeded: VERIFY step='in_session_queue', instancePtr=...`
- `[Native] 🔥🔥🔥 initializeIfNeeded: Entered sessionQueue (step=in_session_queue), instancePtr=...`
- `[Native] 🔥🔥🔥 BEFORE HEALTH CHECK: ...`
- `[Native] 🔥🔥🔥 initializeIfNeeded HEALTH CHECK: ...`
- 기타 모든 `🔥🔥🔥` 표시된 로그들

