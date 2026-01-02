# Petgram 카메라 구조 재설계 계획

## 📋 현재 구조 분석

### Flutter에서 중복 계산하는 상태들

#### 1. 카메라 상태 플래그 (제거 필요)
- `canUseCamera`: 복잡한 조건 체크 (sessionRunning && videoConnected && hasFirstFrame && !isPinkFallback)
- `_nativeInit`: 네이티브 초기화 완료 여부
- `_isReady`: 카메라 준비 완료 여부
- `sessionRunning`: 세션 실행 여부 (네이티브에서 받지만 Flutter에서도 계산)
- `videoConnected`: 비디오 연결 여부 (네이티브에서 받지만 Flutter에서도 계산)
- `hasFirstFrame`: 첫 프레임 수신 여부 (네이티브에서 받지만 Flutter에서도 계산)
- `isPinkFallback`: 핑크 fallback 상태 (네이티브에서 받지만 Flutter에서도 계산)

#### 2. 프리뷰 관련 계산 (제거 필요)
- Aspect ratio 계산 (`lib/pages/home_page.dart`)
- Preview size 계산
- Crop rect 계산
- Preview container 크기 계산

#### 3. 상태 동기화 로직 (제거 필요)
- `getDebugState()` 호출 및 상태 업데이트
- `_pollDebugState()` 주기적 폴링
- Flutter와 네이티브 상태 불일치 해결 로직

### 현재 파일 구조

#### Flutter
- `lib/services/camera_engine.dart` (1605 lines) - 상태 계산 로직 집중
- `lib/pages/home_page.dart` (9639 lines) - UI + 카메라 로직 혼재
- `lib/camera/native_camera_controller.dart` (796 lines)
- `lib/camera/native_camera_preview.dart`
- `lib/camera/native_camera_interface.dart`

#### iOS 네이티브
- `ios/Runner/NativeCamera.swift` (7427 lines) - 모든 카메라 로직
- `ios/Runner/CameraManager.swift`
- `ios/Runner/CameraPreviewView.swift`
- `ios/Runner/CameraSessionManager.swift`
- `ios/Runner/FilterEngine.swift`
- `ios/Runner/FilterPipeline.swift`

---

## 🎯 타겟 아키텍처

### 1. iOS 네이티브 모듈

#### 파일 구조
```
ios/Runner/Camera/
├── PetgramCameraEngine.swift      # 핵심 카메라 엔진 (상태머신 포함)
├── PetgramCameraPlugin.swift      # Flutter 플러그인 (MethodChannel + EventChannel)
└── PetgramCameraTexture.swift     # Texture 렌더링 (또는 UIKitView)
```

#### PetgramCameraEngine

**단일 상태머신:**
```swift
enum CameraState {
    case idle                    // 초기 상태
    case initializing            // 초기화 중
    case ready                   // 준비 완료, 프리뷰 가능
    case running                 // 프리뷰 실행 중
    case takingPhoto             // 촬영 중
    case error(String)           // 에러 발생
}
```

**주요 메서드:**
- `initialize(position: AVCaptureDevice.Position) -> Result<Void, Error>`
- `dispose()`
- `startPreview(aspect: AspectMode, filter: FilterConfig)`
- `stopPreview()`
- `setAspect(_ aspect: AspectMode)`
- `setFilter(_ filter: FilterConfig)`
- `setZoom(_ zoom: Float)`
- `setFlash(_ mode: FlashMode)`
- `takePhoto(completion: @escaping (Result<PhotoResult, Error>) -> Void)`

**내부 관리:**
- AVCaptureSession, AVCaptureDevice, AVCaptureInput, AVCaptureOutput
- CoreImage/Metal 필터 파이프라인
- 프리뷰 비율 계산 및 크롭 영역 계산
- EXIF 메타데이터 생성

#### PetgramCameraPlugin

**MethodChannel: `petgram_camera`**
- `initialize` - 카메라 초기화
- `dispose` - 카메라 해제
- `startPreview` - 프리뷰 시작
- `stopPreview` - 프리뷰 중지
- `setAspect` - 비율 변경
- `setFilter` - 필터 변경
- `setZoom` - 줌 설정
- `setFlash` - 플래시 모드 설정
- `takePhoto` - 촬영
- `switchCamera` - 전후면 전환

**EventChannel: `petgram_camera/state`**
```swift
struct CameraStateEvent {
    let state: CameraState              // ready, busy, error, noPermission
    let canTakePhoto: Bool              // 촬영 가능 여부
    let aspect: AspectMode              // 현재 비율
    let previewSize: CGSize?            // 프리뷰 크기
    let errorMessage: String?           // 에러 메시지
}
```

**EventChannel: `petgram_camera/preview`**
```swift
struct PreviewEvent {
    let textureId: Int64                // Texture ID
    let previewSize: CGSize             // 프리뷰 크기
    let aspect: AspectMode              // 현재 비율
}
```

### 2. Flutter 쪽 구조

#### 새로운 위젯: `PetgramCameraShell`

```dart
class PetgramCameraShell extends StatefulWidget {
  final AspectMode initialAspect;
  final FilterConfig? initialFilter;
  final Function(String photoPath)? onPhotoTaken;
  
  const PetgramCameraShell({...});
}

class _PetgramCameraShellState extends State<PetgramCameraShell> {
  static const MethodChannel _methodChannel = MethodChannel('petgram_camera');
  static const EventChannel _stateChannel = EventChannel('petgram_camera/state');
  static const EventChannel _previewChannel = EventChannel('petgram_camera/preview');
  
  CameraState _currentState = CameraState.idle;
  bool _canTakePhoto = false;
  int64? _textureId;
  Size? _previewSize;
  
  @override
  void initState() {
    super.initState();
    _initializeCamera();
    _subscribeToStateEvents();
    _subscribeToPreviewEvents();
  }
  
  Future<void> _initializeCamera() async {
    await _methodChannel.invokeMethod('initialize', {'position': 'back'});
    await _methodChannel.invokeMethod('startPreview', {
      'aspect': widget.initialAspect.toString(),
      'filter': widget.initialFilter?.toMap(),
    });
  }
  
  void _subscribeToStateEvents() {
    _stateChannel.receiveBroadcastStream().listen((event) {
      setState(() {
        _currentState = CameraState.fromMap(event['state']);
        _canTakePhoto = event['canTakePhoto'] ?? false;
      });
    });
  }
  
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // 프리뷰 (Texture 또는 UIKitView)
        if (_textureId != null)
          Texture(textureId: _textureId!),
        
        // UI 버튼들
        _buildControls(),
      ],
    );
  }
  
  void _onTakePhoto() {
    if (_canTakePhoto) {
      _methodChannel.invokeMethod('takePhoto').then((result) {
        widget.onPhotoTaken?.call(result['photoPath']);
      });
    }
  }
}
```

#### 상태 계산 제거

**제거 대상:**
- `canUseCamera` 계산 로직
- `_nativeInit`, `_isReady` 관리
- `getDebugState()` 폴링
- Aspect ratio 계산
- Preview size 계산
- Crop rect 계산

**대체 방법:**
- 네이티브에서 EventChannel로 전달하는 `canTakePhoto` 사용
- 네이티브에서 전달하는 `previewSize` 사용
- 네이티브에서 전달하는 `aspect` 사용

---

## 📝 리팩토링 단계

### 1단계: 설계 확인 ✅ (현재 단계)

### 2단계: 네이티브 모듈 구현

#### 2-1. PetgramCameraEngine.swift 생성
- `NativeCamera.swift`의 핵심 로직 추출
- 단일 상태머신 구현
- AVCaptureSession 관리
- 필터 파이프라인 통합
- 프리뷰 비율/크롭 계산 통합

#### 2-2. PetgramCameraPlugin.swift 생성
- MethodChannel 구현
- EventChannel 구현 (state, preview)
- Texture 생성 및 관리

#### 2-3. 기존 NativeCamera.swift와의 호환성
- 기존 코드와 병행 운영 가능하도록 구조 유지
- 점진적 마이그레이션

### 3단계: Flutter 카메라 셸 구현

#### 3-1. PetgramCameraShell 위젯 생성
- `lib/widgets/camera/petgram_camera_shell.dart`
- MethodChannel 통신
- EventChannel 구독
- Texture 표시

#### 3-2. HomePage 통합
- 기존 카메라 프리뷰 영역을 `PetgramCameraShell`로 교체
- 기존 상태 계산 로직 제거

### 4단계: 기존 카메라 로직 정리

#### 4-1. camera_engine.dart 정리
- 상태 계산 로직 제거
- 네이티브 상태 수신만 유지 (임시 호환성)

#### 4-2. home_page.dart 정리
- `canUseCamera` 계산 제거
- `_pollDebugState()` 제거
- Aspect ratio 계산 제거
- Preview size 계산 제거

### 5단계: 디버그 포인트

#### 네이티브
- 각 상태 전환 시 로그
- MethodChannel 호출 시 로그
- EventChannel 이벤트 전송 시 로그

#### Flutter
- EventChannel 수신 이벤트 로그
- 상태 변경 로그 (네이티브에서 받은 값 그대로)

---

## 🔄 마이그레이션 전략

### 점진적 마이그레이션
1. 새 모듈을 기존 코드와 병행 운영
2. 새 셸을 HomePage에 추가하되 기존 프리뷰는 유지 (flag로 전환)
3. 테스트 완료 후 기존 코드 제거

### 호환성 유지
- 기존 `camera_engine.dart`는 deprecated로 표시
- 기존 MethodChannel은 유지하되 내부적으로 새 엔진 호출

---

## ✅ 검증 기준

1. **상태 일관성**
   - Flutter에서 카메라 상태를 계산하지 않음
   - 모든 상태는 네이티브 EventChannel에서 수신

2. **프리뷰 안정성**
   - 프리뷰가 정상적으로 표시됨
   - 비율 변경 시 프리뷰가 올바르게 업데이트됨

3. **촬영 안정성**
   - 촬영 버튼이 네이티브 `canTakePhoto`에 따라 활성화/비활성화
   - 촬영 시 정상적으로 사진 생성

4. **상태 동기화**
   - "sessionRunning=true인데 canUseCamera=false" 같은 모순 발생 안 함
   - 모든 상태 판단이 네이티브 한 곳에서만 수행

---

## 📂 파일 변경 요약

### 새로 생성
- `ios/Runner/Camera/PetgramCameraEngine.swift`
- `ios/Runner/Camera/PetgramCameraPlugin.swift`
- `lib/widgets/camera/petgram_camera_shell.dart`

### 수정
- `lib/pages/home_page.dart` - 새 셸 사용, 상태 계산 제거
- `lib/services/camera_engine.dart` - 상태 계산 제거, deprecated 표시

### 삭제 (최종 단계)
- 불필요해진 상태 계산 로직들
