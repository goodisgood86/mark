# 중복 호출 및 권한 체크 문제 수정 완료

## 문제 요약
- SAFE TEARDOWN까지 수행했는데도 Settings 진입 직후 SIGKILL 지속
- `applyLifecycleTransition`가 동일 reason으로 수차례 중복 호출
- `onAppWillResignActive` / `onAppDidEnterBackground`가 연속 다중 호출
- `initializeIfNeeded`가 권한 notDetermined 상태에서도 반복 호출됨

## 원인 분석

### 1. 라이프사이클 옵저버 중복 등록 (확인 결과: 없음)
- ✅ `init`에서 `addObserver` 호출 확인 (코드 생성 경로와 스토리보드 경로 각각)
- ✅ `deinit`에서 `removeObserver(self)` 호출 확인
- ✅ `CameraManager`에서 중복 인스턴스 생성 방지 로직 확인 (이미 존재하면 setup 스킵)

### 2. 권한 notDetermined/denied 상태에서 initializeIfNeeded 반복 호출 (수정 완료)
**위치**: `ios/Runner/NativeCamera.swift:982`
- ❌ **문제**: `initializeIfNeeded` 시작 부분에 권한 체크가 없음
- ✅ **수정**: 권한 체크를 가장 먼저 수행하여 notDetermined/denied 상태에서 즉시 return

### 3. 중복 라이프사이클 호출 (수정 완료)
**위치**: `ios/Runner/NativeCamera.swift:6828-6898`
- ❌ **문제**: `onAppWillResignActive`/`onAppDidEnterBackground`에서 debounce 없음
- ✅ **수정**: 0.5초 debounce 추가 (최근 호출 시간 기반)

### 4. applyLifecycleTransition 중복 호출 (수정 완료)
**위치**: `ios/Runner/NativeCamera.swift:6513`
- ❌ **문제**: 동일 reason으로 연속 호출 시 중복 실행
- ✅ **수정**: reason+timestamp 기반 debounce 추가 (0.5초)

### 5. ensureHealthyOrReinit/ensureConfigured에서 권한 체크 없음 (수정 완료)
**위치**: `ios/Runner/NativeCamera.swift:6633, 6726`
- ❌ **문제**: 권한 미허용 상태에서도 health check/reinit 시도
- ✅ **수정**: 권한 체크를 가장 먼저 수행하여 미허용 시 즉시 return

## 수정 사항

### 수정 1: `initializeIfNeeded` 시작 부분에 권한 체크 추가
```swift
func initializeIfNeeded(position: AVCaptureDevice.Position, aspectRatio: Double?) {
    // 🔥🔥🔥 핵심 수정: 권한 체크를 가장 먼저 수행 (notDetermined/denied 상태에서 초기화 금지)
    let authStatus = AVCaptureDevice.authorizationStatus(for: .video)
    if authStatus != .authorized && authStatus != .limited {
        let skipMsg = "[Native] ⏸️ initializeIfNeeded() SKIPPED: camera permission not authorized (authStatus=\(authStatus.rawValue)..."
        // ... 로그 및 return
        return
    }
    // ... 나머지 로직
}
```

### 수정 2: `onAppWillResignActive`/`onAppDidEnterBackground`에 debounce 추가
```swift
// 🔥🔥🔥 debounce를 위한 마지막 호출 시간 저장
private var lastWillResignActiveTime: Date?
private var lastDidEnterBackgroundTime: Date?
private let debounceInterval: TimeInterval = 0.5  // 0.5초 이내 중복 호출 무시

@objc private func onAppWillResignActive() {
    // 플래그 체크
    guard !isProcessingWillResignActive else { return }
    
    // debounce: 최근 0.5초 이내 호출이면 무시
    let now = Date()
    if let lastTime = lastWillResignActiveTime {
        let elapsed = now.timeIntervalSince(lastTime)
        if elapsed < debounceInterval {
            return  // 중복 호출 무시
        }
    }
    lastWillResignActiveTime = now
    
    // ... 나머지 로직
}
```

### 수정 3: `applyLifecycleTransition`에 reason+timestamp 기반 debounce 추가
```swift
// 🔥🔥🔥 applyLifecycleTransition 중복 호출 방지: reason+timestamp 기반
private var lastLifecycleTransitionReason: String?
private var lastLifecycleTransitionTime: Date?

func applyLifecycleTransition(reason: String, action: String) {
    // 🔥🔥🔥 중복 호출 방지: 동일 reason+timestamp 기반 debounce
    let now = Date()
    if let lastReason = lastLifecycleTransitionReason,
       let lastTime = lastLifecycleTransitionTime,
       lastReason == reason {
        let elapsed = now.timeIntervalSince(lastTime)
        if elapsed < debounceInterval {
            return  // 중복 호출 무시
        }
    }
    lastLifecycleTransitionReason = reason
    lastLifecycleTransitionTime = now
    
    // ... 나머지 로직
}
```

### 수정 4: `ensureHealthyOrReinit`/`ensureConfigured`에 권한 체크 추가
```swift
func ensureHealthyOrReinit(reason: String) {
    // 🔥🔥🔥 핵심 수정: 권한 체크를 가장 먼저 수행 (notDetermined/denied 상태에서 초기화 금지)
    let authStatus = AVCaptureDevice.authorizationStatus(for: .video)
    if authStatus != .authorized && authStatus != .limited {
        let skipMsg = "[Native] ⏸️ ensureHealthyOrReinit: SKIPPED - camera permission not authorized..."
        // ... 로그 및 return
        return
    }
    // ... 나머지 로직
}

private func ensureConfigured() {
    // 🔥🔥🔥 핵심 수정: 권한 체크를 가장 먼저 수행 (notDetermined/denied 상태에서 초기화 금지)
    let authStatus = AVCaptureDevice.authorizationStatus(for: .video)
    if authStatus != .authorized && authStatus != .limited {
        let skipMsg = "[Native] ⏸️ ensureConfigured: SKIPPED - camera permission not authorized..."
        // ... 로그 및 return
        return
    }
    // ... 나머지 로직
}
```

## Flutter 쪽 권한 체크 상태

### 현재 상태: 이미 차단됨
- ✅ `PermissionWrapper`에서 `permissionsGranted=true`일 때만 `HomePage` 렌더링
- ✅ `HomePage`가 렌더링되면 이미 권한이 허용된 상태
- ✅ 네이티브 쪽에서 추가 권한 체크로 이중 차단 (방어적 프로그래밍)

### 추가 안전장치
- 네이티브 쪽에서 `initializeIfNeeded`/`ensureHealthyOrReinit`/`ensureConfigured` 모두 권한 체크 추가
- 권한 미허용 시 네이티브에서 즉시 return하여 AVFoundation 세션 건드리지 않음

## 예상 동작 (수정 후)

### 시나리오: 권한 거부 → 설정으로 이동 → 권한 토글

1. **권한 거부 상태** (`permission denied`)
2. **"설정으로 이동" 버튼 클릭**
   - `setSkipAutoReinit(true)` 호출
   - `openSettings()` 호출
3. **앱이 background로 전환**
   - `onAppWillResignActive()` 호출
   - **debounce**: 0.5초 이내 중복 호출 무시 ✅
   - `applyLifecycleTransition(reason: "willResignActive", action: "stop")` 호출
   - **debounce**: 동일 reason+timestamp 체크로 중복 호출 무시 ✅
   - permission denied + background 전환 → `cleanupForLifecycle` 호출
   - **safe teardown**: 세션 중지 + outputs 제거 ✅
4. **`onAppDidEnterBackground()` 호출**
   - **debounce**: 0.5초 이내 중복 호출 무시 ✅
   - `applyLifecycleTransition(reason: "didEnterBackground", action: "teardown")` 호출
   - **debounce**: 동일 reason+timestamp 체크로 중복 호출 무시 ✅
   - **safe teardown**: 세션 중지 + outputs 제거 ✅
5. **설정 화면에서 권한 토글**
   - iOS가 백그라운드 앱의 카메라 세션을 확인
   - **수정 후**: 세션이 이미 정리되어 있음 → SIGKILL 없음 ✅
6. **앱 복귀 시도**
   - `onAppDidBecomeActive()` 호출
   - `shouldSkipAutoReinit = true` 확인 → auto-reinit 스킵 ✅
   - `ensureHealthyOrReinit` 호출 → **권한 체크로 즉시 return** ✅
   - `initializeIfNeeded` 호출 시도 → **권한 체크로 즉시 return** ✅
   - Flutter에서 권한 재검사 → HomePage 또는 다이얼로그 표시

## 테스트 체크리스트

### 필수 테스트
- [ ] 권한 거부 → 설정으로 이동 → 설정에서 권한 토글 → 앱이 SIGKILL 없이 정상 동작
- [ ] 권한 거부 → 설정으로 이동 → 권한 허용 → 앱 복귀 시 HomePage 표시
- [ ] 권한 거부 → 설정으로 이동 → 권한 변경 없음 → 앱 복귀 시 다이얼로그 재표시
- [ ] Control Center나 알림을 띄울 때 카메라 세션이 유지되는지 확인 (일반 사용 시나리오)

### 로그 확인 사항
- [ ] `onAppWillResignActive`/`onAppDidEnterBackground`에서 "SKIPPED - debounce" 로그 확인
- [ ] `applyLifecycleTransition`에서 "SKIPPED - duplicate call" 로그 확인
- [ ] `initializeIfNeeded`에서 "SKIPPED: camera permission not authorized" 로그 확인
- [ ] `ensureHealthyOrReinit`/`ensureConfigured`에서 "SKIPPED - camera permission not authorized" 로그 확인
- [ ] SAFE TEARDOWN 로그 확인: `[Native] ✅ SAFE TEARDOWN: Session stopped`
- [ ] SAFE TEARDOWN 로그 확인: `[Native] ✅ SAFE TEARDOWN: Outputs removed`
- [ ] SIGKILL 없이 정상 종료 확인

### 중복 호출 방지 확인
- [ ] 동일 reason으로 `applyLifecycleTransition`이 0.5초 이내 연속 호출되면 두 번째 호출이 무시됨
- [ ] `onAppWillResignActive`가 0.5초 이내 연속 호출되면 두 번째 호출이 무시됨
- [ ] `onAppDidEnterBackground`가 0.5초 이내 연속 호출되면 두 번째 호출이 무시됨

## 변경 파일

1. **`ios/Runner/NativeCamera.swift`**
   - `initializeIfNeeded`: 시작 부분에 권한 체크 추가
   - `onAppWillResignActive`/`onAppDidEnterBackground`: debounce 추가
   - `applyLifecycleTransition`: reason+timestamp 기반 debounce 추가
   - `ensureHealthyOrReinit`/`ensureConfigured`: 권한 체크 추가

2. **`lib/widgets/permission_wrapper.dart`**
   - 이미 권한 체크 및 re-entrancy guard 구현됨 (변경 없음)

3. **`DUPLICATE_CALLS_AND_PERMISSION_FIX.md`** (새 파일)
   - 중복 호출 및 권한 체크 문제 수정 완료 문서

## 참고

### debounce 간격
- `debounceInterval = 0.5` 초 (0.5초 이내 중복 호출 무시)
- iOS 시스템 이벤트가 빠르게 연속 발생할 수 있으므로 0.5초로 설정

### 권한 체크 우선순위
1. Flutter `PermissionWrapper`에서 `permissionsGranted=true`일 때만 `HomePage` 렌더링
2. 네이티브 모든 초기화 함수에서 권한 체크 (방어적 프로그래밍)
