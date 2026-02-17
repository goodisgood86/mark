# 기존 구조와의 충돌 최종 검토

## 검토 완료 사항

### ✅ 1. cleanupForLifecycle과 기존 함수들의 관계

| 함수                | 목적                                     | 충돌 여부           |
| ------------------- | ---------------------------------------- | ------------------- |
| `stopSession()`     | Flutter 명시적 호출 (세션만 중지)        | ❌ 없음 - 목적 다름 |
| `dispose()`         | Flutter 명시적 호출 (완전한 리소스 해제) | ❌ 없음 - 목적 다름 |
| `restartSession()`  | Flutter 명시적 호출 (세션 재시작)        | ❌ 없음 - 목적 다름 |
| `recoverIfNeeded()` | 에러 복구 (FSM 기반)                     | ❌ 없음 - 목적 다름 |
| `switchCamera()`    | 카메라 전환 (정상 동작)                  | ❌ 없음 - 목적 다름 |

**결론**: 모든 함수들이 서로 다른 목적과 컨텍스트에서 사용되므로 충돌 없음.

### ✅ 2. 초기화 중간 cleanup 호출 대응

**문제**: 초기화 중간에 라이프사이클 이벤트로 `cleanupForLifecycle`이 호출되면 `isRunningOperationInProgress`가 false로 설정되어 초기화가 중단될 수 있음.

**해결**:

- `initializeIfNeeded`의 completion handler에서 cleanup 여부 확인 로직 추가
- cleanup으로 인해 flags가 이미 정리되었으면 중복 정리 방지
- cleanup으로 인해 `cameraState`가 `.idle`로 변경되었으면 상태 변경 스킵

**코드**:

```swift
// cleanup 여부 확인
if self.isRunningOperationInProgress {
    self.isRunningOperationInProgress = false
    self.lastOperationStartedAt = nil
} else {
    // 이미 cleanup으로 정리되었으면 로그만 출력
    self.log("[Native] ⚠️ initialize completion: flags already cleared by cleanup")
}

// cameraState 확인
if self.cameraState != .idle {
    self.cameraState = .ready
} else {
    self.log("[Native] ⚠️ initialize completion: cameraState is .idle (cleanup called), skipping state change")
}
```

### ✅ 3. ensureHealthyOrReinit과 기존 함수들의 관계

| 함수                 | 목적                          | 충돌 여부                |
| -------------------- | ----------------------------- | ------------------------ |
| `ensureConfigured()` | 기존 health 체크 (deprecated) | ❌ 없음 - 점진적 교체 중 |
| `recoverIfNeeded()`  | 에러 복구                     | ❌ 없음 - 순차적 동작    |
| `restartSession()`   | 세션 재시작                   | ❌ 없음 - 목적 다름      |

**결론**: 충돌 없음. `ensureHealthyOrReinit`이 `ensureConfigured`를 점진적으로 대체 중.

### ✅ 4. sessionQueue 동시성 안전성

**확인 사항**:

- ✅ 모든 cleanup은 `sessionQueue`에서 수행
- ✅ 모든 세션 제어는 `sessionQueue`에서 수행
- ✅ `sessionQueue`는 serial queue이므로 순차적 처리 보장

**결론**: 동시성 안전성 보장됨.

### ✅ 5. dispose()와 cleanupForLifecycle의 중복 가능성

**분석**:

- `dispose()`: Flutter에서 뷰컨트롤러 해제 시 호출 (delegate nil, registry 제거 포함)
- `cleanupForLifecycle()`: 라이프사이클 이벤트 대응 (flags/state/session/outputs 정리)

**결론**:

- 목적이 다르므로 충돌 없음
- `dispose()`는 완전한 리소스 해제, `cleanupForLifecycle()`은 라이프사이클 대응
- 둘 다 호출되어도 문제 없음 (idempotent)

## 최종 결론

### ✅ 충돌 없음

모든 함수들이 서로 다른 목적과 컨텍스트에서 사용되므로 충돌이 없습니다:

1. **라이프사이클/인터럽션 핸들러**: `cleanupForLifecycle()` 사용
2. **복귀 핸들러**: `ensureHealthyOrReinit()` 사용
3. **Flutter 명시적 호출**: 기존 함수들 (`stopSession()`, `dispose()`, `restartSession()`, `recoverIfNeeded()`) 사용
4. **카메라 전환**: 기존 로직 유지
5. **초기화 completion**: cleanup 여부 확인 로직 추가

### ✅ 안전성 보장

1. **동시성 안전**: 모든 세션 제어는 `sessionQueue`에서 순차 처리
2. **중복 호출 안전**: cleanup 함수들이 idempotent하게 구현
3. **초기화 중단 대응**: completion handler에서 cleanup 여부 확인

### ⚠️ 주의사항

1. **Flutter 연동**: `ensureHealthyOrReinit()`에서 `cameraState = .error` 설정 후 `initializeIfNeeded`를 호출하지만, Flutter의 상태 변경 감지도 필요할 수 있음.

2. **타이밍**: 라이프사이클 이벤트가 초기화 중간에 발생하면 cleanup이 호출되어 초기화가 중단될 수 있음. 이는 의도된 동작 (라이프사이클 우선).

## 권장 사항

1. ✅ **현재 구조 유지** - 충돌 없음
2. ✅ **실기기 테스트** - 모든 시나리오 검증
3. ✅ **모니터링** - 디버그 로그로 동작 확인
