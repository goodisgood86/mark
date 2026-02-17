# defer 제거 및 completion에서 플래그 리셋 수정

## 문제 발견
로그 분석 결과, `applyLifecycleTransition`의 `defer` 블록이 `cleanupForLifecycle` 완료 전에 실행되어 플래그가 일찍 리셋되는 문제가 있었습니다.

### 발견된 문제
1. **870-871**: 같은 `didEnterBackground`인데도 `GlobalLifecycleManager.tryAcquire`가 여러 번 성공
2. **875-901**: `applyLifecycleTransition START`가 10회 이상 호출 (인스턴스 guard가 작동하지 않음)
3. **878-879, 902-905**: `isCleaningForLifecycle=true`임에도 `cleanupForLifecycle`이 여러 번 호출됨

### 원인
- `defer` 블록이 함수 반환 시점에 실행되어, `cleanupForLifecycle`이 비동기로 실행되는 동안 플래그가 false로 리셋됨
- 다른 호출이 다시 들어올 수 있게 되어 중복 호출 발생

## 수정 내용

### 1. defer 제거
- `applyLifecycleTransition`에서 `defer` 블록 제거
- `cleanupForLifecycle` completion에서만 플래그 리셋

### 2. completion에서 플래그 리셋
```swift
cleanupForLifecycle(reason: reason, shouldTearDownOutputs: shouldTearDownOutputs) { [weak self] in
    // ... END 로그 출력 ...
    
    // 🔥🔥🔥 핵심: cleanupForLifecycle 완료 후 플래그 리셋 (비동기 완료 후에만 리셋)
    self.applyLifecycleTransitionLock.lock()
    self.isApplyingLifecycleTransition = false
    self.applyLifecycleTransitionLock.unlock()
    
    // release 호출
    GlobalLifecycleManager.shared.release()
}
```

### 3. 전역 lock 획득 실패 시 플래그 리셋
- `GlobalLifecycleManager.shared.tryAcquire` 실패 시에도 플래그를 리셋하도록 수정

## 예상되는 개선 효과

### 수정 전
```
[Native] 🔄 applyLifecycleTransition START: ... (1회)
[Native] 🔄 applyLifecycleTransition START: ... (2회) ← defer로 플래그가 리셋되어 또 호출됨
[Native] 🔄 applyLifecycleTransition START: ... (3회)
...
```

### 수정 후 (예상)
```
[Native] 🔄 applyLifecycleTransition START: ... (1회만)
[Native] ⏸️ applyLifecycleTransition: SKIPPED - already applying transition (나머지 호출)
[Native] 🧹 cleanupForLifecycle START: ... (1회만)
[Native] 🧹 cleanupForLifecycle END: ... (1회만)
[Native] 🔄 applyLifecycleTransition END: ... (1회만, completion에서)
```

## 테스트 시나리오
1. 권한 거부 → "설정으로 이동" 클릭
2. 설정 화면에서 권한 토글
3. 앱 복귀

### 확인 사항
- [ ] `applyLifecycleTransition START`가 1회만 호출되는지 확인
- [ ] `SKIPPED - already applying transition` 로그가 중복 호출 시 출력되는지 확인
- [ ] `END` 로그가 `cleanupForLifecycle` 완료 후에만 출력되는지 확인
- [ ] 플래그가 completion에서만 리셋되는지 확인
- [ ] SIGKILL이 발생하지 않는지 확인
