# 🔍 Petgram 카메라 엔진 디버그 분석 리포트

## 📋 문제 증상 요약

1. **Flutter viewId = 0**, **Native viewId = -1** (불일치)
2. **instancePtr이 비어있음**
3. **sessionRunning / videoConnected / hasFirstFrame 불일치**
4. **초기화 성공 후 다시 false로 덮어씀**
5. **ForceReinit 불필요 작동**
6. **카메라 프리뷰 검은 화면**
7. **촬영 시 "카메라 초기화 실패"**

---

## 🔗 로그 체인 분석

### 단계 1: PlatformView 생성 및 onCreated 호출

**실행 순서:**
```
1. NativeCameraPreview 위젯 빌드
   └─> PlatformView 생성 (viewId = 0)
   └─> onCreated(viewId: 0) 콜백 호출
```

**코드 위치:**
- `lib/pages/home_page.dart:5787` - `onCreated: (viewId) { ... }`

**문제점:**
- ✅ 정상: viewId = 0으로 전달됨

---

### 단계 2: attachNativeView 호출

**실행 순서:**
```
2. _cameraEngine.attachNativeView(viewId: 0)
   └─> _viewId = 0 설정 (CameraEngine)
   └─> NativeCameraController.setViewId(0) 호출
   └─> _viewId = 0 설정 (NativeCameraController)
```

**코드 위치:**
- `lib/services/camera_engine.dart:250` - `attachNativeView()`
- `lib/camera/native_camera_controller.dart:25` - `setViewId()`

**문제점:**
- ✅ 정상: Flutter 쪽 viewId는 0으로 설정됨

---

### 단계 3: initializeNativeCamera 호출 (Flutter → Native)

**실행 순서:**
```
3. _cameraEngine.initializeNativeCamera(viewId: 0, ...)
   └─> NativeCameraController.initializeNativeCamera(viewId: 0, ...)
   └─> MethodChannel.invokeMethod('initializeNativeCamera', {viewId: 0, ...})
```

**코드 위치:**
- `lib/services/camera_engine.dart:270` - `initializeNativeCamera()`
- `lib/camera/native_camera_controller.dart:122` - `initializeNativeCamera()`

**문제점:**
- ✅ 정상: viewId = 0이 네이티브로 전달됨

---

### 단계 4: Native initializeNativeCamera 처리

**실행 순서:**
```
4. Native handleMethodCall('initializeNativeCamera')
   └─> viewId = args["viewId"] as? Int ?? 0  // ✅ viewId = 0 파싱
   └─> cameraVC = CameraManager.shared.getCameraViewController()
   └─> cameraVC.viewId = viewId  // ✅ viewId = 0 설정
   └─> NativeCameraRegistry.shared.setCamera(cameraVC, for: viewId)
```

**코드 위치:**
- `ios/Runner/NativeCamera.swift:5761` - `case "initializeNativeCamera"`
- `ios/Runner/NativeCamera.swift:5787` - `cameraVC.viewId = viewId`

**문제점:**
- ✅ 정상: NativeCameraViewController.viewId = 0으로 설정됨

---

### 단계 5: getDebugState() 호출 (초기화 중/후)

**실행 순서:**
```
5. _pollDebugState() → _cameraEngine.getDebugState()
   └─> NativeCameraController.getDebugState()
   └─> MethodChannel.invokeMethod('getDebugState', {viewId: 0})
   └─> Native handleMethodCall('getDebugState')
   └─> NativeCameraRegistry.shared.camera(for: viewId)  // viewId = 0으로 조회
   └─> controller.getState() 호출
```

**코드 위치:**
- `lib/pages/home_page.dart:392` - `_pollDebugState()`
- `lib/services/camera_engine.dart:1075` - `getDebugState()`
- `ios/Runner/NativeCamera.swift:3155` - `getState()`

**문제점 발견:**
- ❌ **문제 1**: `getState()` 내부에서 `self.viewId`를 사용하는데, 초기화 전에 호출되면 `-1`이 반환됨
- ❌ **문제 2**: `getDebugState()`에서 `_nativeInit`, `_isReady`를 `rawDebugState` 값으로 덮어씀 (line 1118-1119)
- ❌ **문제 3**: `canUseCamera`에서 `viewId = -1`일 때도 mismatch로 처리하여 카메라 사용 불가

---

### 단계 6: canUseCamera 계산

**실행 순서:**
```
6. canUseCamera getter 호출
   └─> state = _cameraEngine.lastDebugState
   └─> currentViewId = _cameraEngine.viewId  // 0
   └─> state.viewId != currentViewId 체크  // -1 != 0 → mismatch!
   └─> return false  // ❌ 카메라 사용 불가
```

**코드 위치:**
- `lib/pages/home_page.dart:551` - `canUseCamera`

**문제점:**
- ❌ **문제 4**: `viewId = -1`은 초기화 전 상태일 수 있는데, mismatch로 처리하여 카메라 사용을 막음

---

### 단계 7: getDebugState()에서 상태 덮어쓰기

**실행 순서:**
```
7. getDebugState() → rawDebugState 수신
   └─> _nativeInit = rawDebugState?['nativeInit']  // ❌ 덮어씀!
   └─> _isReady = rawDebugState?['isReady']  // ❌ 덮어씀!
```

**코드 위치:**
- `lib/services/camera_engine.dart:1118-1119`

**문제점:**
- ❌ **문제 5**: `initialize()` 성공 후 `_nativeInit = true`, `_isReady = true`를 설정했지만, `getDebugState()`에서 다시 덮어씀
- 네이티브가 아직 준비되지 않았으면 `false`로 덮어씌워짐

---

## 🎯 근본 원인 요약

1. **viewId 타이밍 문제**: `getState()`가 `initializeNativeCamera()` 완료 전에 호출되면 `viewId = -1` 반환
2. **상태 덮어쓰기 문제**: `getDebugState()`에서 초기화 성공 후 설정한 `_nativeInit`, `_isReady`를 덮어씀
3. **과도한 방어 로직**: `canUseCamera`에서 `viewId = -1`을 mismatch로 처리하여 초기화 전 상태에서도 카메라 사용 불가
4. **instancePtr 누락 가능성**: 네이티브에서 instancePtr이 제대로 전달되지 않을 수 있음

---

## 🔧 패치 전략

### A. Flutter 쪽 수정

1. **viewId = -1 방어 로직**: 초기화 전 상태로 간주하고 mismatch로 처리하지 않음
2. **상태 덮어쓰기 방지**: `getDebugState()`에서 초기화 성공 후 설정한 값은 덮어쓰지 않음
3. **instancePtr 검증**: instancePtr이 비어있으면 경고 로그

### B. iOS Native 쪽 수정

1. **viewId 설정 보장**: `getState()` 호출 시 viewId가 -1이면 경고만 하고, 실제 값은 반환
2. **instancePtr 보장**: 항상 정확한 instancePtr 반환
3. **초기화 상태 명확화**: 초기화 전/후 상태를 명확히 구분

---

## 📝 다음 단계

패치 코드를 적용하여 위 문제들을 해결합니다.

