# 카메라 초기화 실패 분석 (검은 화면 문제)

## 문제 상황
실제 테스트 시 검은 화면이 뜨면서 카메라를 초기화하지 못하는 문제 발생

## 코드 구조 분석

### 1. Flutter → 네이티브 호출 흐름

```
home_page.dart (_initCameraPipeline)
  ↓
NativeCameraController 생성
  ↓
NativeCameraPreview 위젯 빌드
  ↓
onCreated 콜백 (viewId 받음)
  ↓
_cameraEngine.initialize() 호출
  ↓
MethodChannel: 'petgram/native_camera' → 'initialize'
  ↓
iOS: NativeCameraView.handleMethodCall("initialize")
  ↓
NativeCameraViewController.initialize()
```

### 2. iOS 네이티브 초기화 흐름

```
NativeCameraViewController.initialize()
  ↓
sessionQueue.async { ... }
  ↓
findDevice(position:) → AVCaptureDevice 찾기
  ↓
AVCaptureDeviceInput 생성
  ↓
session.addInput/addOutput
  ↓
session.startRunning()
  ↓
onCameraInitialized 콜백 호출
```

## 의심스러운 영역

### 🔴 **1. 카메라 권한 체크 누락 (최우선 의심)**

**위치**: `ios/Runner/NativeCamera.swift:84` - `initialize()` 메서드

**문제점**:
- `initialize()` 메서드가 호출될 때 **카메라 권한을 체크하지 않음**
- `findDevice()`는 권한 없이도 호출 가능하지만, `AVCaptureDeviceInput(device:)` 생성 시 권한이 필요
- 권한이 없으면 `AVCaptureDeviceInput` 초기화가 실패하거나 세션 시작이 실패할 수 있음

**현재 코드**:
```swift
func initialize(position: AVCaptureDevice.Position, completion: @escaping (Result<Void, Error>) -> Void) {
    // ❌ 권한 체크 없이 바로 findDevice() 호출
    guard let device = self.findDevice(position: position) else {
        // 디바이스를 찾지 못한 경우만 에러 처리
    }
    // ...
    let videoInput = try AVCaptureDeviceInput(device: device) // 권한 없으면 여기서 실패 가능
}
```

**의심 증거**:
- `initCamera` 메서드(2461줄)에서는 권한 체크를 하지만, 실제 `initialize` 메서드에서는 체크하지 않음
- 권한이 거부된 상태에서 `initialize()`를 호출하면 검은 화면만 표시될 수 있음

**해결 방안**:
```swift
func initialize(position: AVCaptureDevice.Position, completion: @escaping (Result<Void, Error>) -> Void) {
    // 권한 체크 추가
    let authStatus = AVCaptureDevice.authorizationStatus(for: .video)
    switch authStatus {
    case .notDetermined:
        AVCaptureDevice.requestAccess(for: .video) { granted in
            if granted {
                // 권한 획득 후 초기화 진행
            } else {
                completion(.failure(NSError(...)))
            }
        }
        return
    case .denied, .restricted:
        completion(.failure(NSError(...)))
        return
    case .authorized:
        break
    @unknown default:
        completion(.failure(NSError(...)))
        return
    }
    // 기존 초기화 로직...
}
```

---

### 🔴 **2. 세션 시작 실패 시 에러 처리 부족**

**위치**: `ios/Runner/NativeCamera.swift:191` - `session.startRunning()`

**문제점**:
- `session.startRunning()`은 동기적으로 실패할 수 있지만, 에러를 던지지 않음
- 세션이 실행 중이 아니거나 설정이 잘못된 경우 `startRunning()`이 실패해도 감지하지 못함
- `onCameraInitialized` 콜백이 호출되지 않아 Flutter 측에서 타임아웃 발생

**현재 코드**:
```swift
self.session.commitConfiguration()
// 세션 시작
self.session.startRunning() // ❌ 실패 여부 확인 없음
self.isRunningOperationInProgress = false

// 바로 onCameraInitialized 호출 (세션이 실제로 시작되었는지 확인 안 함)
DispatchQueue.main.async {
    self.onCameraInitialized?(...)
}
```

**의심 증거**:
- 세션이 시작되지 않으면 프리뷰가 검은 화면으로 표시됨
- `onCameraInitialized`는 호출되지만 실제로는 세션이 실행되지 않을 수 있음

**해결 방안**:
```swift
self.session.commitConfiguration()

// 세션 시작 및 상태 확인
self.session.startRunning()

// 세션이 실제로 실행 중인지 확인
DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
    if self.session.isRunning {
        // 초기화 완료
        self.onCameraInitialized?(...)
    } else {
        // 세션 시작 실패
        self.onCameraError?("Session failed to start")
        completion(.failure(NSError(...)))
    }
}
```

---

### 🟡 **3. 타임아웃 처리의 한계**

**위치**: `ios/Runner/NativeCamera.swift:2535` - 타임아웃 10초

**문제점**:
- `onCameraInitialized` 콜백이 호출되지 않으면 타임아웃 발생
- 하지만 타임아웃이 발생해도 Flutter 측에서 적절한 에러 메시지를 표시하지 않을 수 있음
- 권한이 없거나 디바이스를 찾지 못한 경우에도 타임아웃으로 처리됨

**현재 코드**:
```swift
let timeoutResult = initSemaphore.wait(timeout: .now() + 10.0)
if timeoutResult == .timedOut {
    // 타임아웃 에러만 반환
    result(FlutterError(code: "INIT_TIMEOUT", ...))
}
```

**의심 증거**:
- 실제로는 권한 문제인데 타임아웃으로만 표시될 수 있음
- 사용자에게 명확한 에러 메시지가 전달되지 않음

---

### 🟡 **4. Flutter 측 초기화 순서 문제**

**위치**: `lib/pages/home_page.dart:3454` - `onCreated` 콜백

**문제점**:
- `NativeCameraPreview`의 `onCreated` 콜백에서 바로 `initialize()` 호출
- 이 시점에 권한이 없을 수 있음
- 권한 체크 없이 초기화를 시도하면 실패

**현재 코드**:
```dart
onCreated: (viewId) {
    if (!_cameraEngine.isInitialized) {
        _cameraEngine.setViewId(viewId);
        _cameraEngine.initialize(...) // ❌ 권한 체크 없이 바로 호출
            .then((_) { ... })
            .catchError((e) { ... });
    }
}
```

**의심 증거**:
- 첫 실행 시 권한 요청이 필요한데, Flutter 측에서 권한을 먼저 체크하지 않음
- iOS 네이티브에서도 권한 체크를 하지 않아 실패 가능

---

### 🟡 **5. findDevice() 실패 시 에러 메시지 부족**

**위치**: `ios/Runner/NativeCamera.swift:596` - `findDevice()` 메서드

**문제점**:
- `findDevice()`가 `nil`을 반환하면 "No camera device found" 에러만 반환
- 실제로는 권한 문제일 수도 있는데 구분하지 못함
- 디바이스가 실제로 없는지, 권한이 없는지 구분 불가

**현재 코드**:
```swift
guard let device = self.findDevice(position: position) else {
    completion(.failure(NSError(domain: "Petgram", code: -3, 
        userInfo: [NSLocalizedDescriptionKey: "No camera device found"])))
    return
}
```

**의심 증거**:
- 권한이 없어도 "No camera device found"로 표시될 수 있음
- 실제 원인을 파악하기 어려움

---

### 🟡 **6. AVCaptureDeviceInput 초기화 실패 처리**

**위치**: `ios/Runner/NativeCamera.swift:137`

**문제점**:
- `AVCaptureDeviceInput(device:)` 초기화가 실패할 수 있음 (권한, 디바이스 잠금 등)
- `try`로 처리하지만 구체적인 에러 원인을 구분하지 못함

**현재 코드**:
```swift
let videoInput = try AVCaptureDeviceInput(device: device)
```

**의심 증거**:
- 권한이 없거나 디바이스가 다른 프로세스에서 사용 중이면 초기화 실패
- 에러 메시지가 모호할 수 있음

---

### 🟡 **7. 세션 프리셋 설정 실패 가능성**

**위치**: `ios/Runner/NativeCamera.swift:118`

**문제점**:
- `sessionPreset` 설정이 실패할 수 있음
- `.photo`와 `.high` 모두 실패하면 기본값 사용
- 일부 기기에서는 특정 프리셋을 지원하지 않을 수 있음

**현재 코드**:
```swift
if self.session.canSetSessionPreset(.photo) {
    self.session.sessionPreset = .photo
} else if self.session.canSetSessionPreset(.high) {
    self.session.sessionPreset = .high
}
// 프리셋 설정 실패 시 기본값 사용 (에러 처리 없음)
```

---

### 🟡 **8. Flutter 측 에러 처리 부족**

**위치**: `lib/camera/native_camera_controller.dart:100` - `initialize()` 메서드

**문제점**:
- 네이티브에서 에러가 발생해도 Flutter 측에서 적절한 폴백 처리 없음
- `isInitialized=false`로 반환되면 에러를 던지지만, 사용자에게 명확한 메시지 표시 없음

**현재 코드**:
```dart
if (!_isInitialized) {
    throw Exception(
        'Native camera initialize() returned isInitialized=false. '
        'This may indicate camera hardware not found or permission denied.'
    );
}
```

**의심 증거**:
- 에러가 발생해도 검은 화면만 표시되고 사용자에게 알림이 없을 수 있음

---

## 우선순위별 해결 방안

### 🔥 **최우선 (Critical)**

1. **iOS 네이티브에서 권한 체크 추가**
   - `initialize()` 메서드 시작 부분에 권한 체크 로직 추가
   - 권한이 없으면 명확한 에러 메시지 반환

2. **세션 시작 상태 확인**
   - `session.startRunning()` 후 실제로 실행 중인지 확인
   - 실행되지 않으면 에러 처리

### ⚠️ **높은 우선순위 (High)**

3. **에러 메시지 개선**
   - 권한 문제와 디바이스 문제를 구분
   - Flutter 측에서 사용자에게 명확한 메시지 표시

4. **Flutter 측 권한 체크 추가**
   - `initialize()` 호출 전에 권한 상태 확인
   - 권한이 없으면 먼저 요청

### 📋 **중간 우선순위 (Medium)**

5. **타임아웃 처리 개선**
   - 타임아웃 발생 시 더 자세한 디버그 정보 수집
   - 권한 상태, 세션 상태 등을 로그에 기록

6. **디바이스 찾기 실패 시 상세 에러**
   - 권한 상태와 함께 에러 메시지 반환

---

## 디버깅 체크리스트

실제 테스트 시 다음을 확인:

1. ✅ **카메라 권한 상태**
   - 설정 → Petgram → 카메라 권한 확인
   - 권한이 "거부됨"이면 문제 원인

2. ✅ **네이티브 로그 확인**
   - Xcode 콘솔에서 `[Native]` 로그 확인
   - `onCameraInitialized` 콜백 호출 여부
   - `onCameraError` 콜백 호출 여부

3. ✅ **세션 상태 확인**
   - `session.isRunning` 상태 확인
   - `getDebugState()` 메서드로 세션 상태 조회

4. ✅ **디바이스 찾기 성공 여부**
   - `findDevice()` 반환값 확인
   - 권한이 있어도 디바이스를 찾지 못할 수 있음

5. ✅ **Flutter 측 에러 메시지**
   - `catchError`에서 받은 에러 메시지 확인
   - 타임아웃인지, 권한 문제인지 구분

---

## 예상 시나리오

### 시나리오 1: 권한이 없는 경우
```
1. Flutter: initialize() 호출
2. iOS: findDevice() 성공 (권한 체크 없음)
3. iOS: AVCaptureDeviceInput 초기화 시도
4. iOS: 권한 없어서 실패 또는 세션 시작 실패
5. iOS: onCameraInitialized 호출 안 됨
6. Flutter: 10초 타임아웃 발생
7. 결과: 검은 화면 표시
```

### 시나리오 2: 세션이 시작되지 않는 경우
```
1. Flutter: initialize() 호출
2. iOS: 모든 설정 성공
3. iOS: session.startRunning() 호출
4. iOS: 세션이 실제로 시작되지 않음 (원인 불명)
5. iOS: onCameraInitialized는 호출됨
6. Flutter: 초기화 완료로 인식
7. 결과: 검은 화면 표시 (세션이 실행되지 않아서)
```

### 시나리오 3: 디바이스를 찾지 못하는 경우
```
1. Flutter: initialize() 호출
2. iOS: findDevice() 실패 (nil 반환)
3. iOS: "No camera device found" 에러 반환
4. Flutter: 에러 처리
5. 결과: 검은 화면 또는 에러 메시지
```

---

## 권장 수정 사항

1. **iOS 네이티브 `initialize()` 메서드에 권한 체크 추가** (최우선)
2. **세션 시작 후 상태 확인 로직 추가**
3. **에러 메시지에 권한 상태 정보 포함**
4. **Flutter 측에서 권한 체크 후 초기화 시도**
5. **더 자세한 디버그 로그 추가**

