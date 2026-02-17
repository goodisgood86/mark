# Throttle 및 Debounce 원자적 처리 수정 완료

## 핵심 문제 분석 (최신 로그 기반)

### 관찰된 문제
1. **`onAppDidEnterBackground`가 여러 번 호출됨**
   - 728: "FIRST CALL, PASSING" 후에도 계속 호출됨
   - 730-731: `shouldSkipAutoReinit=true` 설정이 2번 호출됨
   - 745-748: `shouldSkipAutoReinit=true` 설정이 4번 더 호출됨
   - throttle 로그가 출력되지 않음 → throttle이 작동하지 않음

2. **`applyLifecycleTransition START`가 여러 번 호출됨** (738-740, 761-766)
   - 같은 reason "didEnterBackground"로 6번 호출됨
   - `GlobalLifecycleManager`의 debounce가 작동하지 않음

3. **`GlobalLifecycleManager.tryAcquire`가 여러 번 성공함** (733, 751-752)
   - 같은 reason인데도 debounce가 작동하지 않음

### 근본 원인
1. **Throttle 체크와 시간 업데이트가 원자적이지 않음**
   - 첫 호출에서 `lastDidEnterBackgroundTime` 업데이트
   - 동시에 들어온 두 번째 호출이 throttle 체크 시도
   - 첫 호출이 아직 완료되지 않아 두 번째 호출이 통과

2. **플래그 체크와 throttle 체크 순서 문제**
   - throttle 체크 후 플래그 체크를 수행
   - throttle 통과 후 플래그 설정 전에 다른 호출이 들어오면 또 통과

3. **`GlobalLifecycleManager`의 debounce와 lock 획득이 원자적이지 않음**
   - debounce 체크 후 lock 획득 사이에 다른 호출이 들어올 수 있음

## 최종 수정 사항

### 수정 1: `onAppWillResignActive` 원자적 처리
**위치**: `ios/Runner/NativeCamera.swift:6984-7041`

**변경 내용**:
- 플래그 체크를 가장 먼저 수행 (이미 처리 중이면 즉시 스킵)
- throttle + debounce + 플래그 체크를 모두 동기화된 큐에서 원자적으로 수행
- 스킵 시에도 시간 업데이트 (다음 호출까지 대기 시간 확보)
- 스킵 시 플래그 즉시 리셋

**코드 구조**:
```swift
@objc private func onAppWillResignActive() {
    let now = Date()
    var shouldSkip = false
    var skipReason = ""
    
    debounceQueue.sync {
        // 1. 플래그 체크 (가장 먼저)
        if isProcessingWillResignActive {
            shouldSkip = true
            skipReason = "already processing"
            return  // 즉시 스킵
        }
        
        // 2. 플래그 설정 (처리 시작 표시)
        isProcessingWillResignActive = true
        
        // 3. throttle 체크
        if let lastTime = lastWillResignActiveTime {
            elapsedTime = now.timeIntervalSince(lastTime)
            if elapsedTime < throttleInterval {
                shouldSkip = true
                skipReason = "throttle"
                lastWillResignActiveTime = now  // 스킵 시에도 업데이트
                isProcessingWillResignActive = false  // 플래그 리셋
                return
            }
            // debounce 체크도 동일하게...
        } else {
            // 첫 호출: 시간 업데이트 및 통과
            lastWillResignActiveTime = now
        }
    }
    
    if shouldSkip {
        return  // 스킵
    }
    
    defer {
        // 정상 완료 시 플래그 리셋
        debounceQueue.sync {
            isProcessingWillResignActive = false
        }
    }
    
    // 실제 처리 로직...
}
```

### 수정 2: `onAppDidEnterBackground` 원자적 처리
**위치**: `ios/Runner/NativeCamera.swift:7065-7157`

**변경 내용**:
- 동일한 원자적 처리 구조 적용
- throttle + debounce + 플래그 체크를 모두 동기화된 큐에서 수행

### 수정 3: `GlobalLifecycleManager.tryAcquire` 원자적 처리
**위치**: `ios/Runner/NativeCamera.swift:80-154`

**변경 내용**:
- lock 체크를 먼저 수행 (이미 cleanup 중이면 debounce 체크 불필요)
- debounce 체크와 lock 획득을 원자적으로 수행
- 같은 reason의 중복 호출 완전 차단

**코드 구조**:
```swift
func tryAcquire(reason: String) -> Bool {
    var acquired = false
    var shouldSkipDebounce = false
    
    lockQueue.sync {
        // 1. lock 체크 (가장 먼저)
        if _isCleaning {
            acquired = false
            return  // 이미 cleanup 중
        }
        
        // 2. debounce 체크
        if let lastReason = lastTransitionReason,
           let lastTime = lastTransitionTime,
           lastReason == reason {
            elapsedTime = now.timeIntervalSince(lastTime)
            if elapsedTime < debounceInterval {
                shouldSkipDebounce = true
                acquired = false
                return  // debounce로 스킵
            }
            // debounce 통과: 시간 업데이트 및 lock 획득
            lastTransitionReason = reason
            lastTransitionTime = now
            _isCleaning = true
            acquired = true
            return
        } else {
            // 첫 호출 또는 다른 reason: 시간 업데이트 및 lock 획득
            lastTransitionReason = reason
            lastTransitionTime = now
            _isCleaning = true
            acquired = true
            return
        }
    }
    
    if shouldSkipDebounce {
        return false  // debounce로 스킵
    }
    
    return acquired
}
```

## 예상 동작 (수정 후)

### 시나리오: 권한 거부 → 설정으로 이동 → 권한 토글

1. **권한 거부 상태** (`permission denied`)
2. **"설정으로 이동" 버튼 클릭**
   - `setSkipAutoReinit(true)` 호출
   - `openSettings()` 호출
3. **앱이 background로 전환**
   - `onAppDidEnterBackground()` 첫 호출
     - 플래그 체크 → 통과 (처리 중 아님)
     - 플래그 설정 → `isProcessingDidEnterBackground = true`
     - throttle 체크 → 통과 (첫 호출)
     - 시간 업데이트 → `lastDidEnterBackgroundTime = now`
     - 실제 처리 로직 실행
   - `onAppDidEnterBackground()` 두 번째 호출 (0.1초 이내, 동시 호출)
     - 플래그 체크 → **스킵** (이미 처리 중) ✅
     - 즉시 return
   - `onAppDidEnterBackground()` 세 번째 호출 (0.5초 이내)
     - 플래그 체크 → 통과 (첫 호출 완료 후 플래그 리셋됨)
     - 플래그 설정 → `isProcessingDidEnterBackground = true`
     - throttle 체크 → **스킵** (0.5초 < 2초) ✅
     - 시간 업데이트 → `lastDidEnterBackgroundTime = now`
     - 플래그 리셋 → `isProcessingDidEnterBackground = false`
     - 즉시 return
   - `applyLifecycleTransition` 첫 호출
     - `GlobalLifecycleManager.tryAcquire(reason: "didEnterBackground")` 호출
     - lock 체크 → 통과 (cleanup 중 아님)
     - debounce 체크 → 통과 (첫 호출)
     - 시간 업데이트 및 lock 획득
     - `cleanupForLifecycle` 호출
   - `applyLifecycleTransition` 두 번째 호출 (0.3초 이내, 같은 reason)
     - `GlobalLifecycleManager.tryAcquire(reason: "didEnterBackground")` 호출
     - lock 체크 → **스킵** (이미 cleanup 중) ✅
     - 즉시 return
4. **설정 화면에서 권한 토글**
   - iOS가 백그라운드 앱의 카메라 세션을 확인
   - **수정 후**: 세션이 이미 정리되어 있고, 중복 호출이 완전히 차단됨 → SIGKILL 없음 ✅

## 변경 파일

1. **`ios/Runner/NativeCamera.swift`**
   - `onAppWillResignActive`: 원자적 처리 구조로 수정
   - `onAppDidEnterBackground`: 원자적 처리 구조로 수정
   - `GlobalLifecycleManager.tryAcquire`: 원자적 처리 구조로 수정

## 테스트 체크리스트

### 필수 테스트
- [ ] 권한 거부 → 설정으로 이동 → 권한 토글 → SIGKILL 없이 정상 동작
- [ ] 로그에서 다음 메시지 확인:
  - `[Native] ⏸️ onAppWillResignActive: FLAG CHECK - already processing, SKIPPING`
  - `[Native] ⏸️ onAppWillResignActive: THROTTLE - elapsed=X.XXXs < threshold=2.0s, SKIPPING`
  - `[Native] ⏸️ onAppDidEnterBackground: FLAG CHECK - already processing, SKIPPING`
  - `[Native] ⏸️ onAppDidEnterBackground: THROTTLE - elapsed=X.XXXs < threshold=2.0s, SKIPPING`
  - `[GlobalLifecycleManager] tryAcquire: SKIPPED - duplicate reason within debounce interval`
  - `[GlobalLifecycleManager] tryAcquire: already cleaning, returning false`
- [ ] `onAppWillResignActive`/`onAppDidEnterBackground`가 throttle로 차단되는지 확인
- [ ] `applyLifecycleTransition START/END`가 한 번만 호출되는지 확인
- [ ] `SAFE TEARDOWN: Outputs removed`가 한 번만 출력되는지 확인

### 로그 확인 사항
- [ ] throttle 로그가 정상적으로 출력되는지 확인
- [ ] 플래그 체크 로그가 정상적으로 출력되는지 확인
- [ ] `GlobalLifecycleManager`의 debounce가 정상 작동하는지 확인
- [ ] SIGKILL 없이 정상 종료 확인

## 핵심 개선 사항

1. **원자적 처리**: throttle + debounce + 플래그 체크를 모두 동기화된 큐에서 원자적으로 수행
2. **플래그 우선 체크**: 이미 처리 중이면 throttle/debounce 체크 전에 즉시 스킵
3. **시간 업데이트 보장**: 스킵 시에도 시간 업데이트하여 다음 호출까지 대기 시간 확보
4. **Lock과 Debounce 원자적 처리**: `GlobalLifecycleManager`에서 lock 체크와 debounce 체크를 원자적으로 수행
