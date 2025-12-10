# 프리뷰 및 촬영 기능 구조 검증 결과

## ✅ 프리뷰 표시 구조 검증

### 프리뷰 렌더링 파이프라인 (전체 흐름)

```
1. 세션 시작
   ├─ session.startRunning()
   └─ onAppForeground() / resumeSession()

2. SampleBuffer 수신
   ├─ captureOutput(_:didOutput:from:)
   ├─ sampleBufferCount++
   └─ hasFirstFrame = true

3. 이미지 필터링
   ├─ filterEngine.applyToPreview()
   ├─ extent 유효성 검증
   └─ 유효한 경우에만 진행

4. PreviewView 상태 확인 및 복구
   ├─ isPaused 체크 → false로 설정
   ├─ isHidden 체크 → false로 설정
   └─ window 존재 여부 확인

5. Display 호출
   ├─ previewView.display(image:)
   ├─ currentImage 설정
   └─ hasNewImage = true

6. 렌더링
   ├─ draw(in:) 호출
   ├─ currentImage 읽기
   ├─ currentDrawable 확인
   ├─ ciContext.render()
   └─ renderSuccessCount++
```

### ✅ 검증 완료 항목

1. **세션 실행 보장**
   - `onAppForeground()`: 세션 재시작 + 연결 상태 확인
   - `resumeSession()`: 세션 재시작 + 연결 상태 확인
   - `onAppWillResignActive()`: 세션 유지 (프리뷰만 일시 중지)

2. **SampleBuffer 수신 보장**
   - `captureOutput`에서 sampleBuffer 수신 확인
   - 첫 프레임 수신 시 `hasFirstFrame = true`

3. **이미지 유효성 검증**
   - extent 유효성 검증 (isInfinite, isFinite, isNaN)
   - 유효하지 않은 이미지 early return

4. **PreviewView 상태 복구**
   - `isPaused = true` → 자동으로 `false` 설정
   - `isHidden = true` → 자동으로 `false` 설정
   - `window == nil` → 로그 출력

5. **렌더링 파이프라인**
   - `display(image:)`에서 `currentImage` 설정
   - `draw(in:)`에서 렌더링
   - `currentDrawable` nil 체크 및 복구

6. **Flutter 상태 동기화**
   - `_pollDebugState()`에서 상태 폴링
   - 세션 복구 시 즉시 업데이트
   - `canUseCamera` 정확한 계산

### ⚠️ 잠재적 문제점

1. **previewView.window == nil**
   - 문제: 뷰가 window hierarchy에 없으면 렌더링은 되지만 화면에 표시되지 않음
   - 현재: 로그만 출력
   - 영향: 프리뷰가 표시되지 않을 수 있음
   - 우선순위: 중간

2. **세션 재시작 타이밍**
   - 문제: 0.3초 지연 후 연결 상태 확인
   - 현재: 지연 후 확인
   - 영향: 세션이 완전히 시작되기 전에 프레임이 올 수 있음
   - 우선순위: 낮음

## ✅ 촬영 크래시 방지 구조 검증

### 촬영 가드 체인 (전체 흐름)

```
1. 메인 스레드 검증
   └─ Thread.isMainThread

2. 재초기화 중 차단
   ├─ isRunningOperationInProgress (메인)
   └─ isRunningOperationInProgress (sessionQueue)

3. 세션 상태 검증
   ├─ session.isRunning (메인)
   └─ session.isRunning (sessionQueue)

4. 세션 객체 유효성
   ├─ photoOutput nil 체크
   ├─ photoOutput 세션 포함 여부
   ├─ videoDevice nil 및 isConnected
   └─ videoInput nil 및 세션 포함 여부

5. 연결 상태 검증
   ├─ videoConnection nil 체크
   ├─ videoConnection.isEnabled
   └─ videoConnection.isActive

6. 프리뷰 상태 검증
   ├─ hasFirstFrame
   ├─ previewView.hasCurrentImage()
   └─ isPinkFallback

7. 중복 촬영 방지
   └─ isCapturingPhoto

8. 인터럽션 및 에러
   ├─ isSessionInterrupted
   └─ sessionRuntimeError

9. Delegate 안정성
   ├─ strongSelf 사용
   └─ try-catch 블록
```

### ✅ 검증 완료 항목

1. **이중 검증 (메인 + sessionQueue)**
   - 메인 스레드에서 1차 검증
   - sessionQueue에서 2차 검증
   - 레이스 컨디션 방지

2. **재초기화 중 차단**
   - `isRunningOperationInProgress` 체크
   - 메인과 sessionQueue 모두에서 체크

3. **세션 객체 유효성**
   - 모든 객체 nil 체크
   - 세션 포함 여부 확인
   - 연결 상태 확인

4. **Delegate 안정성**
   - `strongSelf`로 해제 방지
   - `try-catch`로 예외 처리

### ⚠️ 잠재적 문제점

1. **레이스 컨디션 (극히 드묾)**
   - 문제: 메인에서 검증 후 sessionQueue에서 호출 사이에 세션 상태 변경
   - 현재: sessionQueue에서도 검증 수행
   - 영향: 거의 없음
   - 우선순위: 매우 낮음

## 📊 최종 결론

### 프리뷰 표시 구조: ✅ 안정적
- 모든 주요 경로에서 상태 복구 로직 구현
- 세션 재시작 보장
- PreviewView 상태 자동 복구
- Flutter 상태 동기화 정확

### 촬영 크래시 방지: ✅ 안정적
- 다층 방어 구조 구현
- 메인 + sessionQueue 이중 검증
- 모든 세션 객체 유효성 검증
- Delegate 안정성 보장

### 권장 사항
1. 실제 기기에서 테스트 필수
2. 다양한 라이프사이클 시나리오 테스트
3. 빠른 연속 촬영 테스트
4. 메모리 부족 상황 테스트

