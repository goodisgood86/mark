# applyLifecycleTransition 중복 호출 방지 수정

## 문제 분석
로그 분석 결과, `applyLifecycleTransition`이 여러 번 동시에 호출되어 SIGKILL이 발생하는 문제가 확인되었습니다.

### 발견된 문제
1. **961-962**: 같은 reason (`didEnterBackground`)에서도 `GlobalLifecycleManager.tryAcquire`가 여러 번 성공
2. **965-972, 980-983**: `applyLifecycleTransition START`가 10회 이상 호출
3. **973-986**: `cleanupForLifecycle: FORCING teardown`이 여러 번 출력
4. **977-997**: `cleanupForLifecycle START`가 여러 번 호출
5. **1010-1019**: 결국 SIGKILL 발생

### 원인
- `applyLifecycleTransition`에 인스턴스별 re-entrancy guard가 없어서, 여러 호출이 동시에 진입
- `END` 로그가 `cleanupForLifecycle` 완료 전에 출력되어, 여러 호출이 동시에 통과하는 것으로 보임
- `GlobalLifecycleManager`의 전역 lock만으로는 인스턴스별 중복 호출을 완전히 막을 수 없음

## 수정 내용

### 1. 인스턴스별 re-entrancy guard 추가
```swift
// 🔥🔥🔥 인스턴스별 applyLifecycleTransition 중복 호출 방지 플래그
private var isApplyingLifecycleTransition = false
private let applyLifecycleTransitionLock = NSLock()
```

### 2. applyLifecycleTransition 함수 수정
- 전역 lock 획득 전에 인스턴스별 플래그 체크
- `defer` 블록에서 플래그 리셋 (정상 완료 및 에러 시 모두)
- `END` 로그를 `cleanupForLifecycle` completion으로 이동 (비동기 완료 후에만 출력)

### 3. 로그 순서 개선
- `END` 로그가 `cleanupForLifecycle` 완료 후에만 출력되도록 수정
- `release` 로그가 `END` 로그 이후에 출력되도록 수정

## 예상되는 개선 효과

### 수정 전
```
[Native] 🔄 applyLifecycleTransition START: ... (10회 이상)
[Native] 🔄 applyLifecycleTransition END: ... (10회 이상, cleanupForLifecycle 완료 전)
[Native] 🧹 cleanupForLifecycle START: ... (10회 이상)
[Native] 🧹 cleanupForLifecycle END: ... (10회 이상)
```

### 수정 후 (예상)
```
[Native] 🔄 applyLifecycleTransition START: ... (1회만)
[Native] ⏸️ applyLifecycleTransition: SKIPPED - already applying transition (나머지 호출)
[Native] 🧹 cleanupForLifecycle START: ... (1회만)
[Native] 🧹 cleanupForLifecycle END: ... (1회만)
[Native] 🔄 applyLifecycleTransition END: ... (1회만, cleanupForLifecycle 완료 후)
[Native] 🔓 applyLifecycleTransition release: ... (1회만)
```

## 테스트 시나리오
1. 권한 거부 → "설정으로 이동" 클릭
2. 설정 화면에서 권한 토글
3. 앱 복귀

### 확인 사항
- [ ] `applyLifecycleTransition START`가 1회만 호출되는지 확인
- [ ] `SKIPPED - already applying transition` 로그가 중복 호출 시 출력되는지 확인
- [ ] `cleanupForLifecycle START/END`가 1회만 호출되는지 확인
- [ ] `END` 로그가 `cleanupForLifecycle` 완료 후에만 출력되는지 확인
- [ ] SIGKILL이 발생하지 않는지 확인
