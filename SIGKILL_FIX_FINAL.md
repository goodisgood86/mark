# SIGKILL 최종 수정 완료

## 문제 요약 (로그 기반)

### 관찰된 문제
1. **`onAppDidEnterBackground`가 여러 번 호출됨** (837-840, 846-847 라인)
   - debounce 로그가 없음 → debounce가 작동하지 않음
   
2. **`applyLifecycleTransition`이 동일 reason으로 여러 번 호출됨** (853-855, 865-870 라인)
   - debounce 로그가 없음 → debounce가 작동하지 않음
   
3. **`GlobalLifecycleManager.tryAcquire`가 여러 번 성공함** (841-842, 848 라인)
   - lock이 제대로 작동하지 않음

4. **`cleanupForLifecycle`이 여러 번 호출됨** (856-857, 871-874 라인)
   - `SAFE TEARDOWN: Outputs removed`가 여러 번 출력됨

5. **결국 SIGKILL 발생** (1010-1019 라인)

## 최종 수정 사항

### 수정 1: `GlobalLifecycleManager`에 전역 debounce 추가
**위치**: `ios/Runner/NativeCamera.swift:68-135`

**변경 내용**:
- `tryAcquire(reason:)` 메서드에 reason 파라미터 추가
- 전역 debounce 체크 추가 (`lastTransitionReason`, `lastTransitionTime` 사용)
- 모든 인스턴스가 공유하는 전역 debounce로 동일 reason의 중복 호출 방지

**코드**:
```swift
func tryAcquire(reason: String) -> Bool {
    var acquired = false
    var shouldSkipDebounce = false
    var elapsedTime: TimeInterval = 0
    
    lockQueue.sync {
        // 전역 debounce 체크
        let now = Date()
        if let lastReason = lastTransitionReason,
           let lastTime = lastTransitionTime,
           lastReason == reason {
            elapsedTime = now.timeIntervalSince(lastTime)
            if elapsedTime < debounceInterval {
                shouldSkipDebounce = true
                return  // 클로저 종료
            }
        }
        lastTransitionReason = reason
        lastTransitionTime = now
        
        // lock 획득 시도
        // ...
    }
    
    if shouldSkipDebounce {
        return false  // debounce로 스킵
    }
    
    return acquired
}
```

### 수정 2: `cleanupForLifecycle`에 re-entrancy guard 추가
**위치**: `ios/Runner/NativeCamera.swift:6199-6216`

**변경 내용**:
- `isCleaningForLifecycle` 플래그를 사용하여 중복 호출 방지
- 이미 cleanup 중이면 즉시 return하고 completion만 호출 (lock 해제를 위해)

**코드**:
```swift
private func cleanupForLifecycle(...) {
    // re-entrancy guard
    if isCleaningForLifecycle {
        let skipMsg = "[Native] ⏸️ cleanupForLifecycle: SKIPPED - already cleaning..."
        // completion 호출하여 lock 해제
        if let completion = completion {
            completion()
        }
        return
    }
    
    isCleaningForLifecycle = true
    defer {
        isCleaningForLifecycle = false
    }
    // ... 나머지 로직
}
```

### 수정 3: `cleanupForLifecycle`의 safe teardown 경로에 중복 실행 방지 추가
**위치**: `ios/Runner/NativeCamera.swift:6232-6300`

**변경 내용**:
- permission denied일 때 safe teardown 수행 전에 이미 정리되었는지 확인
- 세션이 이미 중지되었고 outputs가 이미 제거되었으면 스킵

**코드**:
```swift
sessionQueue.async { [weak self] in
    guard let self else { return }
    
    // 중복 실행 방지: 이미 정리되었는지 확인
    let sessionRunningBefore = self.session.isRunning
    let hasOutputsBefore = (self.photoOutput != nil || self.videoDataOutput != nil)
    
    if !sessionRunningBefore && !hasOutputsBefore && shouldTearDownOutputs {
        // 이미 정리되었으면 스킵
        return
    }
    
    // 세션이 실행 중일 때만 중지
    if sessionRunningBefore {
        self.session.stopRunning()
    }
    
    // outputs가 있을 때만 제거
    if shouldTearDownOutputs && hasOutputsBefore {
        // outputs 제거
    }
}
```

### 수정 4: `onAppDidEnterBackground`에 상세 로그 추가
**위치**: `ios/Runner/NativeCamera.swift:6925-6970`

**변경 내용**:
- debounce 체크와 플래그 체크에 상세 로그 추가
- elapsed time과 threshold를 명시하여 디버깅 용이

### 수정 5: `applyLifecycleTransition`에서 전역 debounce 사용
**위치**: `ios/Runner/NativeCamera.swift:6532-6548`

**변경 내용**:
- 인스턴스별 debounce 제거
- `GlobalLifecycleManager.tryAcquire(reason:)`에서 전역 debounce 처리

## 예상 동작 (수정 후)

### 시나리오: 권한 거부 → 설정으로 이동 → 권한 토글

1. **권한 거부 상태** (`permission denied`)
2. **"설정으로 이동" 버튼 클릭**
   - `setSkipAutoReinit(true)` 호출
   - `openSettings()` 호출
3. **앱이 background로 전환**
   - `onAppDidEnterBackground()` 첫 호출
     - 동기화된 debounce 체크 → 통과
     - 플래그 설정 → `isProcessingDidEnterBackground = true`
     - `applyLifecycleTransition(reason: "didEnterBackground", action: "teardown")` 호출
   - `onAppDidEnterBackground()` 두 번째 호출 (0.5초 이내)
     - 동기화된 debounce 체크 → **스킵 로그 출력** → 즉시 return ✅
   - `applyLifecycleTransition` 첫 호출
     - `GlobalLifecycleManager.tryAcquire(reason: "didEnterBackground")` 호출
     - 전역 debounce 체크 → 통과
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
     - 세션 중지 + outputs 제거
   - `cleanupForLifecycle` 두 번째 호출 (중복 호출)
     - `isCleaningForLifecycle` 체크 → `true` → **스킵 로그 출력** → 즉시 return ✅
4. **설정 화면에서 권한 토글**
   - iOS가 백그라운드 앱의 카메라 세션을 확인
   - **수정 후**: 세션이 이미 정리되어 있음 → SIGKILL 없음 ✅

## 변경 파일

1. **`ios/Runner/NativeCamera.swift`**
   - `GlobalLifecycleManager.tryAcquire`: reason 파라미터 추가, 전역 debounce 추가
   - `cleanupForLifecycle`: re-entrancy guard 추가, 중복 실행 방지 추가
   - `onAppDidEnterBackground`: 상세 로그 추가
   - `applyLifecycleTransition`: 전역 debounce 사용

## 테스트 체크리스트

### 필수 테스트
- [ ] 권한 거부 → 설정으로 이동 → 권한 토글 → SIGKILL 없이 정상 동작
- [ ] 로그에서 다음 메시지 확인:
  - `[Native] ⏸️ onAppDidEnterBackground: SKIPPED - debounce`
  - `[GlobalLifecycleManager] tryAcquire: SKIPPED - duplicate reason within debounce interval`
  - `[Native] ⏸️ applyLifecycleTransition: SKIPPED - cleanup already in progress`
  - `[Native] ⏸️ cleanupForLifecycle: SKIPPED - already cleaning`
  - `[Native] ⏸️ SAFE TEARDOWN: Already cleaned - session not running and outputs already removed, SKIPPING`
- [ ] `SAFE TEARDOWN: Outputs removed`가 한 번만 출력되는지 확인
- [ ] `applyLifecycleTransition START/END`가 중복되지 않는지 확인

### 로그 확인 사항
- [ ] debounce 로그가 정상적으로 출력되는지 확인
- [ ] 전역 lock이 제대로 작동하여 `tryAcquire`가 한 번만 성공하는지 확인
- [ ] `cleanupForLifecycle`의 re-entrancy guard가 작동하는지 확인
- [ ] SIGKILL 없이 정상 종료 확인

## 핵심 개선 사항

1. **전역 debounce**: 모든 인스턴스가 공유하는 전역 debounce로 동일 reason의 중복 호출 방지
2. **Re-entrancy guard**: `cleanupForLifecycle`에 플래그 기반 보호 추가
3. **중복 실행 방지**: safe teardown 경로에서 이미 정리되었는지 확인
4. **상세 로그**: 디버깅을 위한 상세 로그 추가
