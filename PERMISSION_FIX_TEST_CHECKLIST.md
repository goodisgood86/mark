# 권한 설정 문제 수정 완료 - 테스트 체크리스트

## 수정 사항 요약

### 1. ✅ permission_wrapper.dart: 권한 재검사 추가
**문제**: `returnedFromSettings=true`일 때 권한 재검사 없이 return → `_permissionsGranted=false` 유지 → 빈 화면

**해결**:
- `resumed` 상태에서 `_returnedFromSettings=true`일 때 `_checkPermissions()` 호출 추가
- `_isChecking = true` 설정 후 500ms 지연 후 권한 재검사 수행
- 권한 재검사 후 권한 상태에 따라 HomePage 또는 다이얼로그 표시

**코드 변경**:
```dart
// 설정에서 복귀 시 권한 재검사 수행
if (mounted) {
  setState(() {
    _isChecking = true;
    _hasCheckedPermissions = false; // 재검사 필요 플래그
  });
  
  // 약간의 지연 후 권한 체크 (시스템이 안정화될 시간 확보)
  Future.delayed(const Duration(milliseconds: 500), () {
    if (mounted) {
      _checkPermissions();
    }
  });
}
```

### 2. ✅ NativeCamera.swift: setSkipAutoReinit viewId 없이 동작
**문제**: `setSkipAutoReinit` 호출 시 `NO_VIEW_ID` 에러 발생

**해결**:
- `setSkipAutoReinit`을 권한 체크 메서드처럼 viewId 없이도 동작하도록 수정
- `isPermissionCheckMethod`에 `setSkipAutoReinit` 추가
- `NativeCameraRegistry`와 `CameraManager`를 통해 모든 카메라 인스턴스에 플래그 설정

**코드 변경**:
```swift
// 권한 체크 메서드 목록에 추가
let isPermissionCheckMethod = (call.method == "checkCameraPermission" || 
                               call.method == "checkPhotoLibraryPermission" || 
                               call.method == "requestCameraPermission" || 
                               call.method == "requestPhotoLibraryPermission" || 
                               call.method == "setSkipAutoReinit")

// 모든 인스턴스에 플래그 설정
let allCameras = NativeCameraRegistry.shared.allCameras()
for vc in allCameras {
    vc.shouldSkipAutoReinit = skip
}
```

### 3. ✅ 로깅 경로 문제 해결
**문제**: iOS에서 `/Users` 경로에 쓰기 시도 → `PathAccessException` 반복

**해결**:
- iOS에서는 파일 로깅 비활성화
- `debugPrint`만 사용하여 로그 출력
- Android/Desktop에서는 기존 로직 유지 (디버그 빌드에서만)

**코드 변경**:
```dart
// iOS에서는 파일 로깅 비활성화 (sandbox 경로 문제 방지)
if (Platform.isIOS) {
  debugPrint('[DEBUG LOG] $message: ${jsonEncode(data)}');
  return;
}
```

## 테스트 체크리스트

### 기본 시나리오 1: 권한 거부 → 설정으로 이동 → 권한 허용
- [ ] 앱 실행
- [ ] 권한 거부
- [ ] "필수 권한 필요" 다이얼로그 표시 확인
- [ ] "설정으로 이동" 버튼 클릭
- [ ] 설정 앱으로 이동 확인
- [ ] 설정에서 카메라 권한 허용
- [ ] 설정에서 갤러리 권한 허용
- [ ] 앱으로 복귀
- [ ] 앱이 정상적으로 복귀 (SIGKILL 없음)
- [ ] 로그 확인: `[DEBUG LOG] RESUMED - returnedFromSettings=true`
- [ ] 로그 확인: `setSkipAutoReinit(false)` 호출 확인
- [ ] 로그 확인: `_checkPermissions` 호출 확인
- [ ] 권한 재검사 완료 확인
- [ ] 다이얼로그 사라짐 확인
- [ ] HomePage 정상 렌더링 확인 (빈 화면 아님)

### 기본 시나리오 2: 권한 거부 → 설정으로 이동 → 권한 거부 유지
- [ ] 앱 실행
- [ ] 권한 거부
- [ ] "설정으로 이동" 버튼 클릭
- [ ] 설정 앱으로 이동 확인
- [ ] 설정에서 권한 변경 없음
- [ ] 앱으로 복귀
- [ ] 앱이 정상적으로 복귀 (SIGKILL 없음)
- [ ] 다이얼로그 유지 확인
- [ ] 버튼이 정상 동작 확인

### 기본 시나리오 3: 권한 허용 상태에서 앱 재실행
- [ ] 모든 권한이 이미 허용된 상태
- [ ] 앱 실행
- [ ] 권한 체크 스킵 확인 (이미 허용됨)
- [ ] HomePage 즉시 렌더링 확인

### 네이티브 카메라 동작 확인
- [ ] 로그 확인: `setSkipAutoReinit(true)` 호출 확인 (설정으로 이동 전)
- [ ] 로그 확인: `shouldSkipAutoReinit=true` 플래그 설정 확인
- [ ] 로그 확인: `onAppDidBecomeActive`에서 `SKIPPED auto-reinit` 메시지 확인
- [ ] 로그 확인: `onAppDidBecomeActive`에서 권한 체크 메시지 확인
- [ ] 로그 확인: `applyLifecycleTransition`에서 권한 체크 메시지 확인
- [ ] 네이티브 카메라가 자동 재초기화를 시도하지 않음 확인

### 에러 처리 확인
- [ ] `setSkipAutoReinit` 호출 실패해도 앱이 크래시하지 않음
- [ ] 권한 체크 실패해도 앱이 크래시하지 않음
- [ ] 로그 파일 쓰기 실패해도 앱이 크래시하지 않음 (iOS)
- [ ] `PathAccessException` 에러가 더 이상 발생하지 않음

### 성능 확인
- [ ] 설정에서 복귀 후 500ms 내 권한 재검사 시작
- [ ] 권한 재검사 완료 후 즉시 UI 업데이트
- [ ] 다이얼로그 닫기/열기가 부드럽게 동작

## 예상 로그 흐름 (정상 케이스)

```
1. [DEBUG LOG] Dialog button pressed - opening settings
2. [DEBUG LOG] setSkipAutoReinit(true) called before opening settings
3. [Native] 🔥 setSkipAutoReinit: true
4. [Native] 🔥 onAppWillResignActive: Setting shouldSkipAutoReinit=true
5. [Native] ⏸️ cleanupForLifecycle: SKIPPED - camera permission denied/restricted
6. [DEBUG LOG] didChangeAppLifecycleState ENTRY: {"state":"AppLifecycleState.hidden","returnedFromSettings":true}
7. [DEBUG LOG] didChangeAppLifecycleState ENTRY: {"state":"AppLifecycleState.paused","returnedFromSettings":true}
8. [DEBUG LOG] didChangeAppLifecycleState ENTRY: {"state":"AppLifecycleState.resumed","returnedFromSettings":true}
9. [DEBUG LOG] RESUMED - returnedFromSettings=true, closing dialog if exists
10. [Native] ✅ DidBecomeActive: Restoring preview and ensuring configuration
11. [Native] ⏸️ onAppDidBecomeActive: SKIPPED auto-reinit - shouldSkipAutoReinit=true
12. [DEBUG LOG] setSkipAutoReinit(false) called after returning from settings
13. [DEBUG LOG] _checkPermissions ENTRY
14. [DEBUG LOG] Permission check result: camera=true, gallery=true, granted=true
15. [DEBUG LOG] All permissions granted - flags cleared
16. HomePage 렌더링
```

## 예상 로그 흐름 (에러 케이스)

### setSkipAutoReinit 호출 실패
```
1. [DEBUG LOG] setSkipAutoReinit(true) called before opening settings
2. [DEBUG LOG] setSkipAutoReinit failed: [error]
3. (앱은 계속 정상 동작 - 네이티브에서 자동 감지)
4. [Native] 🔥 onAppWillResignActive: Setting shouldSkipAutoReinit=true
```

### 권한 재검사 실패
```
1. [DEBUG LOG] RESUMED - returnedFromSettings=true
2. [DEBUG LOG] _checkPermissions ENTRY
3. [DEBUG LOG] Error checking permissions: [error]
4. (권한 거부로 처리, 다이얼로그 표시)
```

## 추가 확인 사항

### 로그 분석 포인트
- [ ] `returnedFromSettings` 플래그가 올바르게 설정/리셋됨
- [ ] `_isChecking` 플래그가 올바르게 설정/리셋됨
- [ ] `_permissionsGranted` 플래그가 권한 상태와 일치함
- [ ] `_dialogShown` 플래그가 다이얼로그 상태와 일치함
- [ ] `shouldSkipAutoReinit` 플래그가 올바르게 설정/리셋됨
- [ ] 네이티브 카메라가 불필요한 재초기화를 시도하지 않음

### 메모리/성능 확인
- [ ] 설정으로 이동/복귀 반복 시 메모리 누수 없음
- [ ] 다이얼로그가 중복 생성되지 않음
- [ ] 권한 체크가 중복 실행되지 않음
- [ ] 네이티브 카메라 인스턴스가 누수되지 않음

## 롤백 계획

만약 문제가 발생하면:
1. `permission_wrapper.dart`: `_returnedFromSettings=true` 처리에서 권한 재검사 제거
2. `NativeCamera.swift`: `setSkipAutoReinit`을 viewId 필수로 되돌림
3. 로깅: 기존 절대 경로 방식으로 되돌림 (개발 환경에서만)

## 완료 조건

✅ 모든 기본 시나리오 통과
✅ 에러 처리 확인 완료
✅ 로그 분석 포인트 확인 완료
✅ 성능 확인 완료
✅ SIGKILL 발생하지 않음
✅ 빈 화면 문제 해결 확인
