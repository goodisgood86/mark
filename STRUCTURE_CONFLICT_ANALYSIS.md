# 기존 구조와의 충돌 분석

## 발견된 잠재적 충돌 및 해결 방안

### ⚠️ 1. cleanupForLifecycle과 stopSession()의 관계

**현재 상황**:

- `stopSession()`: Flutter에서 명시적으로 호출 가능한 공개 함수
- `cleanupForLifecycle()`: 라이프사이클/인터럽션에서만 사용하는 내부 함수

**충돌 가능성**: 낮음

- `stopSession()`은 `isRunningOperationInProgress` 체크 후 세션만 중지
- `cleanupForLifecycle()`은 flags까지 포함한 포괄적 정리
- 목적이 다르므로 충돌 없음

**권장**: 현재 구조 유지

### ⚠️ 2. cleanupForLifecycle과 dispose()의 관계

**현재 상황**:

- `dispose()`: Flutter에서 뷰컨트롤러 해제 시 호출
- `cleanupForLifecycle()`: 라이프사이클 이벤트에서 호출

**충돌 가능성**: 낮음

- `dispose()`는 완전한 리소스 해제 (delegate nil, registry 제거 포함)
- `cleanupForLifecycle()`은 라이프사이클 이벤트 대응
- 목적이 다르므로 충돌 없음

**권장**: 현재 구조 유지

### ⚠️ 3. cleanupForLifecycle이 초기화 중간에 호출되는 경우

**현재 상황**:

- `cleanupForLifecycle()`은 `isRunningOperationInProgress`를 체크하지 않고 무조건 false로 설정
- 초기화 중간에 라이프사이클 이벤트 발생 시 cleanup이 호출될 수 있음

**충돌 가능성**: 중간

- 초기화 중간에 cleanup이 호출되면 `isRunningOperationInProgress`가 false로 설정되어 초기화가 중단될 수 있음
- 하지만 이는 의도된 동작일 수 있음 (라이프사이클 이벤트가 우선)

**권장**:

- 현재 구조 유지 (라이프사이클 이벤트가 우선순위가 높음)
- 초기화 completion handler에서 이미 정리되었는지 확인하는 로직 추가 고려

### ⚠️ 4. ensureHealthyOrReinit과 recoverIfNeeded의 관계

**현재 상황**:

- `ensureHealthyOrReinit()`: health 체크 후 필요 시 `initializeIfNeeded` 호출
- `recoverIfNeeded()`: `cameraState == .error`일 때만 `initialize()` 호출

**충돌 가능성**: 낮음

- `ensureHealthyOrReinit()`는 `cameraState = .error` 설정 후 `initializeIfNeeded` 호출
- `recoverIfNeeded()`는 `cameraState == .error`일 때만 동작
- 순차적으로 동작하므로 충돌 없음

**권장**: 현재 구조 유지

### ⚠️ 5. ensureHealthyOrReinit과 restartSession의 관계

**현재 상황**:

- `ensureHealthyOrReinit()`: health 체크 후 필요 시 full re-init
- `restartSession()`: 세션만 재시작 (Flutter에서 명시적 호출)

**충돌 가능성**: 낮음

- 목적이 다름 (health 체크 vs 단순 재시작)
- 충돌 없음

**권장**: 현재 구조 유지

### ⚠️ 6. switchCamera 등 다른 함수에서의 세션 제어

**현재 상황**:

- `switchCamera`, `switchToUltraWide`, `switchToWide` 등에서 직접 `session.startRunning()` 호출
- `cleanupForLifecycle()`과는 다른 컨텍스트에서 호출

**충돌 가능성**: 낮음

- 카메라 전환은 정상적인 동작 흐름
- 라이프사이클 이벤트와는 별개
- 충돌 없음

**권장**: 현재 구조 유지

## 최종 결론

### ✅ 충돌 없음

모든 함수들이 서로 다른 목적과 컨텍스트에서 사용되므로 충돌이 없습니다:

1. **라이프사이클 핸들러**: `cleanupForLifecycle()` 사용
2. **인터럽션 핸들러**: `cleanupForLifecycle()` 사용
3. **런타임 에러 핸들러**: `cleanupForLifecycle()` 사용
4. **복귀 핸들러**: `ensureHealthyOrReinit()` 사용
5. **Flutter 명시적 호출**: `stopSession()`, `dispose()`, `restartSession()`, `recoverIfNeeded()` 등 기존 함수 사용
6. **카메라 전환**: 기존 로직 유지

### ⚠️ 주의사항

1. **초기화 중간 cleanup**: 라이프사이클 이벤트가 초기화 중간에 발생하면 cleanup이 호출되어 초기화가 중단될 수 있음. 이는 의도된 동작 (라이프사이클 우선).

2. **중복 호출 방지**: `cleanupForLifecycle()`이 여러 핸들러에서 동시에 호출될 수 있지만, `sessionQueue`에서 순차적으로 처리되므로 문제 없음.

3. **Flutter 연동**: `ensureHealthyOrReinit()`에서 `cameraState = .error` 설정 후 `initializeIfNeeded`를 호출하지만, Flutter의 상태 변경 감지도 필요할 수 있음.

## 권장 사항

1. ✅ 현재 구조 유지
2. ✅ 실기기 테스트로 검증
3. ⚠️ 초기화 completion handler에서 cleanup 여부 확인 로직 추가 고려 (선택사항)
