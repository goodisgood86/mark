# 프리뷰 및 촬영 기능 구조 검증 결과

## ✅ 프리뷰 표시 구조 검증

### 1. 프리뷰 렌더링 파이프라인 체크리스트

#### ✅ 세션 실행
- [x] `session.startRunning()` 호출
- [x] `onAppForeground()`에서 세션 재시작
- [x] `resumeSession()`에서 세션 재시작
- [x] `onAppWillResignActive()`에서 세션 유지 (프리뷰만 일시 중지)

#### ✅ SampleBuffer 수신
- [x] `captureOutput(_:didOutput:from:)` 구현
- [x] 첫 프레임 수신 시 `hasFirstFrame = true` 설정
- [x] sampleBuffer 카운터로 수신 상태 추적

#### ✅ 이미지 처리
- [x] `filterEngine.applyToPreview()` 호출
- [x] 이미지 extent 유효성 검증 (isInfinite, isFinite, isNaN)
- [x] 유효하지 않은 이미지 early return

#### ✅ PreviewView 상태 관리
- [x] `isPaused = false` 자동 복구
- [x] `isHidden = false` 자동 복구
- [x] `window` 존재 여부 확인
- [x] `display(image:)` 호출 전 상태 검증

#### ✅ 렌더링
- [x] `display(image:)`에서 `currentImage` 설정
- [x] `draw(in:)`에서 `currentImage` 렌더링
- [x] `currentDrawable` nil 체크 및 복구
- [x] `ciContext` nil 체크

#### ✅ 상태 동기화 (Flutter)
- [x] `_pollDebugState()` 폴링
- [x] 세션 복구 시 상태 즉시 업데이트
- [x] `canUseCamera` 정확한 계산

### 2. 프리뷰 표시 실패 가능 경로

**경로 1: 세션이 중지됨**
- 증상: sampleBuffer가 오지 않음
- 감지: `sampleBufferCount == 0`
- 해결: ✅ 세션 재시작 로직 구현

**경로 2: previewView.isPaused = true**
- 증상: `draw(in:)`이 호출되지 않음
- 감지: `drawCallCount == 0`
- 해결: ✅ 자동으로 `false` 설정

**경로 3: previewView.window == nil**
- 증상: 렌더링은 되지만 화면에 표시되지 않음
- 감지: 로그로 확인 가능
- 해결: ⚠️ 로그만 출력, 복구 로직 없음

**경로 4: 이미지 extent가 유효하지 않음**
- 증상: `display(image:)`가 호출되지 않음
- 감지: `displayCallCount == 0`
- 해결: ✅ 유효성 검증 및 early return

**경로 5: Flutter 오버레이가 계속 표시됨**
- 증상: 검은색 오버레이가 프리뷰를 가림
- 원인: `canUseCamera=false` 상태가 업데이트되지 않음
- 해결: ✅ 세션 복구 시 상태 즉시 업데이트

## ✅ 촬영 크래시 방지 구조 검증

### 1. 촬영 가드 체크리스트

#### ✅ 메인 스레드 검증
- [x] `Thread.isMainThread` 체크

#### ✅ 재초기화 중 차단
- [x] `isRunningOperationInProgress` 체크 (메인 스레드)
- [x] `isRunningOperationInProgress` 체크 (sessionQueue)

#### ✅ 세션 상태 검증
- [x] `session.isRunning` 체크 (메인 스레드)
- [x] `session.isRunning` 체크 (sessionQueue)

#### ✅ 세션 객체 유효성
- [x] `photoOutput` nil 체크
- [x] `photoOutput` 세션 포함 여부
- [x] `videoDevice` nil 및 `isConnected` 체크
- [x] `videoInput` nil 및 세션 포함 여부 체크

#### ✅ 연결 상태
- [x] `videoConnection` nil 체크
- [x] `videoConnection.isEnabled` 체크
- [x] `videoConnection.isActive` 체크

#### ✅ 프리뷰 상태
- [x] `hasFirstFrame` 체크
- [x] `previewView.hasCurrentImage()` 체크
- [x] `isPinkFallback` 체크

#### ✅ 중복 촬영 방지
- [x] `isCapturingPhoto` 체크

#### ✅ 인터럽션 및 에러
- [x] `isSessionInterrupted` 체크
- [x] `sessionRuntimeError` 체크

#### ✅ Delegate 안정성
- [x] `strongSelf` 사용
- [x] `try-catch` 블록

### 2. 촬영 크래시 가능 경로 차단

**경로 1: sessionRunning=false에서 촬영**
- 차단: ✅ 메인 스레드 + sessionQueue 이중 체크

**경로 2: 재초기화 중 촬영**
- 차단: ✅ `isRunningOperationInProgress` 체크

**경로 3: 세션 객체가 유효하지 않음**
- 차단: ✅ `photoOutput`, `videoDevice`, `videoInput` 검증

**경로 4: delegate가 해제됨**
- 차단: ✅ `strongSelf` 사용

**경로 5: 레이스 컨디션**
- 차단: ✅ 메인 스레드와 sessionQueue 모두에서 검증

## 🔍 발견된 잠재적 이슈

### 이슈 1: previewView.window == nil 처리
- **위치**: `captureOutput`에서 display 호출 전
- **문제**: window가 nil이면 렌더링은 되지만 화면에 표시되지 않음
- **현재**: 로그만 출력
- **권장**: 재시도 로직 또는 상태 복구 메커니즘 추가

### 이슈 2: 세션 재시작 타이밍
- **위치**: `onAppForeground()`에서 0.3초 지연
- **문제**: 세션이 완전히 시작되기 전에 프레임이 올 수 있음
- **현재**: 지연 후 연결 상태 확인
- **권장**: 연결 상태 폴링으로 변경 고려

### 이슈 3: 중복 videoInput 체크
- **위치**: sessionQueue에서 videoInput 체크가 중복됨
- **문제**: 코드 중복 (기능적 문제는 없음)
- **현재**: 두 번 체크됨
- **권장**: 중복 제거 (✅ 이미 수정됨)

## 📋 테스트 체크리스트

### 프리뷰 테스트
- [ ] 앱 실행 후 프리뷰 표시 확인
- [ ] 홈 버튼으로 백그라운드 이동 후 복귀 시 프리뷰 복구 확인
- [ ] 앱 잠금 후 해제 시 프리뷰 복구 확인
- [ ] 카메라 전환 시 프리뷰 유지 확인
- [ ] 라이프사이클 변경 중 프리뷰 일시 중지/재개 확인

### 촬영 테스트
- [ ] 정상 상태에서 촬영 성공 확인
- [ ] 세션 중지 상태에서 촬영 시도 → 에러 표시, 크래시 없음
- [ ] 재초기화 중 촬영 시도 → 에러 표시, 크래시 없음
- [ ] 연속 빠른 촬영 → 중복 방지 작동
- [ ] 촬영 중 앱 전환 → 촬영 취소 확인

### 오버레이 테스트
- [ ] 세션 복구 후 검은색 오버레이 제거 확인
- [ ] 세션 중지 시 검은색 오버레이 표시 확인
- [ ] 핑크 배경이 보이지 않는지 확인

