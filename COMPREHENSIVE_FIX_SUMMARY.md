# 종합 SIGKILL 방지 패치 완료 요약

## 적용된 수정 사항

### A) 옵저버/인스턴스 중복 제거 ✅

#### 1. Static 플래그로 전역 옵저버 등록 보장
- `globalObserversRegistered` static 변수 추가
- `globalObserverLock`으로 전역 동기화
- `init(nibName:)`과 `init(coder:)` 모두에서 static 플래그 체크
- `deinit`에서 `removeObserver(self)` 호출 추가

**수정 파일:** `ios/Runner/NativeCamera.swift`
- Line 540-542: Static 플래그 추가
- Line 599-669: `init(nibName:)`에서 static 플래그 체크 및 등록
- Line 697-754: `init(coder:)`에서 static 플래그 체크 및 등록
- Line 904-920: `deinit`에서 옵저버 제거

#### 2. CameraManager 중복 생성 방지 강화
- 기존 VC가 아직 attached되어 있는지 확인
- 중복 생성 시 스킵 로직 강화

**수정 파일:** `ios/Runner/CameraManager.swift`
- Line 37-53: 중복 생성 방지 로직 강화

### B) 권한 승인 전 카메라 접근 전면 차단 ✅

#### 1. `initialize` 함수에 권한 체크 추가
- 함수 시작 부분에서 `authStatus != .authorized` 체크
- 권한 미허용 시 즉시 return 및 completion 호출
- 기존 switch 문 제거 (권한 요청 로직 제거)

**수정 파일:** `ios/Runner/NativeCamera.swift`
- Line 2395-2404: 권한 체크 추가
- Line 2406-2485: 기존 switch 문 제거, authorized 상태에서만 `_performInitialize` 호출

#### 2. `onAppDidBecomeActive`에서 권한 체크 강화
- 함수 시작 부분에서 `authStatus != .authorized` 체크
- 권한 미허용 시 모든 작업(프리뷰 복구 포함) 건너뛰고 즉시 return

**수정 파일:** `ios/Runner/NativeCamera.swift`
- Line 7313-7323: 권한 체크를 가장 먼저 수행

#### 3. `initializeIfNeeded`, `ensureHealthyOrReinit`, `ensureConfigured`는 이미 권한 체크 있음 ✅

### C) 라이프사이클 중복 호출 하드 차단 ✅

#### 1. GlobalLifecycleManager에 reason+instanceId 기반 throttle 추가
- `TransitionKey` 구조체 추가 (reason + instanceId 조합)
- `throttleInterval` (2초) 추가
- reason+instanceId 조합 기반 debounce/throttle

**수정 파일:** `ios/Runner/NativeCamera.swift`
- Line 73-81: TransitionKey 구조체 및 throttleInterval 추가
- Line 88-174: `tryAcquire(reason:instanceId:)` 메서드에 reason+instanceId 조합 기반 throttle/debounce 추가

#### 2. `applyLifecycleTransition`에서 instanceId 전달
- `stableInstancePtr`를 instanceId로 사용
- `tryAcquire(reason:instanceId:)` 호출 시 instanceId 전달
- 인스턴스별 re-entrancy guard 추가

**수정 파일:** `ios/Runner/NativeCamera.swift`
- Line 6778-6815: 인스턴스별 re-entrancy guard 추가
- Line 6800: `tryAcquire(reason:instanceId:)` 호출
- Line 6873-6898: completion에서 플래그 리셋 (비동기 완료 후)

#### 3. `onAppWillResignActive` / `onAppDidEnterBackground` throttle/debounce는 이미 구현됨 ✅

### D) Flutter 쪽 동기화 ✅

#### 1. `_checkPermissions` re-entrancy guard 강화
- 라이프사이클 상태 체크 추가
- inactive/paused/hidden 상태에서는 pending 플래그만 설정

**수정 파일:** `lib/widgets/permission_wrapper.dart`
- Line 78-83: `_needsPermissionCheck` 플래그 추가
- Line 288-315: 라이프사이클 상태 체크 및 pending 플래그 설정

#### 2. 라이프사이클 전환 시 pending 플래그 처리
- `resumed` 상태에서 `_needsPermissionCheck` 플래그 체크
- pending 플래그가 있으면 권한 체크 재시도

**수정 파일:** `lib/widgets/permission_wrapper.dart`
- Line 229-234: pending 플래그 처리 추가

#### 3. HomePage 진입 전 권한 체크는 이미 구현됨 ✅

## 수정된 파일 목록

1. `ios/Runner/NativeCamera.swift`
   - 옵저버 등록: static 플래그 추가
   - 권한 체크: `initialize`, `onAppDidBecomeActive`에 추가
   - 라이프사이클: GlobalLifecycleManager에 reason+instanceId 조합 기반 throttle 추가
   - `applyLifecycleTransition`: 인스턴스별 re-entrancy guard 추가

2. `ios/Runner/CameraManager.swift`
   - 중복 생성 방지 로직 강화

3. `lib/widgets/permission_wrapper.dart`
   - 라이프사이클 상태 체크 추가
   - pending 플래그 처리 추가

## 예상되는 개선 효과

### 수정 전
```
[Native] ✅ NotificationCenter observers registered (여러 번)
[Native] 🔄 applyLifecycleTransition START: ... (10회 이상)
[Native] 🧹 cleanupForLifecycle START: ... (10회 이상)
[Native] 🔥 initialize() STARTED: ... (authStatus=0에서도 호출)
Process X stopped
* thread #1, queue = 'com.apple.main-thread', stop reason = signal SIGKILL
```

### 수정 후 (예상)
```
[Native] ✅ NotificationCenter observers registered ONCE (1회만)
[Native] ⏸️ initialize() SKIPPED: camera permission not authorized (authStatus=0)
[Native] ⏸️ onAppDidBecomeActive: SKIPPED ALL - camera permission not authorized
[Native] 🔄 applyLifecycleTransition START: ... (1회만)
[Native] ⏸️ applyLifecycleTransition: SKIPPED - already applying transition (나머지)
[Native] ⏸️ GlobalLifecycleManager tryAcquire: SKIPPED - throttle/debounce (중복 호출)
[Native] 🧹 cleanupForLifecycle START: ... (1회만)
✅ SIGKILL 없음
```

## 테스트 체크리스트

### 1. 옵저버 중복 등록 확인
- [ ] 앱 시작 시 "✅ NotificationCenter observers registered ONCE" 로그가 1회만 출력되는지 확인
- [ ] "⚠️ NotificationCenter observers already registered globally" 로그가 출력되지 않는지 확인

### 2. 권한 체크 확인
- [ ] `initialize` 함수에서 권한 미허용 시 즉시 return되는지 확인
- [ ] `onAppDidBecomeActive`에서 권한 미허용 시 모든 작업이 스킵되는지 확인
- [ ] `initializeIfNeeded`가 authStatus=0일 때 호출되지 않는지 확인

### 3. 라이프사이클 중복 호출 확인
- [ ] `applyLifecycleTransition START`가 1회만 호출되는지 확인
- [ ] `SKIPPED - already applying transition` 로그가 중복 호출 시 출력되는지 확인
- [ ] `GlobalLifecycleManager tryAcquire: SKIPPED - throttle/debounce` 로그가 중복 호출 시 출력되는지 확인
- [ ] `onAppDidEnterBackground` throttle이 작동하여 중복 호출이 차단되는지 확인

### 4. Flutter 동기화 확인
- [ ] `_checkPermissions`가 라이프사이클 전환 중 호출되지 않는지 확인
- [ ] `_needsPermissionCheck` 플래그가 resumed 시 권한 체크를 트리거하는지 확인
- [ ] 권한 미허용 시 HomePage가 표시되지 않는지 확인

### 5. SIGKILL 발생 확인
- [ ] 권한 거부 → 설정 이동 → 권한 토글 → 앱 복귀 시 SIGKILL이 발생하지 않는지 확인
- [ ] 로그에서 중복 호출이 차단되는지 확인

## 주요 변경 사항 요약

### Swift (NativeCamera.swift)
1. **Static 옵저버 플래그**: 전역 옵저버 등록 보장
2. **권한 체크 강화**: 모든 초기화 함수에서 `authStatus != .authorized` 체크
3. **reason+instanceId 조합 throttle**: GlobalLifecycleManager에 reason+instanceId 기반 debounce/throttle 추가
4. **인스턴스별 re-entrancy guard**: `applyLifecycleTransition`에 인스턴스별 플래그 추가

### Dart (permission_wrapper.dart)
1. **라이프사이클 상태 체크**: inactive/paused/hidden 상태에서는 native 호출 차단
2. **Pending 플래그**: 라이프사이클 전환 중에는 pending 플래그만 설정, resumed 시 재시도

## 빌드 결과
✅ 빌드 성공 (컴파일 오류 없음)

## 다음 단계
위 테스트 체크리스트를 확인하여 모든 수정 사항이 정상적으로 작동하는지 검증하세요.
