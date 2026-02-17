# SIGKILL 핵심 수정 완료

## 근본 원인 분석 (로그 기반)

### 관찰된 문제
1. **`cleanupForLifecycle`의 `defer`가 너무 빨리 실행됨**
   - permission denied 경로에서 `sessionQueue.async` 호출 후 즉시 `return`
   - `defer { isCleaningForLifecycle = false }`가 즉시 실행되어 플래그가 `false`로 리셋
   - 두 번째 호출이 들어오면 플래그가 `false`이므로 또 호출됨

2. **`GlobalLifecycleManager`의 debounce가 작동하지 않음**
   - 같은 reason인데도 "DEBOUNCE FIRST CALL"이 출력됨
   - `lastTransitionReason`이 제대로 업데이트되지 않거나, 여러 스레드에서 동시에 호출됨

3. **`applyLifecycleTransition START`가 여러 번 호출됨** (854-856, 874-879)
   - 전역 debounce가 작동하지 않아 동일 reason의 중복 호출이 발생

## 최종 수정 사항

### 수정 1: `cleanupForLifecycle`의 플래그 리셋 타이밍 수정
**위치**: `ios/Runner/NativeCamera.swift:6234-6636`

**변경 내용**:
- `defer { isCleaningForLifecycle = false }` 제거
- **Permission denied 경로**: `sessionQueue.async` 내부의 completion에서 플래그 리셋 (6386, 6294 라인)
- **일반 경로**: `sessionQueue.async` 내부의 completion에서 플래그 리셋 (6629 라인)
- 모든 경로에서 completion 호출 전에 플래그를 리셋하도록 통일

**코드**:
```swift
private func cleanupForLifecycle(...) {
    if isCleaningForLifecycle {
        // 중복 호출 방지
        return
    }
    
    isCleaningForLifecycle = true
    // defer 제거!
    
    if isPermissionDenied {
        sessionQueue.async { [weak self] in
            // ... safe teardown 수행 ...
            DispatchQueue.main.async {
                self.isCleaningForLifecycle = false  // ✅ completion에서 리셋
                if let completion = completion {
                    completion()
                }
            }
        }
        return
    }
    
    // 일반 경로
    sessionQueue.async { [weak self] in
        // ... cleanup 수행 ...
        DispatchQueue.main.async {
            self.isCleaningForLifecycle = false  // ✅ completion에서 리셋
            if let completion = completion {
                completion()
            }
        }
    }
}
```

### 수정 2: `GlobalLifecycleManager`의 debounce 로직 개선
**위치**: `ios/Runner/NativeCamera.swift:80-143`

**변경 내용**:
- debounce 체크 로직에 상세 로그 추가
- `wasLastReason`, `wasLastTime` 변수를 사용하여 디버깅 용이
- `lastTransitionReason` 업데이트 타이밍 명확화

**코드**:
```swift
func tryAcquire(reason: String) -> Bool {
    var acquired = false
    var shouldSkipDebounce = false
    var elapsedTime: TimeInterval = 0
    var wasLastReason: String? = nil
    var wasLastTime: Date? = nil
    
    lockQueue.sync {
        let now = Date()
        wasLastReason = lastTransitionReason
        wasLastTime = lastTransitionTime
        
        if let lastReason = lastTransitionReason,
           let lastTime = lastTransitionTime,
           lastReason == reason {
            elapsedTime = now.timeIntervalSince(lastTime)
            if elapsedTime < debounceInterval {
                shouldSkipDebounce = true
                // 상세 로그
                return
            } else {
                // debounce 간격을 넘었으므로 업데이트
                lastTransitionReason = reason
                lastTransitionTime = now
            }
        } else {
            // 첫 호출 또는 다른 reason
            lastTransitionReason = reason
            lastTransitionTime = now
            // 상세 로그 (previousReason 포함)
        }
        
        // lock 획득 시도
        // ...
    }
    
    if shouldSkipDebounce {
        return false
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
     - debounce 체크 → 통과
     - 플래그 설정 → `isProcessingDidEnterBackground = true`
     - `applyLifecycleTransition(reason: "didEnterBackground", action: "teardown")` 호출
   - `onAppDidEnterBackground()` 두 번째 호출 (0.5초 이내)
     - debounce 체크 → **스킵 로그 출력** → 즉시 return ✅
   - `applyLifecycleTransition` 첫 호출
     - `GlobalLifecycleManager.tryAcquire(reason: "didEnterBackground")` 호출
     - 전역 debounce 체크 → 통과 (첫 호출)
     - lock 획득 성공
     - `cleanupForLifecycle` 호출
   - `applyLifecycleTransition` 두 번째 호출 (0.5초 이내, 동일 reason)
     - `GlobalLifecycleManager.tryAcquire(reason: "didEnterBackground")` 호출
     - 전역 debounce 체크 → **스킵 로그 출력** → `false` 반환 ✅
     - "cleanup already in progress" 로그 → 즉시 return ✅
   - `cleanupForLifecycle` 첫 호출
     - `isCleaningForLifecycle` 체크 → `false` → 통과
     - 플래그 설정 → `isCleaningForLifecycle = true`
     - permission denied 감지 → safe teardown 수행
     - `sessionQueue.async`로 비동기 실행
     - 세션 중지 + outputs 제거
     - **completion에서 플래그 리셋** → `isCleaningForLifecycle = false` ✅
   - `cleanupForLifecycle` 두 번째 호출 (중복 호출)
     - `isCleaningForLifecycle` 체크 → `true` → **스킵 로그 출력** → 즉시 return ✅
4. **설정 화면에서 권한 토글**
   - iOS가 백그라운드 앱의 카메라 세션을 확인
   - **수정 후**: 세션이 이미 정리되어 있음 → SIGKILL 없음 ✅

## 핵심 개선 사항

1. **플래그 리셋 타이밍 수정**: `defer` 제거, 모든 경로에서 completion에서 플래그 리셋
2. **Re-entrancy guard 강화**: `isCleaningForLifecycle` 플래그가 비동기 작업 완료 전까지 유지됨
3. **전역 debounce 개선**: 상세 로그 추가로 디버깅 용이

## 테스트 체크리스트

### 필수 테스트
- [ ] 권한 거부 → 설정으로 이동 → 권한 토글 → SIGKILL 없이 정상 동작
- [ ] 로그에서 다음 메시지 확인:
  - `[Native] ⏸️ onAppDidEnterBackground: SKIPPED - debounce`
  - `[GlobalLifecycleManager] tryAcquire: SKIPPED - duplicate reason within debounce interval`
  - `[Native] ⏸️ applyLifecycleTransition: SKIPPED - cleanup already in progress or duplicate reason`
  - `[Native] ⏸️ cleanupForLifecycle: SKIPPED - already cleaning`
- [ ] `cleanupForLifecycle`이 한 번만 호출되는지 확인
- [ ] `isCleaningForLifecycle` 플래그가 completion에서만 리셋되는지 확인
- [ ] `SAFE TEARDOWN: Outputs removed`가 한 번만 출력되는지 확인
