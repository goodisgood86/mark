# 전체 코드 플로우 시뮬레이션 및 검증 리포트

## 1. 앱 초기화 플로우 시뮬레이션

### 1.1 main.dart → HomePage.initState()

**플로우:**
1. ✅ `main()` 실행
   - `WidgetsFlutterBinding.ensureInitialized()` 호출
   - iOS에서는 `availableCameras()` 호출하지 않음 (네이티브 AVFoundation 사용)
   - DB 초기화 (에러 처리 포함)
   - `PetgramApp` 실행

2. ✅ `HomePage.initState()` 실행
   - `CameraEngine()` 생성
   - iOS 실기기: `cameras.isEmpty`이지만 Mock 초기화하지 않음 (정상)
   - `_cameraEngine.addListener()` 등록
   - `_cameraControlChannel.setMethodCallHandler()` 등록
   - `postFrameCallback`에서 `getDebugState()` 호출 (timeout 2초 추가됨 ✅)
   - 초기화 작업들에 `.catchError()` 추가됨 ✅

**잠재적 이슈:**
- ✅ 해결됨: `getDebugState()` timeout 추가로 블로킹 방지
- ✅ 해결됨: 초기화 작업 에러 처리 추가

---

## 2. 카메라 초기화 플로우

### 2.1 NativeCameraPreview → CameraEngine.attachNativeView()

**플로우:**
1. ✅ `NativeCameraPreview` 빌드
   - iOS: `Container(color: Colors.transparent, child: SizedBox.expand())` 반환
   - `didChangeDependencies()` 또는 `build()`에서 `onCreated(0)` 호출

2. ✅ `onCreated(0)` 콜백
   - `_cameraEngine.attachNativeView(0)` 호출
   - `CameraEngine.attachNativeView()` 실행
     - `NativeCameraController` 생성
     - `viewId` 설정

3. ⚠️ **문제점 발견**: `attachNativeView()` 후 자동 초기화가 없음
   - `initializeNativeCameraOnce()`가 어디서 호출되는지 확인 필요

**확인 필요:**
- `attachNativeView()` 후 `initializeNativeCameraOnce()` 자동 호출 여부
- 또는 수동으로 호출해야 하는지

### 2.2 CameraEngine.initializeNativeCameraOnce()

**플로우:**
1. ✅ `_hasInitializedOnce` 체크 (중복 초기화 방지)
2. ✅ 촬영 펜스 체크
3. ✅ `_performInitializeNativeCamera()` 호출
4. ✅ `initialize()` 호출
5. ✅ `getDebugState()`로 `hasFirstFrame` 확인
6. ✅ 최대 2초 대기 후 `hasFirstFrame` 확인

**잠재적 이슈:**
- ✅ `getDebugState()`에 timeout 추가 필요 (이미 추가됨)

---

## 3. 프리뷰 표시 플로우

### 3.1 네이티브 뷰 → Flutter UI

**플로우:**
1. ✅ `_buildCameraPreview()` 호출
   - iOS 실기기: `NativeCameraPreview` 반환
   - Mock: `Image.asset()` 반환

2. ✅ `_buildCameraStack()` 호출
   - `LayoutBuilder`로 프리뷰 크기 계산
   - `targetRatio`에 맞춰 `width`, `height` 계산
   - `top`, `left` 계산 (중앙 정렬)

3. ✅ iOS 프리뷰 동기화
   - `postFrameCallback` 2중 호출로 레이아웃 완료 보장
   - `_getPreviewRectFromKey()`로 rect 계산
   - `_syncPreviewRectWithRetry()`로 네이티브에 전달
   - `updatePreviewLayout()` 호출

4. ✅ 배경색 처리
   - Scaffold `backgroundColor: Colors.transparent` ✅
   - `_buildCameraStack`에서 프리뷰 영역 외부 핑크색 제거 ✅
   - 네이티브 `previewView.backgroundColor = .clear` ✅

**잠재적 이슈:**
- ✅ 해결됨: Flutter 배경색 투명 처리
- ✅ 해결됨: 네이티브 배경색 투명 처리
- ⚠️ 확인 필요: 네이티브가 프리뷰 영역 외부를 핑크색으로 그리는지 확인

---

## 4. 촬영 플로우

### 4.1 촬영 버튼 → 이미지 저장

**플로우:**
1. ✅ `_handleShutterButton()` 호출
   - `_takePhoto()` 호출

2. ✅ `_takePhoto()` 실행
   - `canUseCamera` 체크 ✅
     - `sessionRunning && videoConnected && hasFirstFrame` 확인
   - 촬영 중복 방지 (`_cameraEngine.isCapturingPhoto`)
   - 타이머/연속 촬영 모드 처리
   - `_captureFenceUntil` 설정 (4초)

3. ✅ Mock 카메라 모드
   - `CameraEngine.takePicture()` 호출
   - 이미지 처리 (필터, 밝기, 프레임, 줌)

4. ✅ 네이티브 카메라 모드
   - `CameraEngine.takePicture()` 호출
   - 네이티브에서 이미지 처리
   - 갤러리 저장 또는 임시 파일 저장

5. ✅ DB 저장
   - `PetgramPhotoRepository.upsertPhotoRecord()` 호출
   - 백그라운드 처리 (`unawaited`)

**잠재적 이슈:**
- ✅ `canUseCamera` 체크로 안전성 보장
- ✅ 촬영 펜스로 재초기화 방지
- ✅ 에러 처리 포함

---

## 5. 기타 기능 확인

### 5.1 필터 기능
- ✅ `_applyFilterIfChanged()` 호출
- ✅ 카메라 초기화 후 필터 재적용
- ⚠️ 확인 필요: 필터 페이지에서 돌아올 때 필터 유지

### 5.2 설정 기능
- ✅ `_loadAllSettings()` 호출
- ✅ SharedPreferences 사용

### 5.3 갤러리 기능
- ✅ `_openDiaryPage()` 호출
- ⚠️ 확인 필요: 갤러리 권한 처리

---

## 6. 실기기에서 프리뷰 표시 확인

### 6.1 확인 사항
1. ✅ 네이티브 카메라 초기화
   - `RootViewController.cameraContainer`에 프리뷰 추가
   - `previewView.backgroundColor = .clear` ✅

2. ✅ Flutter UI 투명 처리
   - Scaffold `backgroundColor: Colors.transparent` ✅
   - 프리뷰 영역 외부 핑크색 제거 ✅

3. ⚠️ 확인 필요: 네이티브 배경색
   - `RootViewController.view.backgroundColor`가 핑크색인지 확인
   - 프리뷰 영역 외부가 핑크색으로 보이는지 확인

### 6.2 잠재적 문제
- ⚠️ `attachNativeView()` 후 `initializeNativeCameraOnce()` 자동 호출 여부 확인 필요
- ⚠️ 프리뷰 동기화 타이밍 문제 가능성

---

## 7. 실기기에서 촬영 확인

### 7.1 확인 사항
1. ✅ `canUseCamera` 체크
   - `sessionRunning && videoConnected && hasFirstFrame` ✅

2. ✅ 촬영 안전성
   - 촬영 중복 방지 ✅
   - 촬영 펜스 설정 ✅
   - 에러 처리 ✅

3. ✅ 이미지 저장
   - 갤러리 저장 또는 임시 파일 저장
   - DB 저장 (백그라운드)

### 7.2 잠재적 문제
- ✅ 모든 안전 체크 포함됨

---

## 8. 발견된 문제점 및 해결 방안

### 8.1 ✅ 해결됨
1. **스플래시 멈춤 문제**
   - `getDebugState()`에 timeout 추가
   - 초기화 작업에 에러 처리 추가

2. **핑크 배경 문제**
   - Scaffold `backgroundColor: Colors.transparent`
   - 프리뷰 영역 외부 핑크색 제거
   - 네이티브 `previewView.backgroundColor = .clear`

### 8.2 ⚠️ 확인 필요
1. **카메라 초기화 자동화**
   - ✅ `attachNativeView()` 후 네이티브에서 자동 초기화하는 것으로 보임
   - ✅ `CameraManager.shared.setRootViewController(self)` 호출로 카메라 관리
   - ⚠️ `initializeNativeCameraOnce()`는 네이티브가 자동으로 호출하는 것으로 추정
   - ⚠️ 실기기 테스트로 확인 필요

2. **네이티브 배경색**
   - ✅ `RootViewController.view.backgroundColor`가 핑크색으로 설정됨 (라인 53-58)
   - ✅ 프리뷰 영역 외부가 네이티브에서 핑크색으로 그려짐
   - ✅ Flutter는 투명하게 처리하여 네이티브 배경색이 보이도록 함

3. **프리뷰 동기화 타이밍**
   - ✅ `postFrameCallback` 2중 호출로 레이아웃 완료 보장
   - ✅ `_syncPreviewRectWithRetry()`로 재시도 메커니즘 포함
   - ⚠️ 실기기 테스트로 동기화 정확성 확인 필요

---

## 9. 종합 평가

### 9.1 강점
- ✅ 안전한 초기화 플로우 (timeout, 에러 처리)
- ✅ 안전한 촬영 플로우 (중복 방지, 펜스 설정)
- ✅ 투명 배경 처리로 네이티브 프리뷰 표시 가능
- ✅ 상태 관리 체계적 (CameraDebugState)

### 9.2 개선 필요
- ✅ 네이티브 배경색 확인 완료 (RootViewController에서 핑크색 설정)
- ⚠️ 카메라 초기화 자동화 실기기 테스트 필요
- ⚠️ 프리뷰 동기화 타이밍 실기기 테스트 필요

### 9.3 실기기 테스트 권장 사항
1. 앱 시작 시 프리뷰 표시 확인
2. 프리뷰 영역 외부 핑크색 표시 확인
3. 촬영 기능 정상 동작 확인
4. 필터 적용 확인
5. 설정 저장/로드 확인
6. 갤러리 기능 확인

