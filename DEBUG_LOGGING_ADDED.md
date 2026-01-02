# 디버그 로깅 추가 완료

## 추가된 로깅

### 1. `_initCameraPipeline()` 진입 시
- `Platform.isIOS`
- `isSimulator`
- `_shouldUseMockCamera`
- `_isCameraReady`
- `_cameraEngine.isCameraReady`
- `_cameraEngine.useMockCamera`
- `cameras.length`

**위치**: `lib/pages/home_page.dart:1137`
**로그 형식**: `[InitPipeline] 📷 ENTRY: Platform.isIOS=true, isSimulator=false, ...`

### 2. `CameraEngine.initialize()` 내부
각 단계별 상태 로깅:

#### 시작 시 (INIT START)
- `position`
- `aspectRatio`
- `viewId`
- `isCameraReady`
- `useMockCamera`

**위치**: `lib/services/camera_engine.dart:131`
**로그 형식**: `[CameraEngine] 📷 INIT START: position=back, aspectRatio=0.5625, viewId=123, ...`

#### 성공 시 (INIT SUCCESS)
- `isInitialized`
- `isCameraReady`
- `useMockCamera`
- `viewId`
- `aspectRatio`
- `previewSize`

**위치**: `lib/services/camera_engine.dart:163`
**로그 형식**: `[CameraEngine] ✅ INIT SUCCESS: isInitialized=true, isCameraReady=true, ...`

#### 실패 시 (INIT FAILED)
- `error`
- `viewId`
- `isCameraReady`
- `useMockCamera`

**위치**: `lib/services/camera_engine.dart:191`
**로그 형식**: `[CameraEngine] ❌ INIT FAILED: error=..., viewId=123, ...`

#### Finally 시 (INIT FINALLY)
- `isInitializing`
- `isInitialized`
- `isCameraReady`
- `useMockCamera`
- `shouldUseMockCamera`
- `viewId`

**위치**: `lib/services/camera_engine.dart:235`
**로그 형식**: `[CameraEngine] 🔚 INIT FINALLY: isInitializing=false, isInitialized=true, ...`

### 3. iOS 네이티브 `initialize()` 메서드
각 단계별 상세 로깅:

#### 진입 시
- `position`
- `authorizationStatus` (권한 상태)

**위치**: `ios/Runner/NativeCamera.swift:94`
**로그 형식**: `[Native] 📷 INIT START: position=back, authorizationStatus=3`

#### Step 1: findDevice
- 디바이스 찾기 성공/실패
- 찾은 디바이스 이름

**위치**: `ios/Runner/NativeCamera.swift:179`
**로그 형식**: 
- 성공: `[Native] ✅ Step 1 SUCCESS: Device found - Back Camera`
- 실패: `[Native] ❌ Step 1 FAILED: No camera device found`

#### Step 2: AVCaptureDeviceInput 생성
- AVCaptureDeviceInput 생성 성공/실패

**위치**: `ios/Runner/NativeCamera.swift:191`
**로그 형식**: `[Native] ✅ Step 2 SUCCESS: AVCaptureDeviceInput created`

#### Step 3: Session 구성
- 세션 구성 완료

**위치**: `ios/Runner/NativeCamera.swift:242`
**로그 형식**: `[Native] ✅ Step 3 SUCCESS: Session configured`

#### Step 4: Session 시작
- `startRunning()` 호출
- `session.isRunning` 상태 확인

**위치**: `ios/Runner/NativeCamera.swift:245-248`
**로그 형식**: 
- 호출: `[Native] 📷 Step 4: Starting session (startRunning)`
- 확인: `[Native] 📷 Step 4 CHECK: session.isRunning=true`
- 성공: `[Native] ✅ Step 4 SUCCESS: Camera initialized: ...`
- 실패: `[Native] ❌ Step 4 FAILED: Session failed to start...`

## 디버그 오버레이 개선

### 표시되는 정보
1. **기본 상태**
   - `canUseCamera`
   - `nativeInit`
   - `useMock`
   - `shouldUseMock`
   - `isInitializing`
   - `previewSource`
   - `initError` (에러 발생 시)

2. **최근 로그 (최대 5개)**
   - 최근 디버그 로그를 실시간으로 표시
   - 60자로 제한하여 표시

### 복사 기능
- "복사" 버튼 클릭 시 전체 디버그 정보를 클립보드에 복사
- 최대 50개 로그 포함
- 타임스탬프 및 모든 상태 정보 포함

### 표시 위치
- 화면 왼쪽 상단 (left: 8, top: 8)
- 반투명 검은 배경으로 가독성 확보

## 로그 전달 경로

### Flutter → 디버그 오버레이
1. `debugPrint()` → 콘솔 출력
2. `_addDebugLog()` → 디버그 오버레이에 표시

### iOS 네이티브 → Flutter → 디버그 오버레이
1. iOS `log()` 메서드 → `onDebugLog` 콜백 호출
2. `NativeCameraController.addDebugLogListener()` → Flutter 리스너 호출
3. `_addDebugLog()` → 디버그 오버레이에 표시

## 사용 방법

1. **디버그 오버레이 확인**
   - 앱 실행 시 왼쪽 상단에 디버그 정보 박스 표시
   - 실시간 상태 확인 가능

2. **로그 확인**
   - 디버그 오버레이 하단에 최근 5개 로그 표시
   - 전체 로그는 "복사" 버튼으로 확인

3. **문제 진단**
   - 각 단계별 로그를 통해 어느 단계에서 실패했는지 확인
   - 권한 상태, viewId, 세션 상태 등을 종합적으로 확인

## 주의사항

- 디버그 오버레이는 `kEnableCameraDebugOverlay = true`로 설정되어 있음
- 프로덕션 빌드 전에는 `false`로 변경 권장
- 로그가 많아지면 성능에 영향을 줄 수 있으므로 필요시 로그 레벨 조정

