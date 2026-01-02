# 카메라 프리뷰 흐름 시뮬레이션 및 문제점 분석

## 로그 분석 결과

### 발견된 문제점

1. **`step=in_session_queue`는 설정되지만 `Entered sessionQueue` 로그가 없음**

   - `sessionQueue.async` 블록이 실행되지 않았거나 로그가 누락됨
   - `guard let self`에서 실패했을 가능성

2. **`HEALTH CHECK` 로그가 없음**

   - 초기화가 진행되지 않음
   - `sessionQueue.async` 블록이 실행되지 않아서 health check까지 도달하지 못함

3. **`instancePtr`이 계속 바뀜**

   - VC가 재생성되고 있음
   - `stableInstancePtr`은 사용 중이지만 VC 재생성 시 새 값이 생성됨

4. **`photoOutputIsNil=true`, `sessionRunning=false`, `hasFirstFrame=false`**
   - 초기화가 완료되지 않음
   - `_performInitialize`까지 도달하지 못함

## 전체 흐름 시뮬레이션

### 1. 앱 시작 → Flutter UI 로드

```
[Lifecycle] App lifecycle changed: AppLifecycleState.resumed
[PreviewBind] onCreated: Requesting native initializeIfNeeded()
```

### 2. Flutter → Native: requestInitializeIfNeeded 호출

```
[Native] 📷 initializeIfNeeded CALLED: viewId=0, position=back
[Native] 🔥 About to call targetCameraVC.initializeIfNeeded
```

### 3. Native: initializeIfNeeded() 호출

```
[Native] 🔥🔥🔥 initializeIfNeeded() STARTED: position=back
[Native] 🔥🔥🔥 initializeIfNeeded: About to call sessionQueue.async
[Native] 🔥🔥🔥 initializeIfNeeded: sessionQueue check - queue exists=YES
```

### 4. sessionQueue.async 블록 실행 (예상)

```
[Native] 🔥🔥🔥 initializeIfNeeded: sessionQueue.async BLOCK ENTERED
[Native] 🔥🔥🔥 initializeIfNeeded: step set to 'in_session_queue', proceeding...
[Native] 🔥🔥🔥 initializeIfNeeded: Entered sessionQueue (step=in_session_queue)
[Native] 🔥🔥🔥 BEFORE HEALTH CHECK: isRunningOperationInProgress=false, cameraState=idle
[Native] 🔥🔥🔥 initializeIfNeeded HEALTH CHECK: sessionRunning=false, hasPhotoOutput=false, ...
[Native] 🔥🔥🔥 HEALTH CHECK FAILED: isHealthy=false, proceeding to initialize
```

### 5. initialize() 호출 (예상)

```
[Native] 🔥🔥🔥 initializeIfNeeded: Passed early return checks, proceeding to initialize
[Native] 🔥🔥🔥 About to call initialize(position=back, aspectRatio=nil)
[Native] 🔥🔥🔥 CALLING initialize() NOW
[Native] 🔥🔥🔥 initialize() STARTED: position=back
```

### 6. \_performInitialize() 호출 (예상)

```
[Native] 🔥🔥🔥 _performInitialize STARTED: position=back
[Native] 🔥🔥🔥 _performInitialize: About to enter sessionQueue.async
[Native] 🔥🔥🔥 _performInitialize: Entered sessionQueue.async
```

### 7. startRunning() 호출 (예상)

```
[Native] 🔥🔥🔥 Step 4: Starting session (startRunning)
[Native] 🔥🔥🔥 Step 4: startRunning() CALLED, session.isRunning=true
```

### 8. 첫 프레임 수신 (예상)

```
[Native] ✅ First sampleBuffer received! sampleBufferCount=1
[Native] ✅ hasFirstFrame set to true, firstFrameRetryCount reset to 0
[FSM] ✅ First frame received: state → ready
```

## 실제 로그에서 누락된 부분

1. ❌ `[Native] 🔥🔥🔥 initializeIfNeeded: About to call sessionQueue.async` - 없음
2. ❌ `[Native] 🔥🔥🔥 initializeIfNeeded: sessionQueue.async BLOCK ENTERED` - 없음
3. ❌ `[Native] 🔥🔥🔥 initializeIfNeeded: Entered sessionQueue` - 없음
4. ❌ `[Native] 🔥🔥🔥 BEFORE HEALTH CHECK` - 없음
5. ❌ `[Native] 🔥🔥🔥 initializeIfNeeded HEALTH CHECK` - 없음

## 문제 원인 추정

1. **`sessionQueue.async` 블록이 실행되지 않음**

   - `sessionQueue`가 nil이거나 제대로 초기화되지 않음
   - VC가 deallocated되어서 `guard let self`에서 실패
   - 큐가 막혀있어서 블록이 실행되지 않음

2. **VC가 계속 재생성됨**

   - `instancePtr`이 계속 바뀜
   - 라이프사이클 이벤트로 인한 VC 재생성

3. **초기화가 진행되지 않음**
   - `sessionQueue.async` 블록이 실행되지 않아서 초기화가 시작되지 않음

## 해결 방안

1. **`sessionQueue.async` 블록 실행 확인**

   - `sessionQueue` 초기화 확인
   - `guard let self` 실패 시 로그 출력
   - 블록 진입 직후 로그 출력 (self 없이도)

2. **VC 재생성 방지**

   - `stableInstancePtr` 사용 확인
   - VC 생명주기 관리 개선

3. **초기화 강제 실행**
   - `sessionQueue.async` 블록이 실행되지 않을 경우 대체 경로 제공
   - 타임아웃 후 재시도 로직 추가
