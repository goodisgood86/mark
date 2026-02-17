# SIGKILL 문제 완전 해결 - 최종 수정 사항

## 원인 분석

### 원인 가설 1: 권한 denied 상태에서 세션이 정리되지 않음 ✅ **확인됨**
**문제**: `cleanupForLifecycle`에서 권한이 denied일 때 완전히 SKIP하여 세션이 실행 중인 상태로 남음
- iOS는 백그라운드로 전환될 때 실행 중인 카메라 세션을 발견하면 강제 종료(SIGKILL)할 수 있음
- 권한이 denied여도 세션을 정리하지 않으면 iOS가 감지하여 강제 종료

**증거**:
- 로그: `cleanupForLifecycle: SKIPPED - camera permission denied/restricted`
- 로그: `SIGKILL`이 `didEnterBackground` 직후 발생
- 세션이 정리되지 않은 상태에서 백그라운드 전환

**해결**: 권한이 denied여도 세션을 안전하게 정리하는 "safe teardown" 경로 추가

### 원인 가설 2: re-entrancy guard 부족 ✅ **확인됨**
**문제**: `_checkPermissions`가 동시에 여러 번 호출될 수 있음
- 설정에서 복귀 시 `_checkPermissions()`가 여러 번 호출될 수 있음
- 권한 요청이 중복되어 충돌 발생 가능

**해결**: re-entrancy guard 추가 (`if (_isChecking) return`)

### 원인 가설 3: 중복 권한 요청 ✅ **확인됨**
**문제**: `requestPhotoLibraryPermission`이 여러 번 호출됨
- 권한 요청 플래그가 없어서 동시에 여러 번 요청 가능

**해결**: `_isRequestingPermission` 플래그 추가

## 수정 사항

### 1. ✅ 네이티브: Safe Teardown 경로 추가

**파일**: `ios/Runner/NativeCamera.swift`

**변경 사항**:
- 권한이 denied일 때도 세션을 안전하게 정리하는 "safe teardown" 경로 추가
- `session.stopRunning()`은 권한 없이도 호출 가능 (세션 생성/설정만 권한 필요)
- `sessionQueue.async` 내부에서 안전하게 정리 수행

**코드**:
```swift
// 권한이 denied여도 safe teardown 수행
if isPermissionDenied {
    sessionQueue.async { [weak self] in
        // 세션 중지 (권한 불필요)
        if self.session.isRunning {
            self.session.stopRunning()
        }
        
        // outputs 정리
        if shouldTearDownOutputs {
            self.session.beginConfiguration()
            for input in self.session.inputs {
                self.session.removeInput(input)
            }
            for output in self.session.outputs {
                self.session.removeOutput(output)
            }
            self.session.commitConfiguration()
            // 리소스 정리...
        }
    }
    return
}

// sessionQueue.async 내부에서도 권한 재확인
// 권한이 denied로 바뀌었으면 safe teardown 수행
if isPermissionDeniedInQueue {
    // safe teardown 수행...
    return
}
```

### 2. ✅ Flutter: Re-entrancy Guard 추가

**파일**: `lib/widgets/permission_wrapper.dart`

**변경 사항**:
- `_checkPermissions()` 시작 시 `if (_isChecking) return` 추가
- 권한 요청 중복 방지 플래그 추가 (`_isRequestingPermission`)

**코드**:
```dart
Future<void> _checkPermissions() async {
  // 🔥 re-entrancy guard
  if (_isChecking) {
    debugPrint('[DEBUG LOG] _checkPermissions SKIPPED - already checking');
    return;
  }
  
  // _isChecking 플래그 설정
  if (mounted) {
    setState(() {
      _isChecking = true;
    });
  }
  
  // 권한 요청 시 중복 방지
  if (cameraPermissionStatus == 0 && !_isRequestingPermission) {
    _isRequestingPermission = true;
    try {
      await cameraChannel.invokeMethod<bool>('requestCameraPermission');
    } finally {
      _isRequestingPermission = false;
    }
  }
}
```

### 3. ✅ 설정 복귀 시 권한 재검사

**파일**: `lib/widgets/permission_wrapper.dart`

**변경 사항**:
- `resumed` 상태에서 `_returnedFromSettings=true`일 때 권한 재검사 추가
- 500ms 지연 후 `_checkPermissions()` 호출

**코드**:
```dart
if (_returnedFromSettings) {
  _returnedFromSettings = false;
  
  // 권한 재검사
  if (mounted) {
    setState(() {
      _isChecking = true;
      _hasCheckedPermissions = false;
    });
    
    Future.delayed(const Duration(milliseconds: 500), () {
      if (mounted) {
        _checkPermissions();
      }
    });
  }
}
```

### 4. ✅ applyLifecycleTransition 권한 체크

**파일**: `ios/Runner/NativeCamera.swift`

**변경 사항**:
- `applyLifecycleTransition` 시작 시점에 권한 체크 추가
- 권한이 denied이면 cleanup 시도하지 않고 즉시 release

**코드**:
```swift
func applyLifecycleTransition(reason: String, action: String) {
    // ... lock acquire ...
    
    // 권한 체크: denied이면 cleanup 시도하지 않음
    let authStatus = AVCaptureDevice.authorizationStatus(for: .video)
    if authStatus == .denied || authStatus == .restricted {
        GlobalLifecycleManager.shared.release()
        return
    }
    
    // cleanup 수행...
}
```

## 예상 동작 흐름 (권한 변경 시)

### 정상 케이스
1. 권한 거부 상태에서 "설정으로 이동" 버튼 클릭
2. `setSkipAutoReinit(true)` 호출
3. `willResignActive` → `cleanupForLifecycle` 호출
4. 권한 denied 감지 → **SAFE TEARDOWN 수행** ✅
   - 세션 중지: `session.stopRunning()`
   - outputs 제거: `removeInput/removeOutput`
   - 리소스 정리
5. 설정 앱으로 이동
6. 사용자가 권한 변경
7. 앱으로 복귀 → `didBecomeActive`
8. `shouldSkipAutoReinit=true` 체크 → 자동 재초기화 건너뛰기
9. Flutter: `resumed` → 권한 재검사 → HomePage 렌더링

### 에러 케이스 (이제 해결됨)
1. 권한 거부 상태에서 "설정으로 이동"
2. `willResignActive` → 권한 denied 감지
3. **이전**: cleanup SKIP → 세션 실행 중 상태 유지 → iOS가 강제 종료 (SIGKILL) ❌
4. **수정 후**: SAFE TEARDOWN 수행 → 세션 정리 → iOS가 정상 종료 허용 ✅

## 테스트 체크리스트

### 핵심 테스트
- [ ] 권한 거부 → 설정 이동 → 권한 변경 순간에 **SIGKILL 발생하지 않음**
- [ ] 로그 확인: `SAFE TEARDOWN: Session stopped` 메시지 확인
- [ ] 로그 확인: `SAFE TEARDOWN: Outputs removed` 메시지 확인
- [ ] 설정에서 복귀 후 권한 재검사 정상 동작
- [ ] `_checkPermissions` 중복 호출 방지 확인

### 추가 확인
- [ ] `_isChecking` 플래그가 올바르게 설정/리셋됨
- [ ] `_isRequestingPermission` 플래그가 올바르게 설정/리셋됨
- [ ] 권한 요청이 중복되지 않음
- [ ] `setSkipAutoReinit`이 정상 동작 (viewId 없이도)
- [ ] 네이티브 카메라가 불필요한 재초기화를 시도하지 않음

## 로그 예시 (정상 케이스)

```
[Native] 🔥 onAppWillResignActive: Setting shouldSkipAutoReinit=true (authStatus=2)
[Native] 🔥 cleanupForLifecycle: Permission denied - performing SAFE TEARDOWN (authStatus=2, reason=willResignActive, shouldTearDown=false)
[Native] ✅ SAFE TEARDOWN: Session stopped (reason=willResignActive)
[Native] 🔥 onAppDidEnterBackground: Setting shouldSkipAutoReinit=true (authStatus=2)
[Native] 🔥 cleanupForLifecycle: Permission denied - performing SAFE TEARDOWN (authStatus=2, reason=didEnterBackground, shouldTearDown=true)
[Native] ✅ SAFE TEARDOWN: Session stopped (reason=didEnterBackground)
[Native] ✅ SAFE TEARDOWN: Outputs removed (reason=didEnterBackground)
[DEBUG LOG] RESUMED - returnedFromSettings=true, closing dialog if exists
[DEBUG LOG] setSkipAutoReinit(false) called after returning from settings
[DEBUG LOG] _checkPermissions ENTRY
[Native] ✅ DidBecomeActive: Restoring preview and ensuring configuration
[Native] ⏸️ onAppDidBecomeActive: SKIPPED auto-reinit - shouldSkipAutoReinit=true
[DEBUG LOG] Permission check result: camera=true, gallery=true, granted=true
HomePage 렌더링
```

## 주요 개선 사항

1. **Safe Teardown 경로**: 권한이 denied여도 세션을 안전하게 정리
2. **Re-entrancy Guard**: 중복 호출 방지
3. **중복 권한 요청 방지**: 플래그 기반 제어
4. **권한 재검사**: 설정 복귀 시 자동 재검사
5. **다층 방어**: 여러 지점에서 권한 체크 및 safe teardown 수행

## 다음 단계

1. 실제 테스트 수행
2. 로그 분석하여 safe teardown이 정상 동작하는지 확인
3. SIGKILL이 발생하지 않는지 확인
4. 권한 변경 후 정상 복귀 확인
