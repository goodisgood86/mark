# AF 아이콘 및 로딩 문제 분석 및 수정 방안

## 문제 5: AF 아이콘이 실제 초점 상태와 동기화되지 않는 문제

### 1. 관련 코드 위치

#### 네이티브 (iOS)
- **파일**: `ios/Runner/NativeCamera.swift`
- **메서드**: `getFocusStatus()` (라인 3370-3420)
- **상태 감지**: `device.isAdjustingFocus`, `device.focusMode`

#### Flutter
- **파일**: `lib/pages/home_page.dart`
- **상태 변수**: 
  - `_isAutoFocusEnabled` (라인 643): AF 활성화 여부
  - `_isFocusAdjusting` (라인 644): 포커스 조정 중 여부
- **폴링**: `_startFocusStatusPolling()` (라인 162), `_pollFocusStatus()` (라인 180)
- **UI**: `_buildAutoFocusStatusIndicator()` (라인 3083)

#### 연결 채널
- **MethodChannel**: `petgram/native_camera`
- **메서드**: `getFocusStatus`

### 2. AF 상태 흐름 (현재)

```
1. 네이티브 (iOS):
   - AVCaptureDevice.isAdjustingFocus 읽기
   - focusMode 읽기 (continuousAutoFocus, autoFocus, locked)
   → Map 반환: {"isAdjustingFocus": bool, "focusMode": string}

2. MethodChannel:
   - Flutter에서 300ms마다 getFocusStatus 호출
   - 네이티브에서 동기적으로 상태 반환

3. Flutter:
   - _pollFocusStatus()에서 상태 수신
   - _isFocusAdjusting 업데이트
   - _buildAutoFocusStatusIndicator()에서 UI 업데이트
     - isAdjusting = true → 주황색 (조정 중)
     - isAdjusting = false → 초록색 (완료)
```

### 3. 문제 원인 분석

#### a) AF 완료 이벤트만 전달되는 문제
**현재 코드:**
```dart
// lib/pages/home_page.dart:189-197
final isAdjusting = status['isAdjustingFocus'] as bool? ?? false;
if (_isFocusAdjusting != isAdjusting) {
  setState(() {
    _isFocusAdjusting = isAdjusting;
  });
}
```

**문제점:**
- `isAdjustingFocus`가 false가 되면 초록색으로 표시
- 하지만 실제로 초점이 맞춰졌는지 확인하지 않음
- 카메라를 이동해도 `isAdjustingFocus`가 false이면 계속 초록색 유지

#### b) Flutter에서 상태를 false로 되돌리는 경로 부재
**현재 코드:**
```dart
// lib/pages/home_page.dart:3085-3090
final isAdjusting = _isFocusAdjusting;
final borderColor = isAdjusting
    ? Colors.orange.withValues(alpha: 0.8)
    : Colors.green.withValues(alpha: 0.8);
```

**문제점:**
- `isAdjusting = false`일 때 무조건 초록색 표시
- 실제 초점 상태(성공/실패/대기)를 구분하지 않음

#### c) 네이티브에서 AF 상태를 세밀하게 전달하지 않음
**현재 코드:**
```swift
// ios/Runner/NativeCamera.swift:3406-3420
let isAdjusting = device.isAdjustingFocus
let focusModeStr: String
switch device.focusMode {
case .locked:
    focusModeStr = "locked"
case .autoFocus:
    focusModeStr = "autoFocus"
case .continuousAutoFocus:
    focusModeStr = "continuousAutoFocus"
}
```

**문제점:**
- `isAdjustingFocus`만 전달
- 초점 성공/실패 여부를 판단할 수 없음
- `continuousAutoFocus` 모드에서는 항상 조정 중일 수 있음

### 4. 수정 방안

#### a) 네이티브에서 AF 상태 세분화

**iOS 네이티브 수정:**
```swift
// ios/Runner/NativeCamera.swift
case "getFocusStatus":
    // 포커스 상태를 세 가지로 구분
    let isAdjusting = device.isAdjustingFocus
    let focusMode = device.focusMode
    
    // 초점 상태 판단
    var focusStatus: String = "unknown"
    if isAdjusting {
        focusStatus = "adjusting" // 조정 중
    } else if focusMode == .continuousAutoFocus {
        // continuousAutoFocus 모드에서는 초점이 계속 조정되므로
        // isAdjustingFocus가 false여도 "ready" 상태로 간주
        focusStatus = "ready" // 준비됨 (초점 잡힘)
    } else if focusMode == .locked {
        focusStatus = "locked" // 고정됨
    } else {
        focusStatus = "ready" // 준비됨
    }
    
    result([
        "isAdjustingFocus": isAdjusting,
        "focusMode": focusModeStr,
        "focusStatus": focusStatus // 추가: 세분화된 상태
    ])
```

#### b) Flutter에서 세 가지 상태로 UI 업데이트

**Flutter 수정:**
```dart
// lib/pages/home_page.dart
enum FocusStatus {
  adjusting,  // 조정 중 (주황색)
  ready,      // 준비됨/초점 잡힘 (초록색)
  locked,     // 고정됨 (회색)
  unknown,    // 알 수 없음 (회색)
}

FocusStatus _focusStatus = FocusStatus.unknown;

Future<void> _pollFocusStatus() async {
  // ...
  final status = await _cameraEngine.nativeCamera?.getFocusStatus();
  if (status != null) {
    final isAdjusting = status['isAdjustingFocus'] as bool? ?? false;
    final focusStatusStr = status['focusStatus'] as String? ?? 'unknown';
    
    FocusStatus newStatus;
    switch (focusStatusStr) {
      case 'adjusting':
        newStatus = FocusStatus.adjusting;
        break;
      case 'ready':
        newStatus = FocusStatus.ready;
        break;
      case 'locked':
        newStatus = FocusStatus.locked;
        break;
      default:
        newStatus = FocusStatus.unknown;
    }
    
    if (_focusStatus != newStatus) {
      if (mounted) {
        setState(() {
          _focusStatus = newStatus;
          _isFocusAdjusting = isAdjusting; // 호환성 유지
        });
      }
    }
  }
}

Widget _buildAutoFocusStatusIndicator() {
  Color borderColor;
  Color iconColor;
  Color textColor;
  
  switch (_focusStatus) {
    case FocusStatus.adjusting:
      borderColor = Colors.orange.withValues(alpha: 0.8);
      iconColor = Colors.orangeAccent;
      textColor = Colors.orangeAccent;
      break;
    case FocusStatus.ready:
      borderColor = Colors.green.withValues(alpha: 0.8);
      iconColor = Colors.greenAccent;
      textColor = Colors.greenAccent;
      break;
    case FocusStatus.locked:
    case FocusStatus.unknown:
    default:
      borderColor = Colors.grey.withValues(alpha: 0.8);
      iconColor = Colors.grey;
      textColor = Colors.grey;
      break;
  }
  // ... UI 빌드
}
```

## 문제 6: 카메라 화면 복귀 시 작은 로딩 아이콘 무한 로딩

### 1. 화면 이동/복귀 시 카메라 라이프사이클

#### 현재 구조

**카메라 페이지 진입 시:**
- `initState()` → `_initCameraPipeline()` 호출
- `_cameraEngine.initialize()` 호출
- `_isCameraReady`가 true가 될 때까지 대기

**카메라 페이지 이탈 시:**
- `dispose()` 호출
- `_cameraEngine.dispose()` 호출
- `_stopFocusStatusPolling()` 호출

**다시 카메라 페이지로 복귀 시:**
- `initState()` 다시 호출
- `_initCameraPipeline()` 다시 호출
- 하지만 이전 세션이 완전히 정리되지 않았을 수 있음

### 2. "작은 로딩 아이콘" 상태 관리

**로딩 아이콘 표시 조건:**
```dart
// lib/pages/home_page.dart:4290
if (isCameraInitializing && hasNativeCamera) {
  cameraPreviewWidget = Container(
    color: Colors.black,
    child: Center(
      child: SizedBox(
        width: 48.0,
        height: 48.0,
        child: const CircularProgressIndicator(...),
      ),
    ),
  );
}
```

**문제점:**
- `isCameraInitializing`이 true에서 false로 돌아오지 않으면 무한 로딩
- 초기화 실패 시에도 `isCameraInitializing`이 false로 돌아오지 않을 수 있음

### 3. 네이티브 카메라 초기화/해제 로직 점검

**현재 dispose 로직:**
```dart
// lib/services/camera_engine.dart:485-491
void dispose() {
  _isInitializing = false;
  _useMockCamera = false;
  _initErrorMessage = null;
  _listeners.clear();
  _notifyListeners();
}
```

**문제점:**
- `_nativeCamera?.dispose()`를 호출하지 않음
- 네이티브 세션이 완전히 정리되지 않을 수 있음

### 4. 수정 방안

#### a) CameraEngine.dispose() 개선

```dart
// lib/services/camera_engine.dart
void dispose() {
  // 네이티브 카메라 완전히 정리
  _nativeCamera?.dispose().then((_) {
    _nativeCamera = null;
  }).catchError((e) {
    debugPrint('[CameraEngine] Dispose error: $e');
  });
  
  _isInitializing = false;
  _useMockCamera = false;
  _initErrorMessage = null;
  _setState(CameraState.idle); // 상태 초기화
  _listeners.clear();
  _notifyListeners();
}
```

#### b) 초기화 실패 시 상태 보장

```dart
// lib/pages/home_page.dart: _initCameraPipeline()
Future<void> _initCameraPipeline() async {
  try {
    // 초기화 시작
    setState(() {
      // 상태는 CameraEngine에서 관리
    });
    
    await _cameraEngine.initialize(...);
    
    // 초기화 완료 확인
    if (!_cameraEngine.isInitialized) {
      // 초기화 실패 처리
      if (mounted) {
        setState(() {
          // 상태 초기화 보장
        });
      }
    }
  } catch (e) {
    // 에러 발생 시 상태 초기화 보장
    if (mounted) {
      setState(() {
        // CameraEngine 상태 확인 및 초기화
      });
    }
  } finally {
    // 항상 상태 초기화 보장
    if (mounted) {
      // _cameraEngine.isInitializing이 false인지 확인
      if (_cameraEngine.isInitializing) {
        // 타임아웃 처리
        Future.delayed(const Duration(seconds: 5), () {
          if (mounted && _cameraEngine.isInitializing) {
            debugPrint('[Petgram] ⚠️ Camera initialization timeout');
            // 강제로 상태 초기화
          }
        });
      }
    }
  }
}
```

#### c) 화면 복귀 시 재초기화 로직 개선

```dart
// lib/pages/home_page.dart
@override
void initState() {
  super.initState();
  // ...
  
  // 화면 복귀 시 이전 세션 완전히 정리
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (mounted) {
      _ensureCameraCleanup().then((_) {
        _initCameraPipeline();
      });
    }
  });
}

Future<void> _ensureCameraCleanup() async {
  // 이전 세션이 있으면 완전히 정리
  if (_cameraEngine.isInitialized || _cameraEngine.isInitializing) {
    await _cameraEngine.dispose();
    // 상태 초기화 대기
    await Future.delayed(const Duration(milliseconds: 100));
  }
}
```

