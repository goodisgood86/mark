# 종합 SIGKILL 방지 패치 (최종 강화 버전)

## 문제 요약 (확정된 증상)
- SIGKILL 반복 발생
- 동일 instanceId에서 applyLifecycleTransition가 같은 reason으로 다중 호출됨
- "observers registered ONCE" 로그가 같은 instanceId에서 여러 번 출력됨 → guard 실패
- 권한 미승인 상태에서도 viewDidAppear auto-init이 계속 발생

## 적용된 수정 사항 (A~E 전체 반영)

### A) NotificationCenter 옵저버 등록 정확히 1회 보장 ✅

#### 1. registerObserversIfNeeded() 메서드로 통합
- `init(nibName:)`과 `init(coder:)` 모두에서 `registerObserversIfNeeded()` 호출
- static 플래그 (`globalObserversRegistered`)로 전역 보장
- `registeredInstancePtr`로 등록된 인스턴스 추적
- 최초 1회만 로그 출력

**수정 파일:** `ios/Runner/NativeCamera.swift`
- Line 561-566: Static 플래그 및 registeredInstancePtr 추가
- Line 664-748: `registerObserversIfNeeded()` 메서드 구현
- Line 607-638: `init(nibName:)`에서 `registerObserversIfNeeded()` 호출
- Line 716-724: `init(coder:)`에서 `registerObserversIfNeeded()` 호출

#### 2. deinit에서 removeObserver 확실히
- `deinit`에서 `NotificationCenter.default.removeObserver(self)` 호출
- 인스턴스 플래그만 리셋 (static 플래그는 유지)

### B) applyLifecycleTransition 단일화 (Singleflight) ✅

#### 1. GlobalLifecycleManager에 reason+instanceId 조합 기반 throttle 추가
- `TransitionKey` 구조체 (reason + instanceId)
- `throttleInterval` (2초) + `debounceInterval` (0.5초)
- reason+instanceId 조합이 같으면 2초 이내 중복 호출 무시

**수정 파일:** `ios/Runner/NativeCamera.swift`
- Line 73-81: TransitionKey 구조체 및 throttleInterval 추가
- Line 88-177: `tryAcquire(reason:instanceId:)` 메서드에 reason+instanceId 조합 기반 throttle/debounce 추가

#### 2. applyLifecycleTransition에서 instanceId 전달
- `stableInstancePtr`를 instanceId로 사용
- 인스턴스별 re-entrancy guard 추가
- completion에서 플래그 리셋 (비동기 완료 후)

**수정 파일:** `ios/Runner/NativeCamera.swift`
- Line 6678-6715: 인스턴스별 re-entrancy guard 추가
- Line 6700: `tryAcquire(reason:instanceId:)` 호출
- Line 6771-6799: completion에서 플래그 리셋

#### 3. onAppWillResignActive / onAppDidEnterBackground
- throttle/debounce가 이미 구현되어 있음
- applyLifecycleTransition 호출 시 instanceId 전달

### C) 권한 미승인 상태에서 auto-init 완전 차단 ✅

#### 1. viewDidAppear에서 권한 체크 추가
- `authStatus != .authorized` 체크를 가장 먼저 수행
- 권한 미승인 시 즉시 return (자동 초기화 절대 금지)
- 비동기 블록 내에서도 권한 재확인

**수정 파일:** `ios/Runner/NativeCamera.swift`
- Line 878-912: viewDidAppear에서 권한 체크 추가

#### 2. initialize / initializeIfNeeded / ensureHealthyOrReinit / ensureConfigured
- 모두 함수 시작 부분에서 `authStatus != .authorized` 체크
- 권한 미승인 시 즉시 return

### D) 권한 요청 Singleflight ✅

#### 1. NativeCamera 클래스에 in-flight 플래그 추가
- `isRequestingCameraPermission` static 변수
- `isRequestingPhotoLibraryPermission` static 변수
- `permissionRequestLock`으로 동기화

**수정 파일:** `ios/Runner/NativeCamera.swift`
- Line 11397-11400: NativeCamera 클래스에 권한 요청 플래그 추가
- Line 13089-13123: `requestCameraPermission`에 in-flight 플래그 체크 추가
- Line 13125-13182: `requestPhotoLibraryPermission`에 in-flight 플래그 체크 추가

#### 2. 권한 요청 중에는 재진입 금지
- in-flight 플래그가 true이면 즉시 return
- FlutterError 반환하여 이미 진행 중임을 알림
- 권한 요청 완료 시 플래그 리셋

### E) Flutter 쪽 동기화 ✅

#### 1. _checkPermissions re-entrancy guard
- `if (_isChecking) return;`로 중복 호출 방지
- 라이프사이클 상태 체크 추가 (inactive/paused/hidden 상태에서는 pending 플래그만 설정)

**수정 파일:** `lib/widgets/permission_wrapper.dart`
- Line 78-83: `_needsPermissionCheck` 플래그 추가
- Line 243-247: re-entrancy guard 추가
- Line 288-315: 라이프사이클 상태 체크 및 pending 플래그 설정

#### 2. 라이프사이클 전환 시 pending 플래그 처리
- `resumed` 상태에서 `_needsPermissionCheck` 플래그 체크
- pending 플래그가 있으면 권한 체크 재시도

**수정 파일:** `lib/widgets/permission_wrapper.dart`
- Line 229-234: pending 플래그 처리 추가

#### 3. HomePage 진입 전 권한 체크
- `permissionsGranted=true` 전까지 HomePage가 표시되지 않음
- 빈 화면만 표시 (다이얼로그는 별도 처리)

**수정 파일:** `lib/widgets/permission_wrapper.dart`
- Line 1077-1102: 권한 미허용 시 빈 화면 반환

## 수정된 파일 목록

1. `ios/Runner/NativeCamera.swift`
   - 옵저버 등록: `registerObserversIfNeeded()` 메서드로 통합
   - 권한 체크: `viewDidAppear`, `initialize`, `onAppDidBecomeActive`에 추가
   - 라이프사이클: GlobalLifecycleManager에 reason+instanceId 조합 기반 throttle 추가
   - `applyLifecycleTransition`: 인스턴스별 re-entrancy guard 추가
   - 권한 요청: NativeCamera 클래스에 in-flight 플래그 추가

2. `lib/widgets/permission_wrapper.dart`
   - 라이프사이클 상태 체크 추가
   - pending 플래그 처리 추가

## 예상되는 개선 효과

### 수정 전
```
[Native] ✅ NotificationCenter observers registered ONCE (여러 번, 같은 instanceId)
[Native] 🔄 applyLifecycleTransition START: ... (10회 이상, 같은 reason+instanceId)
[Native] 🔥 viewDidAppear: cameraState=idle, starting auto-initialization (authStatus=0)
[Native] 🔥 initialize() STARTED: ... (authStatus=0에서도 호출)
Process X stopped
* thread #1, queue = 'com.apple.main-thread', stop reason = signal SIGKILL
```

### 수정 후 (예상)
```
[Native] ✅ registerObserversIfNeeded: NotificationCenter observers registered ONCE (1회만)
[Native] ⏸️ viewDidAppear: SKIPPED auto-initialization - camera permission not authorized (authStatus=0)
[Native] ⏸️ initialize() SKIPPED: camera permission not authorized (authStatus=0)
[Native] ⏸️ requestCameraPermission: SKIPPED - permission request already in-flight
[Native] 🔄 applyLifecycleTransition START: ... (1회만, 같은 reason+instanceId)
[Native] ⏸️ applyLifecycleTransition: SKIPPED - global cleanup already in progress or duplicate reason
[Native] ⏸️ GlobalLifecycleManager tryAcquire: SKIPPED - throttle/debounce
✅ SIGKILL 없음
```

## 테스트 체크리스트

### 1. 옵저버 등록 확인
- [ ] 앱 시작 시 "✅ registerObserversIfNeeded: NotificationCenter observers registered ONCE" 로그가 1회만 출력되는지 확인
- [ ] "⚠️ registerObserversIfNeeded: SKIPPED - observers already registered globally" 로그가 두 번째 호출 시 출력되는지 확인
- [ ] 같은 instanceId에서 여러 번 출력되지 않는지 확인

### 2. 권한 체크 확인
- [ ] `viewDidAppear`에서 권한 미허용 시 auto-initialization이 스킵되는지 확인
- [ ] `initialize` 함수에서 권한 미허용 시 즉시 return되는지 확인
- [ ] `onAppDidBecomeActive`에서 권한 미허용 시 모든 작업이 스킵되는지 확인

### 3. 라이프사이클 중복 호출 확인
- [ ] `applyLifecycleTransition START`가 같은 reason+instanceId 조합에서 1회만 호출되는지 확인
- [ ] `SKIPPED - global cleanup already in progress or duplicate reason` 로그가 중복 호출 시 출력되는지 확인
- [ ] `GlobalLifecycleManager tryAcquire: SKIPPED - throttle/debounce` 로그가 2초 이내 중복 호출 시 출력되는지 확인

### 4. 권한 요청 Singleflight 확인
- [ ] `requestCameraPermission`이 동시에 여러 번 호출될 때 첫 번째만 진행되고 나머지는 SKIPPED되는지 확인
- [ ] `requestPhotoLibraryPermission`이 동시에 여러 번 호출될 때 첫 번째만 진행되고 나머지는 SKIPPED되는지 확인
- [ ] 권한 요청 완료 후 플래그가 리셋되는지 확인

### 5. Flutter 동기화 확인
- [ ] `_checkPermissions`가 라이프사이클 전환 중 호출되지 않는지 확인
- [ ] `_needsPermissionCheck` 플래그가 resumed 시 권한 체크를 트리거하는지 확인
- [ ] 권한 미허용 시 HomePage가 표시되지 않는지 확인

### 6. SIGKILL 발생 확인
- [ ] 권한 거부 → 설정 이동 → 권한 토글 → 앱 복귀 시 SIGKILL이 발생하지 않는지 확인
- [ ] 로그에서 중복 호출이 차단되는지 확인

## 주요 변경 사항 요약

### Swift (NativeCamera.swift)

#### 1. 옵저버 등록 통합
```swift
// registerObserversIfNeeded() 메서드로 통합
private func registerObserversIfNeeded() {
    // static 플래그로 최초 1회만 등록
    if NativeCameraViewController.globalObserversRegistered {
        return // 스킵
    }
    // 옵저버 등록...
}
```

#### 2. viewDidAppear 권한 체크
```swift
override func viewDidAppear(_ animated: Bool) {
    // 권한 체크 (가장 먼저)
    let authStatus = AVCaptureDevice.authorizationStatus(for: .video)
    if authStatus != .authorized {
        return // 자동 초기화 절대 금지
    }
    // auto-initialization 진행...
}
```

#### 3. 권한 요청 Singleflight
```swift
case "requestCameraPermission":
    NativeCamera.permissionRequestLock.lock()
    if NativeCamera.isRequestingCameraPermission {
        // SKIPPED
        return
    }
    NativeCamera.isRequestingCameraPermission = true
    // 권한 요청...
}
```

#### 4. applyLifecycleTransition Singleflight
- GlobalLifecycleManager에 reason+instanceId 조합 기반 throttle
- 인스턴스별 re-entrancy guard
- completion에서 플래그 리셋

### Dart (permission_wrapper.dart)
- 라이프사이클 상태 체크: inactive/paused/hidden 상태에서는 native 호출 차단
- Pending 플래그: 라이프사이클 전환 중에는 pending 플래그만 설정, resumed 시 재시도
- HomePage 진입: 권한 미허용 시 빈 화면 반환

## 빌드 결과
✅ 빌드 성공 (컴파일 오류 없음)

## 다음 단계
위 테스트 체크리스트를 확인하여 모든 수정 사항이 정상적으로 작동하는지 검증하세요.

특히 다음 시나리오를 테스트하세요:
1. 권한 거부 → "설정으로 이동" 클릭
2. 설정 화면에서 권한 토글
3. 앱 복귀

확인 사항:
- `registerObserversIfNeeded: NotificationCenter observers registered ONCE` 로그가 1회만 출력
- `viewDidAppear: SKIPPED auto-initialization - camera permission not authorized` (authStatus=0일 때)
- `applyLifecycleTransition START`가 같은 reason+instanceId에서 1회만 호출
- `SKIPPED - global cleanup already in progress or duplicate reason` 로그가 중복 호출 시 출력
- `SKIPPED - throttle/debounce` 로그가 2초 이내 중복 호출 시 출력
- `requestCameraPermission: SKIPPED - permission request already in-flight` (중복 호출 시)
- SIGKILL 발생하지 않음
