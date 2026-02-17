# initializeIfNeeded 인스턴스 생명주기 보호 수정

## 문제점 분석

사용자 로그 분석 결과:

- `initializeIfNeededStep = "in_session_queue"`는 설정되지만, 이후 로그들이 누락됨
- `instancePtr`가 계속 변경되어 인스턴스가 재생성되고 있음
- `sessionQueue.async` 블록 내에서 인스턴스가 해제될 가능성

## 적용된 수정사항

### 1. Strong Reference 보호

- `sessionQueue.async` 블록 내에서 `guard let self` 후 `let strongSelf = self` 추가
- 초기화 완료까지 인스턴스가 해제되지 않도록 보장

### 2. 인스턴스 포인터 로깅 강화

- 모든 주요 로그에 `instancePtr` 추가하여 인스턴스 추적 가능
- `step` 설정 후 즉시 검증 로그 추가

### 3. 로깅 순서 보장

- `initializeIfNeededStep` 설정 직후 검증 로그 추가
- 각 단계마다 `instancePtr` 포함하여 인스턴스 일관성 확인

## 수정된 코드 위치

**파일**: `ios/Runner/NativeCamera.swift`
**함수**: `initializeIfNeeded(position:aspectRatio:)`
**라인**: 828-1115

### 주요 변경사항:

1. **Strong Reference 추가** (라인 859):

```swift
guard let self else { ... }
let strongSelf = self  // 🔥 인스턴스 생명주기 보호
```

2. **인스턴스 포인터 로깅** (라인 863-871):

```swift
let instancePtr = Unmanaged.passUnretained(strongSelf).toOpaque()
let stepSetMsg = "[Native] 🔥🔥🔥 initializeIfNeeded: step set to 'in_session_queue', instancePtr=\(instancePtr), proceeding..."
```

3. **모든 `self.` 참조를 `strongSelf.`로 변경**:
   - 인스턴스가 초기화 완료까지 유지되도록 보장
   - 모든 로그에 `instancePtr` 추가

## 예상 효과

1. **인스턴스 생명주기 보호**: 초기화 중 인스턴스가 해제되지 않음
2. **로그 추적 개선**: `instancePtr`로 인스턴스 일관성 확인 가능
3. **디버깅 용이성**: 각 단계에서 인스턴스 상태 추적 가능

## 검증 방법

1. 앱 실행 후 디버그 로그 확인:

   - `instancePtr`가 동일한 값으로 유지되는지 확인
   - `step set to 'in_session_queue'` 이후 로그들이 순차적으로 나타나는지 확인
   - `HEALTH CHECK` 로그가 나타나는지 확인

2. 프리뷰 상태 확인:
   - `hasFirstFrame=true`가 되는지 확인
   - `sessionRunning=true`, `videoConnected=true` 확인
   - 검은/핑크 화면이 아닌 실제 카메라 프리뷰가 나타나는지 확인

## 다음 단계

1. 실기기에서 테스트하여 로그 확인
2. `instancePtr` 일관성 확인
3. 프리뷰 정상 표시 여부 확인
4. 추가 문제 발견 시 로그 기반 진단
