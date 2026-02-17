# AF 아이콘 및 로딩 문제 수정 완료

## 문제 5: AF 아이콘이 실제 초점 상태와 동기화되지 않는 문제 ✅

### 수정 내용

#### 1. 네이티브에서 AF 상태 세분화
**파일**: `ios/Runner/NativeCamera.swift`

**변경 사항:**
- `getFocusStatus()` 메서드에 `focusStatus` 필드 추가
- 세 가지 상태로 구분:
  - `adjusting`: 조정 중
  - `ready`: 준비됨/초점 잡힘
  - `locked`: 고정됨
  - `unknown`: 알 수 없음

**코드:**
```swift
// 초점 상태 판단
var focusStatus: String = "unknown"
if isAdjusting {
    focusStatus = "adjusting" // 조정 중
} else if focusMode == .continuousAutoFocus {
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

#### 2. Flutter에서 세 가지 상태로 UI 업데이트
**파일**: `lib/pages/home_page.dart`

**변경 사항:**
- `_FocusStatus` enum 추가 (adjusting, ready, locked, unknown)
- `_pollFocusStatus()` 메서드에서 `focusStatus` 파싱 및 상태 업데이트
- `_buildAutoFocusStatusIndicator()` 메서드에서 상태별 색상 적용:
  - `adjusting`: 주황색 (조정 중)
  - `ready`: 초록색 (준비됨/초점 잡힘)
  - `locked`/`unknown`: 회색 (고정됨/알 수 없음)

**코드:**
```dart
enum _FocusStatus {
  adjusting,  // 조정 중 (주황색)
  ready,      // 준비됨/초점 잡힘 (초록색)
  locked,     // 고정됨 (회색)
  unknown,    // 알 수 없음 (회색)
}

Future<void> _pollFocusStatus() async {
  // ...
  final focusStatusStr = status['focusStatus'] as String? ?? 'unknown';
  
  _FocusStatus newStatus;
  switch (focusStatusStr) {
    case 'adjusting':
      newStatus = _FocusStatus.adjusting;
      break;
    case 'ready':
      newStatus = _FocusStatus.ready;
      break;
    case 'locked':
      newStatus = _FocusStatus.locked;
      break;
    default:
      newStatus = _FocusStatus.unknown;
  }
  
  if (_focusStatus != newStatus) {
    setState(() {
      _focusStatus = newStatus;
    });
  }
}
```

#### 3. MethodChannel 연결
**파일**: `lib/camera/native_camera_controller.dart`

**변경 사항:**
- `getFocusStatus()` 메서드에서 `focusStatus` 필드 반환 추가

## 문제 6: 카메라 화면 복귀 시 작은 로딩 아이콘 무한 로딩 ✅

### 수정 내용

#### 1. CameraEngine.dispose() 개선
**파일**: `lib/services/camera_engine.dart`

**변경 사항:**
- `dispose()` 메서드에서 네이티브 카메라 완전히 정리
- 상태를 `CameraState.idle`로 초기화

**코드:**
```dart
Future<void> dispose() async {
  // 네이티브 카메라 완전히 정리
  if (_nativeCamera != null) {
    await _nativeCamera!.dispose();
    _nativeCamera = null;
  }
  
  _isInitializing = false;
  _useMockCamera = false;
  _initErrorMessage = null;
  _setState(CameraState.idle); // 상태 초기화
  _listeners.clear();
  _notifyListeners();
}
```

#### 2. 화면 복귀 시 재초기화 로직 개선
**파일**: `lib/pages/home_page.dart`

**변경 사항:**
- `_ensureCameraCleanup()` 메서드 추가: 이전 세션 완전히 정리
- `initState()`에서 `addPostFrameCallback`을 사용하여 정리 후 초기화

**코드:**
```dart
@override
void initState() {
  super.initState();
  // ...
  
  // 🔥 로딩 문제 해결: 화면 복귀 시 이전 세션 완전히 정리 후 초기화
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (mounted) {
      _ensureCameraCleanup().then((_) {
        if (mounted) {
          _initCameraPipeline();
        }
      });
    }
  });
}

/// 🔥 로딩 문제 해결: 화면 복귀 시 이전 카메라 세션 완전히 정리
Future<void> _ensureCameraCleanup() async {
  // 이전 세션이 있으면 완전히 정리
  if (_cameraEngine.isInitialized || _cameraEngine.isInitializing) {
    if (kDebugMode) {
      debugPrint('[Petgram] 🧹 Cleaning up previous camera session...');
    }
    await _cameraEngine.dispose();
    // 상태 초기화 대기
    await Future.delayed(const Duration(milliseconds: 100));
  }
}
```

#### 3. dispose()에서 완전한 정리
**파일**: `lib/pages/home_page.dart`

**변경 사항:**
- `dispose()` 메서드에서 카메라 엔진 완전히 해제

## 테스트 체크리스트

### AF 아이콘 문제
- [ ] 카메라를 다른 장소/피사체로 이동 시 AF 아이콘 색상이 변경되는지 확인
- [ ] 초점 조정 중: 주황색 표시
- [ ] 초점 잡힘: 초록색 표시
- [ ] 초점 고정: 회색 표시

### 로딩 문제
- [ ] 필터 페이지로 이동 후 카메라 화면으로 복귀 시 로딩 아이콘이 사라지는지 확인
- [ ] 카메라 프리뷰가 정상적으로 표시되는지 확인
- [ ] 초기화 실패 시에도 로딩 아이콘이 사라지는지 확인

## 예상 개선 효과

### AF 아이콘 문제
- **이전**: 초록색으로 고정되어 실제 초점 상태를 알 수 없음
- **이후**: 실제 초점 상태에 따라 색상 변경 (주황색/초록색/회색)
- **개선**: **사용자가 실제 초점 상태를 정확히 파악 가능**

### 로딩 문제
- **이전**: 화면 복귀 시 무한 로딩 상태
- **이후**: 이전 세션 완전히 정리 후 재초기화
- **개선**: **화면 복귀 시 정상적으로 카메라 프리뷰 표시**

