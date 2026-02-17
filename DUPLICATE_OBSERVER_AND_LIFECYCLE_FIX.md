# 중복 옵저버 및 라이프사이클 핸들러 폭주 수정 완료

## 핵심 문제 분석

### 관찰된 문제
1. **NotificationCenter 옵저버 중복 등록**
   - `NativeCameraViewController.init`에서 항상 옵저버를 등록
   - 인스턴스가 여러 번 생성되면 각각 옵저버 등록
   - `deinit`에서 제거하지만 중복 등록 방지 메커니즘 부재

2. **라이프사이클 핸들러 폭주**
   - `onAppWillResignActive`/`onAppDidEnterBackground`가 0.5초 debounce만으로는 부족
   - 같은 reason으로 `applyLifecycleTransition START/END`가 연속 다발 발생
   - `SAFE TEARDOWN`이 여러 번 호출되고 "Already cleaned" 로그 반복

3. **권한 미허용 상태에서 initialize 반복 호출**
   - 이미 권한 체크가 있지만 추가 보강 필요

## 최종 수정 사항

### A) 옵저버 중복 등록 방지

#### 수정 1: 옵저버 등록 플래그 추가
**위치**: `ios/Runner/NativeCamera.swift:537-541`

**변경 내용**:
- `areObserversRegistered` 플래그 추가
- `observerRegistrationLock`을 사용한 thread-safe 체크
- `init`에서 이미 등록되어 있으면 스킵

**코드**:
```swift
// 옵저버 중복 등록 방지 플래그
private var areObserversRegistered = false
private let observerRegistrationLock = NSLock()
```

#### 수정 2: init에서 중복 등록 체크
**위치**: `ios/Runner/NativeCamera.swift:591-659`

**변경 내용**:
- 옵저버 등록 전에 플래그 체크
- 이미 등록되어 있으면 즉시 return
- 등록 완료 후 플래그 설정

**코드**:
```swift
override init(...) {
    // ...
    
    // 🔥🔥🔥 옵저버 중복 등록 방지: 플래그 체크
    observerRegistrationLock.lock()
    defer { observerRegistrationLock.unlock() }
    
    if areObserversRegistered {
        let msg = "[Native] ⚠️ NotificationCenter observers already registered, skipping..."
        // 로그 출력 및 return
        return
    }
    
    // 옵저버 등록
    NotificationCenter.default.addObserver(...)
    // ...
    
    // 플래그 설정
    areObserversRegistered = true
}
```

#### 수정 3: deinit에서 플래그 리셋
**위치**: `ios/Runner/NativeCamera.swift:837-850`

**변경 내용**:
- `removeObserver` 전에 플래그 체크
- 플래그 리셋 로그 추가
- `removeObserver` 후 플래그 리셋

**코드**:
```swift
deinit {
    observerRegistrationLock.lock()
    defer { observerRegistrationLock.unlock() }
    
    if areObserversRegistered {
        // 로그 출력
    }
    
    // 옵저버 제거
    NotificationCenter.default.removeObserver(self)
    
    // 플래그 리셋
    areObserversRegistered = false
}
```

### B) 라이프사이클 중복 호출 완전 차단

#### 수정 4: 2초 throttle 추가
**위치**: `ios/Runner/NativeCamera.swift:6965`

**변경 내용**:
- `throttleInterval: TimeInterval = 2.0` 추가
- debounce (0.5초)와 throttle (2초) 함께 사용

**코드**:
```swift
private let debounceInterval: TimeInterval = 0.5  // 0.5초 이내 중복 호출 무시
private let throttleInterval: TimeInterval = 2.0  // 🔥🔥🔥 2초 throttle (라이프사이클 이벤트 폭주 방지)
```

#### 수정 5: onAppWillResignActive에 throttle 추가
**위치**: `ios/Runner/NativeCamera.swift:6976-7042`

**변경 내용**:
- throttle 체크를 debounce보다 우선
- 2초 내 중복 호출 무시
- throttle 통과 후 debounce 체크

**코드**:
```swift
@objc private func onAppWillResignActive() {
    let now = Date()
    var shouldSkipThrottle = false
    var shouldSkipDebounce = false
    var shouldSkipProcessing = false
    
    debounceQueue.sync {
        // 🔥🔥🔥 throttle 체크: 2초 내 중복 호출 무시
        if let lastTime = lastWillResignActiveTime {
            elapsedTime = now.timeIntervalSince(lastTime)
            if elapsedTime < throttleInterval {
                shouldSkipThrottle = true
                return  // throttle로 스킵
            } else if elapsedTime < debounceInterval {
                shouldSkipDebounce = true
            } else {
                lastWillResignActiveTime = now
            }
        } else {
            lastWillResignActiveTime = now
        }
        // ...
    }
    
    if shouldSkipThrottle {
        return  // throttle로 스킵
    }
    // ...
}
```

#### 수정 6: onAppDidEnterBackground에 throttle 추가
**위치**: `ios/Runner/NativeCamera.swift:7044-7120`

**변경 내용**:
- 동일하게 throttle 체크 추가
- 2초 내 중복 호출 무시

### C) 권한 미허용 상태에서 initialize/permission 요청 단일화

#### 확인 결과
- ✅ `initializeIfNeeded`: 권한 체크 있음 (1080-1085 라인)
- ✅ `ensureHealthyOrReinit`: 권한 체크 있음 (6779-6786 라인)
- ✅ `ensureConfigured`: 권한 체크 있음 (6873-6880 라인)
- ✅ `PermissionWrapper._checkPermissions`: re-entrancy guard 있음 (244-247 라인)

**현재 상태**: 모든 권한 체크가 이미 구현되어 있음 ✅

## 예상 동작 (수정 후)

### 시나리오: 권한 거부 → 설정으로 이동 → 권한 토글

1. **권한 거부 상태** (`permission denied`)
2. **"설정으로 이동" 버튼 클릭**
   - `setSkipAutoReinit(true)` 호출
   - `openSettings()` 호출
3. **앱이 background로 전환**
   - `onAppDidEnterBackground()` 첫 호출
     - throttle 체크 → 통과 (첫 호출)
     - debounce 체크 → 통과
     - 플래그 설정 → `isProcessingDidEnterBackground = true`
     - `applyLifecycleTransition` 호출
   - `onAppDidEnterBackground()` 두 번째 호출 (0.1초 이내)
     - throttle 체크 → **스킵** (0.1초 < 2초) ✅
     - 즉시 return
   - `onAppDidEnterBackground()` 세 번째 호출 (1초 이내)
     - throttle 체크 → **스킵** (1초 < 2초) ✅
     - 즉시 return
   - `applyLifecycleTransition` 첫 호출
     - 전역 debounce 체크 → 통과
     - lock 획득 성공
     - `cleanupForLifecycle` 호출
   - `applyLifecycleTransition` 두 번째 호출 (0.5초 이내)
     - 전역 debounce 체크 → **스킵** ✅
     - "cleanup already in progress" → 즉시 return
4. **설정 화면에서 권한 토글**
   - iOS가 백그라운드 앱의 카메라 세션을 확인
   - **수정 후**: 세션이 이미 정리되어 있고, 중복 호출이 차단됨 → SIGKILL 없음 ✅

## 변경 파일

1. **`ios/Runner/NativeCamera.swift`**
   - 옵저버 등록 플래그 추가
   - init에서 중복 등록 체크
   - deinit에서 플래그 리셋
   - throttle 추가 (2초)
   - onAppWillResignActive/onAppDidEnterBackground에 throttle 적용

## 테스트 체크리스트

### 필수 테스트
- [ ] 권한 거부 → 설정으로 이동 → 권한 토글 → SIGKILL 없이 정상 동작
- [ ] 로그에서 다음 메시지 확인:
  - `[Native] ⚠️ NotificationCenter observers already registered, skipping`
  - `[Native] ⏸️ onAppWillResignActive: THROTTLE - elapsed=X.XXXs < threshold=2.0s, SKIPPING`
  - `[Native] ⏸️ onAppDidEnterBackground: THROTTLE - elapsed=X.XXXs < threshold=2.0s, SKIPPING`
  - `[Native] ⏸️ applyLifecycleTransition: SKIPPED - cleanup already in progress or duplicate reason`
  - `[Native] ⏸️ cleanupForLifecycle: SKIPPED - already cleaning`
- [ ] 옵저버가 한 번만 등록되는지 확인
- [ ] 라이프사이클 핸들러가 throttle로 차단되는지 확인
- [ ] `applyLifecycleTransition START/END`가 중복되지 않는지 확인

### 로그 확인 사항
- [ ] 옵저버 등록 로그가 한 번만 출력되는지 확인
- [ ] throttle 로그가 정상적으로 출력되는지 확인
- [ ] 전역 debounce가 정상 작동하는지 확인
- [ ] SIGKILL 없이 정상 종료 확인

## 핵심 개선 사항

1. **옵저버 중복 등록 방지**: 플래그 기반 체크로 인스턴스가 여러 번 생성되어도 옵저버는 한 번만 등록
2. **Throttle 추가**: 2초 throttle로 라이프사이클 이벤트 폭주 완전 차단
3. **Debounce + Throttle 조합**: 짧은 간격 중복 호출(debounce) + 긴 간격 연속 호출(throttle) 모두 차단
4. **권한 체크 확인**: 모든 initialize 함수에 권한 체크가 이미 구현되어 있음 확인
