# 종합 SIGKILL 방지 패치 (A~D 전체 반영)

## 문제 요약
- SIGKILL 반복 발생
- willResignActive/didEnterBackground가 동일 reason으로 다중 호출됨
- applyLifecycleTransition START/END, cleanupForLifecycle이 연속 다발 발생
- requestCameraPermission가 라이프사이클 전환 중에도 계속 호출됨
- initializeIfNeeded가 authStatus=0인 상태에서 반복 호출됨

## A) 옵저버/인스턴스 중복 제거

### 현재 상태 확인
1. ✅ `areObserversRegistered` 플래그가 있으나 인스턴스별 (static 아님)
2. ❌ `init(coder:)`에서도 옵저버 등록 중복 가능
3. ✅ CameraManager는 싱글톤이지만, `ensureCameraViewController`에서 중복 생성 가능성

### 수정 사항

#### 1. Static 플래그로 전역 옵저버 등록 보장
```swift
// NativeCameraViewController 클래스 내부
// 🔥🔥🔥 전역 옵저버 등록 방지 (static으로 변경)
private static var globalObserversRegistered = false
private static let globalObserverLock = NSLock()
```

#### 2. init(coder:)에서도 중복 방지
```swift
required init?(coder: NSCoder) {
    // ... 기존 코드 ...
    
    // 🔥🔥🔥 static 플래그로 전역 등록 확인
    NativeCameraViewController.globalObserverLock.lock()
    let alreadyRegistered = NativeCameraViewController.globalObserversRegistered
    if !alreadyRegistered {
        // 옵저버 등록
        // ...
        NativeCameraViewController.globalObserversRegistered = true
    }
    NativeCameraViewController.globalObserverLock.unlock()
}
```

#### 3. CameraManager 중복 생성 방지 강화
```swift
private func setupCameraViewController(in rootVC: RootViewController) {
    // 이미 설정되어 있으면 스킵 (기존 로직 유지)
    if cameraViewController != nil {
        NSLog("[CameraManager] ⚠️ Camera view controller already exists, skipping setup")
        return
    }
    
    // 🔥🔥🔥 추가: 기존 VC가 dealloc되지 않았는지 확인
    if let existingVC = cameraViewController,
       existingVC.view.superview != nil {
        NSLog("[CameraManager] ⚠️ Existing camera VC still attached, skipping setup")
        return
    }
    
    // ... 나머지 코드 ...
}
```

## B) 권한 승인 전 카메라 접근 전면 차단

### 수정 사항

#### 1. `initialize` 함수에 권한 체크 추가
```swift
func initialize(position: AVCaptureDevice.Position, aspectRatio: Double? = nil, completion: @escaping (Result<Void, Error>) -> Void) {
    // 🔥🔥🔥 핵심: 권한 체크를 가장 먼저 수행
    let authStatus = AVCaptureDevice.authorizationStatus(for: .video)
    if authStatus != .authorized {
        let skipMsg = "[Native] ⏸️ initialize() SKIPPED: camera permission not authorized (authStatus=\(authStatus.rawValue))"
        log(skipMsg)
        onDebugLog?(skipMsg)
        NativeCamera.sendDebugLog(viewId: Int64(viewId), message: skipMsg)
        completion(.failure(NSError(domain: "Petgram", code: -401, userInfo: [NSLocalizedDescriptionKey: "Camera permission not authorized"])))
        return
    }
    
    // ... 기존 코드 ...
}
```

#### 2. `onAppDidBecomeActive`에서 권한 체크 강화
```swift
@objc private func onAppDidBecomeActive() {
    // 🔥🔥🔥 핵심: 권한 체크를 가장 먼저 수행 (모든 작업 전에)
    let authStatus = AVCaptureDevice.authorizationStatus(for: .video)
    if authStatus != .authorized {
        let skipMsg = "[Native] ⏸️ onAppDidBecomeActive: SKIPPED ALL - camera permission not authorized (authStatus=\(authStatus.rawValue))"
        log(skipMsg)
        onDebugLog?(skipMsg)
        NativeCamera.sendDebugLog(viewId: Int64(viewId), message: skipMsg)
        return  // 권한이 없으면 아무것도 하지 않음
    }
    
    // ... 기존 코드 ...
}
```

#### 3. `ensureHealthyOrReinit`, `ensureConfigured`는 이미 권한 체크 있음 ✅

## C) 라이프사이클 중복 호출 하드 차단

### 수정 사항

#### 1. GlobalLifecycleManager에 reason+instanceId 기반 throttle 추가
```swift
final class GlobalLifecycleManager {
    // ... 기존 코드 ...
    
    // 🔥🔥🔥 reason + instanceId 조합 기반 debounce
    private struct TransitionKey: Hashable {
        let reason: String
        let instanceId: String
    }
    private var lastTransitionKey: TransitionKey?
    private var lastTransitionTime: Date?
    
    func tryAcquire(reason: String, instanceId: String) -> Bool {
        var acquired = false
        
        lockQueue.sync {
            let now = Date()
            let key = TransitionKey(reason: reason, instanceId: instanceId)
            
            // 🔥🔥🔥 lock 체크 먼저
            if _isCleaning {
                acquired = false
                return
            }
            
            // 🔥🔥🔥 reason+instanceId 조합 기반 debounce
            if let lastKey = lastTransitionKey,
               let lastTime = lastTransitionTime,
               lastKey == key {
                let elapsedTime = now.timeIntervalSince(lastTime)
                if elapsedTime < debounceInterval {
                    acquired = false
                    return
                }
            }
            
            // 획득
            lastTransitionKey = key
            lastTransitionTime = now
            _isCleaning = true
            acquired = true
        }
        
        return acquired
    }
}
```

#### 2. `applyLifecycleTransition`에서 instanceId 전달
```swift
func applyLifecycleTransition(reason: String, action: String) {
    let instanceId = stableInstancePtr
    
    // 🔥🔥🔥 instanceId 포함하여 전역 lock 획득
    let acquired = GlobalLifecycleManager.shared.tryAcquire(reason: reason, instanceId: instanceId)
    // ... 기존 코드 ...
}
```

## D) Flutter 쪽 동기화

### 수정 사항

#### 1. `_checkPermissions` re-entrancy guard 강화
```dart
Future<void> _checkPermissions() async {
  // 🔥🔥🔥 re-entrancy guard: 이미 체크 중이면 중복 호출 방지
  if (_isChecking) {
    debugPrint('[DEBUG LOG] _checkPermissions SKIPPED - already checking');
    return;
  }
  
  // 🔥🔥🔥 라이프사이클 상태 체크: inactive/paused 상태에서는 pending 플래그만 설정
  final currentState = WidgetsBinding.instance.lifecycleState;
  if (currentState == AppLifecycleState.paused ||
      currentState == AppLifecycleState.hidden ||
      currentState == AppLifecycleState.inactive) {
    debugPrint('[DEBUG LOG] _checkPermissions SKIPPED - app is background (state=$currentState)');
    // 🔥🔥🔥 pending 플래그 설정 (resumed 시 재시도)
    _needsPermissionCheck = true;
    return;
  }
  
  setState(() {
    _isChecking = true;
  });
  
  try {
    // ... 기존 권한 체크 로직 ...
  } finally {
    if (mounted) {
      setState(() {
        _isChecking = false;
      });
    }
  }
}
```

#### 2. 라이프사이클 전환 시 pending 플래그 처리
```dart
@override
void didChangeAppLifecycleState(AppLifecycleState state) {
  if (state == AppLifecycleState.resumed) {
    // 🔥🔥🔥 pending 플래그가 있으면 권한 체크 재시도
    if (_needsPermissionCheck && !_isChecking && mounted) {
      _needsPermissionCheck = false;
      Future.delayed(const Duration(milliseconds: 300), () {
        if (mounted) {
          _checkPermissions();
        }
      });
    }
    
    // ... 기존 코드 ...
  }
}
```

#### 3. HomePage 진입 전 권한 체크
```dart
@override
Widget build(BuildContext context) {
  // 🔥🔥🔥 권한이 허용되지 않았으면 HomePage 진입 차단
  if (!_permissionsGranted) {
    return Scaffold(
      body: Center(
        child: CircularProgressIndicator(),
      ),
    );
  }
  
  return HomePage(cameras: widget.cameras);
}
```

## 테스트 체크리스트

### 1. 옵저버 중복 등록 확인
- [ ] 앱 시작 시 "✅ NotificationCenter observers registered" 로그가 1회만 출력되는지 확인
- [ ] "⚠️ NotificationCenter observers already registered, skipping" 로그가 출력되지 않는지 확인

### 2. 권한 체크 확인
- [ ] `initialize` 함수에서 권한 미허용 시 즉시 return되는지 확인
- [ ] `onAppDidBecomeActive`에서 권한 미허용 시 모든 작업이 스킵되는지 확인
- [ ] `initializeIfNeeded`가 authStatus=0일 때 호출되지 않는지 확인

### 3. 라이프사이클 중복 호출 확인
- [ ] `applyLifecycleTransition START`가 1회만 호출되는지 확인
- [ ] `SKIPPED - already applying transition` 로그가 중복 호출 시 출력되는지 확인
- [ ] `onAppDidEnterBackground` throttle이 작동하여 중복 호출이 차단되는지 확인

### 4. Flutter 동기화 확인
- [ ] `_checkPermissions`가 라이프사이클 전환 중 호출되지 않는지 확인
- [ ] `_needsPermissionCheck` 플래그가 resumed 시 권한 체크를 트리거하는지 확인
- [ ] 권한 미허용 시 HomePage가 표시되지 않는지 확인

### 5. SIGKILL 발생 확인
- [ ] 권한 거부 → 설정 이동 → 권한 토글 → 앱 복귀 시 SIGKILL이 발생하지 않는지 확인
- [ ] 로그에서 중복 호출이 차단되는지 확인

## 예상되는 개선 효과

### 수정 전
```
[Native] 🔄 applyLifecycleTransition START: ... (10회 이상)
[Native] 🧹 cleanupForLifecycle START: ... (10회 이상)
Process X stopped
* thread #1, queue = 'com.apple.main-thread', stop reason = signal SIGKILL
```

### 수정 후 (예상)
```
[Native] ✅ NotificationCenter observers registered (1회만)
[Native] ⏸️ initialize() SKIPPED: camera permission not authorized (authStatus=0)
[Native] ⏸️ onAppDidBecomeActive: SKIPPED ALL - camera permission not authorized
[Native] 🔄 applyLifecycleTransition START: ... (1회만)
[Native] ⏸️ applyLifecycleTransition: SKIPPED - already applying transition (나머지)
[Native] 🧹 cleanupForLifecycle START: ... (1회만)
✅ SIGKILL 없음
```
