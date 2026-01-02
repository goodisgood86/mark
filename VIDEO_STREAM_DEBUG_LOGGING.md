# 비디오 스트림 디버깅 로그 추가 완료

## 🔍 문제 분석 결과

### 현재 상태
- ✅ 네이티브 카메라로 정상 진입 (useMock: false, nativeInit: true)
- ✅ 세션 실행 중 (sessionRunning: true)
- ❌ 비디오 스트림 미수신:
  - `videoConnected: false`
  - `connectionEnabled: false`
  - `sampleBufferCount: 0`
  - `previewFrameCount: 0`

### 원인 추정
- AVCaptureVideoDataOutput의 connection이 제대로 설정되지 않음
- 또는 connection이 disabled 상태
- 또는 delegate가 제대로 설정되지 않음

## ✅ 추가된 로깅

### 1. 세션 구성 시 상세 로깅

#### Step 2: Video Input 추가
- `canAddInput(videoInput)` 체크 및 로깅
- 추가 성공/실패 로깅

#### Step 2.5: Video Data Output 추가
- `canAddOutput(videoDataOutput)` 체크 및 로깅
- `sampleBufferDelegate` 설정 여부 확인
- 추가 성공/실패 로깅

#### Step 2.6: Video Connection 설정
- `connection(with: .video)` nil 체크
- `connection.isEnabled` 상태 확인
- `connection.isActive` 상태 확인
- `isVideoMirroringSupported` 확인
- `isVideoOrientationSupported` 확인
- connection이 disabled면 자동으로 enable

### 2. 세션 시작 후 상태 확인

#### Step 4: Session Start
- `startRunning()` 호출 후 0.2초 뒤 상태 확인
- `session.isRunning` 확인
- connection 상태 재확인

#### 초기화 완료 후 1초 뒤
- `sampleBufferCount` 확인
- 0이면 경고 로그 및 connection 상태 재확인
- delegate 설정 여부 확인

### 3. captureOutput Delegate 호출 확인

- 30프레임마다 로그 출력:
  - `sampleBufferCount` 값
  - `connection.isActive` 상태
  - `connection.isEnabled` 상태
- `CMSampleBufferGetImageBuffer` 실패 시 로그

### 4. switchCamera 재구성 로깅

#### 재구성 전 상태
- `hasVideoOutput` 확인
- `hasVideoOutputInSession` 확인
- connection 상태 확인

#### 재구성 후 상태
- `commitConfiguration` 후 connection 상태 확인
- `startRunning` 후 connection 상태 확인 (0.1초 뒤)

### 5. getState() 개선

다음 정보 추가:
- `videoConnected`: connection 존재 여부
- `connectionEnabled`: connection 활성화 여부
- `previewLayerHasSession`: output이 세션에 있는지
- `sampleBufferCount`: 수신된 sample buffer 개수

## 📋 로그 확인 방법

### 디버그 오버레이에서 확인
1. 앱 실행 후 왼쪽 상단 디버그 오버레이 확인
2. 최근 로그에서 다음 키워드 확인:
   - `[Native] 📷 Step 2.5`: Video Data Output 추가
   - `[Native] 📷 Step 2.6`: Connection 설정
   - `[Native] ✅ captureOutput called`: sampleBuffer 수신 확인
   - `[Native] ⚠️ WARNING: No sampleBuffer received`: 스트림 미수신 경고

### 복사 기능 사용
1. 디버그 오버레이의 "복사" 버튼 클릭
2. 클립보드에 복사된 로그 확인
3. 다음 정보 확인:
   - `canAddOutput(videoDataOutput)`: true/false
   - `connection.isEnabled`: true/false
   - `connection.isActive`: true/false
   - `sampleBufferCount`: 0이면 문제

## 🎯 예상되는 문제 시나리오

### 시나리오 1: canAddOutput이 false
```
[Native] 📷 canAddOutput(videoDataOutput): false
[Native] ❌ Cannot add videoDataOutput to session
```
→ 세션 설정 문제 또는 output이 이미 추가됨

### 시나리오 2: connection이 nil
```
[Native] ❌ CRITICAL: videoOutput.connection(with: .video) is nil!
```
→ output이 세션에 제대로 추가되지 않음

### 시나리오 3: connection.isEnabled가 false
```
[Native] ⚠️ WARNING: connection.isEnabled is false! Enabling...
```
→ 자동으로 enable하지만, 이후에도 false면 문제

### 시나리오 4: sampleBuffer가 전혀 안 옴
```
[Native] ⚠️ WARNING: No sampleBuffer received after 1 second! sampleBufferCount=0
```
→ connection이 활성화되지 않았거나 delegate가 설정되지 않음

## 🔧 다음 단계

1. **앱 실행 후 로그 확인**
   - 디버그 오버레이에서 위의 로그 확인
   - 특히 `canAddOutput`, `connection.isEnabled`, `sampleBufferCount` 확인

2. **문제 발견 시**
   - 로그를 복사하여 분석
   - 어떤 단계에서 실패했는지 확인
   - connection이 nil인지, disabled인지 확인

3. **추가 수정 필요 시**
   - 로그 결과를 바탕으로 추가 수정 진행

---

**모든 로그는 디버그 오버레이에 표시되며, "복사" 버튼으로 전체 로그를 복사할 수 있습니다.**

