# 로그 분석 체크리스트

## 현재 확인된 로그
- ✅ `[NativeCamera] ✅ [1768039889.236539] MethodChannel registered:` - NativeCamera 정상 등록

## 테스트 시나리오: 권한 거부 → 설정 이동 → 권한 토글

### 예상되는 정상 로그 순서

#### 1. 앱 시작 시
```
[Native] 🔒 stableInstancePtr initialized: 0x...
[Native] ✅ NotificationCenter observers registered (viewId=0, instancePtr=0x...)
[Petgram][ViewIdCheck] 🎬 NativeCameraViewController init (viewId will be set later)
```

#### 2. 권한 거부 후 "설정으로 이동" 클릭 시
```
flutter: [DEBUG LOG] Dialog closed with rootNavigator, opening settings
flutter: [DEBUG LOG] openSettings called successfully: true
[Native] 🔥 setSkipAutoReinit: true (applied to ...)
```

#### 3. 설정 화면으로 이동 시 (앱이 background로 전환)
```
flutter: [DEBUG LOG] didChangeAppLifecycleState ENTRY: {"state":"AppLifecycleState.inactive",...}
[Native] ⏸️ onAppWillResignActive: FLAG CHECK - already processing, SKIPPING (첫 호출이 아닌 경우)
또는
[Native] ✅ onAppWillResignActive: FIRST CALL, PASSING (첫 호출인 경우)

flutter: [DEBUG LOG] didChangeAppLifecycleState ENTRY: {"state":"AppLifecycleState.hidden",...}
[Native] ✅ onAppDidEnterBackground: FIRST CALL, PASSING (첫 호출인 경우)
또는
[Native] ⏸️ onAppDidEnterBackground: THROTTLE - elapsed=X.XXXs < threshold=2.0s, SKIPPING (0.1초 이내 중복 호출)
또는
[Native] ⏸️ onAppDidEnterBackground: FLAG CHECK - already processing, SKIPPING (동시 호출)

[Native] 🔥 onAppDidEnterBackground: Setting shouldSkipAutoReinit=true (authStatus=2) (한 번만 출력되어야 함)

[GlobalLifecycleManager] tryAcquire: FIRST CALL or different reason (reason=didEnterBackground, previousReason=willResignActive) - acquired lock
또는
[GlobalLifecycleManager] tryAcquire: SKIPPED - duplicate reason within debounce interval (reason=didEnterBackground, elapsed=X.XXXs, threshold=0.5s) (중복 호출 차단)

[Native] 🔐 applyLifecycleTransition tryAcquire: acquired=true, instanceId=0x..., viewId=0, reason=didEnterBackground (한 번만)
[Native] 🔄 applyLifecycleTransition START: instanceId=0x..., viewId=0, reason=didEnterBackground, action=teardown, shouldTearDownOutputs=true (한 번만)
[Native] 🔥 cleanupForLifecycle: Permission denied - performing SAFE TEARDOWN (authStatus=2, reason=didEnterBackground, shouldTearDown=true, isCleaningFlag=false) (한 번만)
[Native] ✅ SAFE TEARDOWN: Session stopped (reason=didEnterBackground, wasRunning=true)
[Native] ✅ SAFE TEARDOWN: Outputs removed (reason=didEnterBackground, hadOutputs=true) (한 번만)
[Native] 🔄 applyLifecycleTransition END: instanceId=0x..., viewId=0, reason=didEnterBackground, action=teardown (한 번만)
[GlobalLifecycleManager] release: released lock (wasCleaning=true, isCleaning=false)
[Native] 🔓 applyLifecycleTransition release: instanceId=0x..., viewId=0, reason=didEnterBackground
```

#### 4. 설정 화면에서 권한 토글 시 (SIGKILL 발생하지 않아야 함)
- ✅ SIGKILL 없음
- 세션이 이미 정리되어 있음

#### 5. 앱 복귀 시 (resumed)
```
flutter: [DEBUG LOG] didChangeAppLifecycleState ENTRY: {"state":"AppLifecycleState.resumed",...}
[Native] ✅ DidBecomeActive: Restoring preview and ensuring configuration
[Native] ⏸️ onAppDidBecomeActive: SKIPPED auto-reinit - shouldSkipAutoReinit=true (returned from settings) (권한 미허용 시)
또는
[Native] 🔄 onAppDidBecomeActive: Calling initializeIfNeeded after 0.5s delay (권한 허용 시)
```

## 문제가 있는 로그 패턴

### ❌ 문제 1: 중복 호출이 차단되지 않음
```
[Native] ✅ onAppDidEnterBackground: FIRST CALL, PASSING
[Native] 🔥 onAppDidEnterBackground: Setting shouldSkipAutoReinit=true (authStatus=2)
[Native] 🔥 onAppDidEnterBackground: Setting shouldSkipAutoReinit=true (authStatus=2)  ← 중복!
[Native] 🔥 onAppDidEnterBackground: Setting shouldSkipAutoReinit=true (authStatus=2)  ← 중복!
```

**원인**: throttle/debounce가 작동하지 않음

### ❌ 문제 2: applyLifecycleTransition이 여러 번 호출됨
```
[Native] 🔄 applyLifecycleTransition START: ... reason=didEnterBackground
[Native] 🔄 applyLifecycleTransition START: ... reason=didEnterBackground  ← 중복!
[Native] 🔄 applyLifecycleTransition START: ... reason=didEnterBackground  ← 중복!
```

**원인**: GlobalLifecycleManager의 debounce가 작동하지 않음

### ❌ 문제 3: cleanupForLifecycle이 여러 번 호출됨
```
[Native] 🔥 cleanupForLifecycle: Permission denied - performing SAFE TEARDOWN ...
[Native] 🔥 cleanupForLifecycle: Permission denied - performing SAFE TEARDOWN ...  ← 중복!
[Native] ⏸️ SAFE TEARDOWN: Already cleaned - session not running and outputs already removed, SKIPPING  ← 여러 번 출력
```

**원인**: isCleaningForLifecycle 플래그가 작동하지 않음

### ❌ 문제 4: SIGKILL 발생
```
Process X stopped
* thread #1, queue = 'com.apple.main-thread', stop reason = signal SIGKILL
```

**원인**: 백그라운드에서 카메라 세션이 정리되지 않음

## 확인 사항

### 코드 수정 확인
- [x] 옵저버 중복 등록 방지 플래그 추가됨
- [x] onAppWillResignActive에 원자적 throttle/debounce 적용됨
- [x] onAppDidEnterBackground에 원자적 throttle/debounce 적용됨
- [x] GlobalLifecycleManager에 원자적 debounce 적용됨
- [x] cleanupForLifecycle에 re-entrancy guard 적용됨
- [x] 권한 체크가 모든 initialize 함수에 적용됨

### 테스트 확인
- [ ] 앱 시작 시 옵저버가 한 번만 등록되는지 확인
- [ ] 권한 거부 → 설정 이동 시 throttle 로그가 출력되는지 확인
- [ ] applyLifecycleTransition이 한 번만 호출되는지 확인
- [ ] cleanupForLifecycle이 한 번만 호출되는지 확인
- [ ] SIGKILL이 발생하지 않는지 확인

## 다음 단계
실제 테스트 시나리오를 실행하고 전체 로그를 확인하여 위 체크리스트를 검증하세요.
