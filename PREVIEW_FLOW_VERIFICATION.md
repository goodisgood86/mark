# 카메라 프리뷰 흐름 검증 시뮬레이션

## 수정 사항 요약

### 핵심 수정

1. **인스턴스 생명주기 보호**: `sessionQueue.async` 블록 내에서 `strongSelf` 사용
2. **로깅 강화**: 모든 로그에 `instancePtr` 추가하여 인스턴스 추적
3. **단계별 검증**: `step` 설정 후 즉시 검증 로그 출력

## 예상 흐름 시뮬레이션

### 1. 앱 시작 → NativeCameraPreview 생성

```
[Flutter] NativeCameraPreview.onCreated() 호출
  → viewId=0 전달
  → _cameraEngine.attachNativeView(0)
  → _cameraEngine.requestInitializeIfNeeded()
```

### 2. 네이티브 initializeIfNeeded 호출

```
[Native] 🔥🔥🔥 initializeIfNeeded() STARTED: position=back, aspectRatio=nil
[Native] 🔥🔥🔥 initializeIfNeeded: About to call sessionQueue.async
[Native] 🔥🔥🔥 initializeIfNeeded: sessionQueue check - queue exists=YES
```

### 3. sessionQueue.async 블록 진입 (수정 후)

```
[Native] 🔥🔥🔥 initializeIfNeeded: sessionQueue.async BLOCK ENTERED
[Native] 🔥🔥🔥 initializeIfNeeded: step set to 'in_session_queue', instancePtr=0x1234567890, proceeding...
[Native] 🔥🔥🔥 initializeIfNeeded: VERIFY step='in_session_queue', instancePtr=0x1234567890
[Native] 🔥🔥🔥 initializeIfNeeded: Entered sessionQueue (step=in_session_queue), instancePtr=0x1234567890
[Native] 🔥🔥🔥 BEFORE HEALTH CHECK: isRunningOperationInProgress=false, cameraState=idle, instancePtr=0x1234567890
[Native] 🔥🔥🔥 initializeIfNeeded HEALTH CHECK: sessionRunning=false, hasPhotoOutput=false, hasVideoDataOutput=false, ...
```

### 4. Health Check 실패 → 초기화 진행

```
[Native] 🔥🔥🔥 HEALTH CHECK FAILED: isHealthy=false, proceeding to initialize, instancePtr=0x1234567890
[Native] 🔥🔥🔥 initializeIfNeeded: Passed early return checks, proceeding to initialize, instancePtr=0x1234567890
[Native] 🔥🔥🔥 About to call initialize(position=back, aspectRatio=nil), instancePtr=0x1234567890
[Native] 🔥🔥🔥 CALLING initialize() NOW, instancePtr=0x1234567890
```

### 5. initialize() 실행

```
[Native] 📷 INIT START: position=back, authorizationStatus=3
[Native] 🔥🔥🔥 _performInitialize: Entered sessionQueue.async
[Native] 📷 Step 1: Finding device for position=back
[Native] ✅ Step 1 SUCCESS: Device found - Back Camera
[Native] 📷 Step 2: Creating AVCaptureDeviceInput
[Native] ✅ Step 2 SUCCESS: AVCaptureDeviceInput created
...
```

### 6. 첫 프레임 수신

```
[Native] ✅✅✅ captureOutput CALLED! This means delegate is working!
[Native] ✅ First frame received! sampleBufferCount=1
```

### 7. 초기화 완료

```
[Native] 🔥🔥🔥 initialize() COMPLETION: SUCCESS, instancePtr=0x1234567890
```

## 검증 포인트

### ✅ 인스턴스 일관성

- 모든 로그에서 `instancePtr`가 동일한 값으로 유지되어야 함
- `instancePtr`가 변경되면 인스턴스가 재생성된 것

### ✅ 로그 순서

- `step set to 'in_session_queue'` → `VERIFY step` → `Entered sessionQueue` 순서로 나타나야 함
- `BEFORE HEALTH CHECK` → `HEALTH CHECK` 순서로 나타나야 함

### ✅ Health Check 결과

- 초기 상태: `isHealthy=false` (정상)
- 초기화 후: `isHealthy=true` (목표)

### ✅ 프리뷰 상태

- `hasFirstFrame=true`
- `sessionRunning=true`
- `videoConnected=true`
- `photoOutputIsNil=false`

## 문제 진단 가이드

### 문제 1: instancePtr가 계속 변경됨

**원인**: 인스턴스가 재생성되고 있음
**해결**: `strongSelf` 보호가 제대로 작동하는지 확인

### 문제 2: `step set to 'in_session_queue'` 이후 로그 누락

**원인**:

- 인스턴스가 해제됨 (수정 후 해결 예상)
- `sessionQueue`가 실행되지 않음
- 로그가 캡처되지 않음

**확인 사항**:

- `VERIFY step` 로그가 나타나는지 확인
- `Entered sessionQueue` 로그가 나타나는지 확인
- `instancePtr`가 동일한지 확인

### 문제 3: Health Check 통과하지 못함

**원인**:

- `session.isRunning=false`
- `photoOutput=nil` 또는 `videoDataOutput=nil`
- `connection.isEnabled=false`

**해결**: 초기화가 완료될 때까지 대기

## 다음 단계

1. **실기기 테스트**: 수정된 코드로 빌드 후 실행
2. **로그 수집**: 디버그 오버레이에서 로그 확인
3. **인스턴스 추적**: `instancePtr` 일관성 확인
4. **프리뷰 확인**: 검은/핑크 화면이 아닌 실제 프리뷰 표시 여부 확인
