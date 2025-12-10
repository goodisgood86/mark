# 프리뷰 및 촬영 기능 구조 검증 결과

## ✅ 프리뷰가 나오는 구조 검증

### 1. 세션 실행 확인
- ✅ `session.isRunning` 체크
- ✅ `onAppForeground()`에서 세션 재시작 로직 구현
- ✅ `resumeSession()`에서 세션 재시작 로직 구현
- ✅ `onAppWillResignActive()`에서 세션 유지 (프리뷰만 일시 중지)

### 2. SampleBuffer 수신 확인
- ✅ `captureOutput(_:didOutput:from:)`에서 sampleBuffer 수신
- ✅ 첫 프레임 수신 시 `hasFirstFrame = true` 설정
- ✅ sampleBuffer 카운터로 수신 상태 추적

### 3. 이미지 필터링 및 유효성 검증
- ✅ `filterEngine.applyToPreview()` 호출
- ✅ 이미지 extent 유효성 검증 (isInfinite, isFinite, isNaN 체크)
- ✅ 유효하지 않은 이미지인 경우 early return

### 4. PreviewView 상태 확인
- ✅ `previewView.isPaused` 자동 복구 로직 추가
- ✅ `previewView.isHidden` 자동 복구 로직 추가
- ✅ `previewView.window` 존재 여부 확인
- ✅ `previewView.display(image:)` 호출 전 상태 검증

### 5. 렌더링 파이프라인
- ✅ `display(image:)`에서 `currentImage` 설정
- ✅ `draw(in:)`에서 `currentImage` 렌더링
- ✅ `isPaused = false`일 때만 렌더링
- ✅ `currentDrawable` 및 `ciContext` 유효성 검증

### 6. 상태 동기화 (Flutter)
- ✅ `_pollDebugState()`에서 네이티브 상태 폴링
- ✅ 세션 복구 시 상태 즉시 업데이트
- ✅ `canUseCamera` 계산 로직 정확성

### ⚠️ 잠재적 문제점
1. **세션 재시작 타이밍**: `onAppForeground()`에서 0.3초 지연 후 연결 상태 확인
   - 세션이 완전히 시작되기 전에 프레임이 올 수 있음
   - 해결: 연결 상태 확인 지연 시간 조정 필요할 수 있음

2. **previewView.window == nil**: 뷰가 window hierarchy에 없으면 렌더링 실패
   - 로그만 출력하고 복구 로직 없음
   - 해결: window가 nil인 경우 재시도 로직 추가 고려

## ✅ 촬영 시 크래시가 안 나는 구조 검증

### 1. 메인 스레드 검증
- ✅ `Thread.isMainThread` 체크

### 2. 재초기화 중 차단
- ✅ `isRunningOperationInProgress` 체크 (메인 스레드)
- ✅ `isRunningOperationInProgress` 체크 (sessionQueue)

### 3. 세션 상태 검증
- ✅ `session.isRunning` 체크 (메인 스레드)
- ✅ `session.isRunning` 체크 (sessionQueue)

### 4. 세션 객체 유효성 검증
- ✅ `photoOutput` nil 체크
- ✅ `photoOutput` 세션 포함 여부 체크
- ✅ `videoDevice` nil 및 `isConnected` 체크
- ✅ `videoInput` nil 및 세션 포함 여부 체크

### 5. 연결 상태 검증
- ✅ `videoConnection` nil 체크
- ✅ `videoConnection.isEnabled` 체크
- ✅ `videoConnection.isActive` 체크

### 6. 프리뷰 상태 검증
- ✅ `hasFirstFrame` 체크
- ✅ `previewView.hasCurrentImage()` 체크
- ✅ `isPinkFallback` 체크

### 7. 중복 촬영 방지
- ✅ `isCapturingPhoto` 체크

### 8. 세션 인터럽션 및 에러 처리
- ✅ `isSessionInterrupted` 체크
- ✅ `sessionRuntimeError` 체크

### 9. Delegate 안정성
- ✅ `strongSelf` 사용하여 delegate 해제 방지
- ✅ `try-catch` 블록으로 예외 처리

### ⚠️ 잠재적 문제점
1. **레이스 컨디션**: 메인 스레드에서 검증 후 sessionQueue에서 실제 호출 사이 시간차
   - 해결: sessionQueue에서도 모든 검증 수행 (✅ 이미 구현됨)

2. **세션 재구성 타이밍**: `isRunningOperationInProgress`가 false인데 실제로는 재구성 중일 수 있음
   - 해결: sessionQueue에서 추가 검증 (✅ 이미 구현됨)

## 📊 테스트 시나리오

### 시나리오 1: 정상 프리뷰 표시
1. 앱 실행
2. 세션 시작 확인
3. sampleBuffer 수신 확인
4. display(image:) 호출 확인
5. draw(in:) 호출 확인
6. renderSuccessCount 증가 확인

**예상 결과**: 프리뷰가 정상적으로 표시됨

### 시나리오 2: 라이프사이클 변경 후 프리뷰 복구
1. 앱 실행
2. 홈 버튼 눌러서 백그라운드로 이동
3. 앱 다시 활성화
4. 세션 재시작 확인
5. 프리뷰 복구 확인

**예상 결과**: 프리뷰가 복구되어 표시됨

### 시나리오 3: 정상 촬영
1. 프리뷰 표시 확인
2. 촬영 버튼 클릭
3. 모든 guard 절 통과 확인
4. capturePhotoWithSettings 호출 확인
5. photoOutput:didFinishProcessingPhoto 호출 확인

**예상 결과**: 사진이 정상적으로 촬영됨

### 시나리오 4: 세션 중지 상태에서 촬영 시도
1. 세션 중지 상태 유도
2. 촬영 버튼 클릭
3. guard 절에서 차단 확인

**예상 결과**: 에러 메시지 표시, 크래시 없음

### 시나리오 5: 재초기화 중 촬영 시도
1. 재초기화 시작
2. 촬영 버튼 클릭
3. isRunningOperationInProgress 체크에서 차단 확인

**예상 결과**: "Camera is being reinitialized" 에러 표시, 크래시 없음

### 시나리오 6: 세션 복구 후 오버레이 제거
1. 세션이 중지된 상태에서 오버레이 표시
2. 세션 복구
3. _pollDebugState()에서 상태 업데이트
4. canUseCamera = true로 변경
5. 오버레이 제거 확인

**예상 결과**: 오버레이가 즉시 제거됨

## 🔍 추가 검증이 필요한 부분

1. **실제 기기에서 테스트 필요**:
   - 세션 재시작 타이밍
   - 프리뷰 렌더링 성능
   - 메모리 사용량

2. **에지 케이스 테스트 필요**:
   - 매우 빠른 연속 촬영
   - 카메라 전환 중 촬영
   - 메모리 부족 상황

3. **로그 분석**:
   - 디버그 로그를 통해 실제 실행 경로 추적
   - guard 절 통과/실패 패턴 분석

