# SIGKILL 원인 분석 및 수정 완료

## 문제 요약
- 권한 거부 → 설정으로 이동 → 설정 화면에서 권한 토글 순간 앱이 SIGKILL로 종료됨
- 로그에서 `applyLifecycleTransition`이 "permission denied → SKIPPED"로 반복되어 `cleanupForLifecycle`이 실행되지 않음
- 백그라운드 전환 시 카메라 세션이 정리되지 않아 iOS가 강제 종료(SIGKILL)

## 원인 분석

### 1차 원인: `applyLifecycleTransition`에서 permission denied 시 즉시 return
**위치**: `ios/Runner/NativeCamera.swift:6516-6528`
- `applyLifecycleTransition` 시작 시점에 permission denied 체크
- denied 시 `cleanupForLifecycle` 호출 없이 즉시 return
- 결과: 백그라운드 전환 시 세션이 정리되지 않음 → SIGKILL

**로그 증거**:
```
[Native] ⏸️ applyLifecycleTransition: SKIPPED - camera permission denied/restricted (authStatus=2, reason=didEnterBackground)
```

### 2차 원인: `cleanupForLifecycle`에서 "app is active"로 SKIP
**위치**: `ios/Runner/NativeCamera.swift:6270-6280` (수정 전)
- `appState == .active && !shouldTearDownOutputs`일 때 SKIP
- `willResignActive`/`didEnterBackground` 호출 시점에 `appState`가 아직 `.active`일 수 있음
- 결과: background 전환이 확실한데도 cleanup이 SKIP됨

**로그 증거**:
```
[Native] ⏸️ cleanupForLifecycle: SKIPPED - app is active, keeping session running (reason=willResignActive)
```

### 3차 원인: Flutter 쪽 re-entrancy 문제 (부수적)
**위치**: `lib/widgets/permission_wrapper.dart:242-247`
- 이미 re-entrancy guard가 있지만, lifecycle 변경 중 permission 체크가 중복 호출될 수 있음
- 권한 요청 중 타임아웃이 발생할 수 있음 (이미 타임아웃 추가됨)

## 수정 사항

### 수정 1: `applyLifecycleTransition`에서 permission denied일 때도 cleanup 호출
**파일**: `ios/Runner/NativeCamera.swift:6513-6529`

**변경 내용**:
- permission denied일 때 background 전환(`willResignActive`/`didEnterBackground`)이면 `cleanupForLifecycle` 호출
- `shouldTearDownOutputs`를 `true`로 강제 설정하여 완전한 teardown 보장

**코드**:
```swift
// willResignActive/didEnterBackground의 경우 permission denied여도 반드시 teardown 실행
let shouldForceTeardown = (reason.contains("willResignActive") || reason.contains("didEnterBackground") || reason.contains("background"))
let shouldTearDownOutputs = (action == "teardown") || (isPermissionDenied && shouldForceTeardown)

if isPermissionDenied && shouldForceTeardown {
    // permission denied + background 전환: safe teardown을 위해 cleanupForLifecycle 호출
    // cleanupForLifecycle에 이미 "safe teardown" 로직이 구현되어 있음
}
```

### 수정 2: `cleanupForLifecycle`에서 background 전환 시 appState 무시
**파일**: `ios/Runner/NativeCamera.swift:6266-6290`

**변경 내용**:
- `isBackgroundTransition` 체크 추가
- background 전환 시 `appState`와 관계없이 반드시 teardown 수행

**코드**:
```swift
let isBackgroundTransition = (reason.contains("willResignActive") || reason.contains("didEnterBackground") || reason.contains("background"))

if appState == .active && !shouldTearDownOutputs && !isBackgroundTransition {
    // Control Center나 알림을 띄울 때만 세션 유지
    return
}

if isBackgroundTransition {
    // background 전환 시 appState와 관계없이 반드시 세션 정리 (SIGKILL 방지)
}
```

### 수정 3: Flutter 쪽 re-entrancy guard 확인 (이미 구현됨)
**파일**: `lib/widgets/permission_wrapper.dart:242-247`

**현재 상태**:
- `_checkPermissions`에 re-entrancy guard 이미 구현됨
- 타임아웃 추가됨 (5-10초)
- lifecycle 변경 시 체크 스킵 로직 있음

## 예상 동작 (수정 후)

### 시나리오: 권한 거부 → 설정으로 이동 → 권한 토글

1. **권한 거부 상태** (`permission denied`)
2. **"설정으로 이동" 버튼 클릭**
   - `setSkipAutoReinit(true)` 호출
   - `openSettings()` 호출
   - `_returnedFromSettings = true` 설정
3. **앱이 background로 전환**
   - `onAppWillResignActive()` 호출
   - `applyLifecycleTransition(reason: "willResignActive", action: "stop")` 호출
   - **수정 후**: permission denied여도 `cleanupForLifecycle` 호출
   - `cleanupForLifecycle`: background 전환이므로 `appState` 무시하고 세션 중지
   - **safe teardown 경로**: 세션 중지 + outputs 제거
4. **설정 화면에서 권한 토글**
   - iOS가 백그라운드 앱의 카메라 세션을 확인
   - **수정 후**: 세션이 이미 정리되어 있음 → SIGKILL 없음 ✅
5. **앱 복귀**
   - `onAppDidBecomeActive()` 호출
   - `shouldSkipAutoReinit = true` 확인 → auto-reinit 스킵
   - Flutter에서 권한 재검사 → HomePage 또는 다이얼로그 표시

## 테스트 체크리스트

### 필수 테스트
- [ ] 권한 거부 → 설정으로 이동 → 설정에서 권한 토글 → 앱이 SIGKILL 없이 정상 동작
- [ ] 권한 거부 → 설정으로 이동 → 권한 허용 → 앱 복귀 시 HomePage 표시
- [ ] 권한 거부 → 설정으로 이동 → 권한 변경 없음 → 앱 복귀 시 다이얼로그 재표시
- [ ] Control Center나 알림을 띄울 때 카메라 세션이 유지되는지 확인 (일반 사용 시나리오)

### 로그 확인 사항
- [ ] `applyLifecycleTransition`에서 permission denied + background 전환 시 "FORCING teardown" 로그 확인
- [ ] `cleanupForLifecycle`에서 "SAFE TEARDOWN" 또는 "FORCING teardown" 로그 확인
- [ ] 세션 중지 로그 확인: `[Native] ✅ SAFE TEARDOWN: Session stopped`
- [ ] outputs 제거 로그 확인: `[Native] ✅ SAFE TEARDOWN: Outputs removed`
- [ ] SIGKILL 없이 정상 종료 확인

## 추가 고려사항

### 중복 observer 등록
- `onAppWillResignActive`/`onAppDidEnterBackground`에서 re-entrancy guard 확인됨
- `isProcessingWillResignActive`/`isProcessingDidEnterBackground` 플래그 사용

### Flutter 쪽 타임아웃
- 네이티브 메서드 호출에 5-10초 타임아웃 추가됨
- 타임아웃 발생 시 `_isChecking = false`로 리셋하여 인디케이터 멈춤 방지

## 참고 로그 (수정 전)
```
[Native] ⏸️ applyLifecycleTransition: SKIPPED - camera permission denied/restricted (authStatus=2, reason=didEnterBackground)
→ cleanupForLifecycle이 호출되지 않음
→ 세션이 정리되지 않음
→ iOS가 SIGKILL
```

## 예상 로그 (수정 후)
```
[Native] 🔥 applyLifecycleTransition: Permission denied but FORCING teardown for background transition (authStatus=2, reason=didEnterBackground, shouldTearDownOutputs=true)
[Native] 🔥 cleanupForLifecycle: Permission denied - performing SAFE TEARDOWN (authStatus=2, reason=didEnterBackground, shouldTearDown=true)
[Native] ✅ SAFE TEARDOWN: Session stopped (reason=didEnterBackground)
[Native] ✅ SAFE TEARDOWN: Outputs removed (reason=didEnterBackground)
→ 세션이 정리됨
→ iOS가 SIGKILL하지 않음 ✅
```
