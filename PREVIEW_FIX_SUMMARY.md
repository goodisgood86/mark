# 프리뷰 검정/핑크 Fallback 근본 원인 해결

## A) 변경 사항 (패치 형태)

### 1. `isRunningOperationInProgress` 영구 락 방지

```swift
// 추가: 타임아웃 기준 변수
private var lastOperationStartedAt: Date?

// 수정: initializeIfNeeded에서 타임아웃 체크
if self.isRunningOperationInProgress {
    if let lastOp = self.lastOperationStartedAt {
        let elapsed = Date().timeIntervalSince(lastOp)
        if elapsed > 1.5 {
            // 타임아웃 시 강제 해제
            self.isRunningOperationInProgress = false
            self.lastOperationStartedAt = nil
            // 계속 진행
        }
    }
}

// 수정: 모든 flag 설정 시 타임아웃 기준 설정
self.isRunningOperationInProgress = true
self.lastOperationStartedAt = Date()

// 수정: 모든 failure 경로에서 타임아웃 기준 해제
self.isRunningOperationInProgress = false
self.lastOperationStartedAt = nil
```

### 2. `initializeIfNeeded` Health Check 강화

```swift
// 수정 전: sessionRunning && hasPreview만 확인
if sessionRunning && hasPreview { return }

// 수정 후: 모든 health 조건 확인
let hasPhotoOutput = self.photoOutput != nil
let hasVideoDataOutput = self.videoDataOutput != nil
let videoDataOutputInSession = hasVideoDataOutput && self.session.outputs.contains(self.videoDataOutput!)
let videoConnection = hasVideoDataOutput ? self.videoDataOutput!.connection(with: .video) : nil
let hasVideoConnection = videoConnection != nil
let connectionEnabled = videoConnection?.isEnabled ?? false

let isHealthy = sessionRunning &&
               hasPhotoOutput &&
               hasVideoDataOutput &&
               videoDataOutputInSession &&
               hasVideoConnection &&
               connectionEnabled &&
               hasPreview

if isHealthy { return }

// 반쪽 상태 감지 및 재초기화
if sessionRunning && (!hasPhotoOutput || !hasVideoDataOutput || !videoDataOutputInSession || !hasVideoConnection || !connectionEnabled) {
    // 세션 중지 및 기존 구성 요소 정리
    self.session.stopRunning()
    self.session.beginConfiguration()
    for input in self.session.inputs { self.session.removeInput(input) }
    for output in self.session.outputs { self.session.removeOutput(output) }
    self.session.commitConfiguration()
    self.videoInput = nil
    self.photoOutput = nil
    self.videoDataOutput = nil
    // 재초기화 진행
}
```

### 3. `_performInitialize` startRunning 실패/첫 프레임 미수신 처리

```swift
// 추가: startRunning 후 0.2초 체크
DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
    if !self.session.isRunning {
        // startRunning 실패 처리
        self.isRunningOperationInProgress = false
        self.lastOperationStartedAt = nil
        self.session.stopRunning()
        completion(.failure(...))
        return
    }
}

// 수정: 0.5초 내 sampleBuffer 없으면 connection rebind
DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
    if self.sampleBufferCount == 0 {
        // delegate 재설정, connection 재활성화, 필요시 output 재부착
    }
}

// 수정: 1.0초 내 sampleBuffer 없으면 실패 처리
DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
    if self.sampleBufferCount == 0 {
        self.isRunningOperationInProgress = false
        self.lastOperationStartedAt = nil
        self.session.stopRunning()
        completion(.failure(...))
    } else {
        // 첫 프레임 수신 성공
        self.isRunningOperationInProgress = false
        self.lastOperationStartedAt = nil
    }
}
```

### 4. 라이프사이클 핸들러 개선

```swift
// 수정: onAppWillResignActive
@objc private func onAppWillResignActive() {
    // flag 정리 및 세션 중지
    sessionQueue.async {
        if self.isRunningOperationInProgress {
            self.isRunningOperationInProgress = false
            self.lastOperationStartedAt = nil
        }
        if self.session.isRunning {
            self.session.stopRunning()
        }
    }
}

// 수정: onAppDidEnterBackground
@objc private func onAppDidEnterBackground() {
    // flag 정리 및 세션 중지
    sessionQueue.async {
        if self.isRunningOperationInProgress {
            self.isRunningOperationInProgress = false
            self.lastOperationStartedAt = nil
        }
        if self.session.isRunning {
            self.session.stopRunning()
        }
    }
}

// 추가: ensureConfigured (health 체크 후 필요 시 reconfigure)
private func ensureConfigured() {
    sessionQueue.async {
        // HEALTH CHECK: 모든 필수 구성 요소 확인
        let isHealthy = sessionRunning && hasPhotoOutput && hasVideoDataOutput && ...

        if !isHealthy {
            // Flutter에서 initializeIfNeeded 호출하도록 상태 변경
            DispatchQueue.main.async {
                self.cameraState = CameraState.error
                self.notifyStateChange()
            }
            return
        }

        // HEALTH CHECK 통과: connection 재활성화만 수행
        if let connection = videoDataOutput.connection(with: .video) {
            connection.isEnabled = true
            if !self.session.isRunning {
                self.session.startRunning()
            }
        }
    }
}

// 수정: onAppDidBecomeActive
@objc private func onAppDidBecomeActive() {
    // 프리뷰 상태 복구
    previewView.isPaused = false
    previewView.isHidden = false
    // ensureConfigured 호출
    ensureConfigured()
}
```

### 5. 디버그 로그 강화

```swift
// 추가: photoOutput 생성/세션 add 성공 여부
self.log("[Native] 📷 Step 2.1: Creating AVCapturePhotoOutput")
self.log("[Native] 📷 canAddOutput(photoOutput): \(canAddPhotoOutput)")
self.log("[Native] ✅ Step 2.1 SUCCESS: photoOutput created and added to session")

// 추가: videoDataOutput/connection 상세 로그
self.log("[Native] ✅ videoOutput.connection(with: .video) exists")
self.log("[Native] 📷 connection.isEnabled: \(connection.isEnabled)")
self.log("[Native] 📷 connection.isActive: \(connection.isActive)")

// 추가: configure 시작/끝
self.log("[Native] 📷 Step 2.7: Committing session configuration")
self.log("[Native] ✅ Step 3 SUCCESS: Session configuration committed")

// 추가: startRunning 직전/직후 session.isRunning
self.log("[Native] 📷 Step 4: session.isRunning BEFORE startRunning=\(self.session.isRunning)")
self.log("[Native] 📷 Step 4: session.isRunning AFTER startRunning=\(self.session.isRunning)")
```

## B) 왜 이 수정이 문제를 해결하는가

1. **Health Check 강화**: `sessionRunning=true`만으로 판단하지 않고 `photoOutput`, `videoDataOutput`, `connection`까지 모두 확인하여 불완전한 초기화 상태를 감지하고 재초기화합니다.

2. **영구 락 방지**: `isRunningOperationInProgress`가 1.5초 이상 유지되면 타임아웃으로 강제 해제하여 라이프사이클로 끊겨도 복구 가능합니다.

3. **startRunning 실패 명확히 처리**: 0.2초 후 `session.isRunning==false`면 즉시 실패 처리하여 무한 대기를 방지합니다.

4. **첫 프레임 미수신 자동 복구**: 0.5초 내 sampleBuffer 없으면 connection rebind, 1.0초 내 없으면 실패 처리하여 재시도 가능하게 합니다.

5. **라이프사이클 안정화**: inactive/hidden 진입 시 flag 정리 및 세션 중지, resumed 시 `ensureConfigured`로 health 체크 후 필요 시 reconfigure하여 반복적으로 복구됩니다.

## C) Flutter 측 initializeIfNeeded 호출 권장 타이밍

1. **resumed 이후 1프레임 지연**: `WidgetsBinding.instance.addPostFrameCallback` 사용

   ```dart
   WidgetsBinding.instance.addPostFrameCallback((_) {
     Future.delayed(Duration(milliseconds: 16), () {
       nativeCameraController.initializeIfNeeded(...);
     });
   });
   ```

2. **AppLifecycleState.resumed 이후 200ms 지연**: 라이프사이클 변경 후 안정화 대기

   ```dart
   void didChangeAppLifecycleState(AppLifecycleState state) {
     if (state == AppLifecycleState.resumed) {
       Future.delayed(Duration(milliseconds: 200), () {
         nativeCameraController.initializeIfNeeded(...);
       });
     }
   }
   ```

3. **onCameraInitialized 콜백 실패 시 재시도**: 초기화 실패 시 지수 백오프로 재시도
   ```dart
   void _retryInitialize({int retryCount = 0}) {
     if (retryCount >= 3) return;
     nativeCameraController.initializeIfNeeded(...).catchError((error) {
       Future.delayed(Duration(milliseconds: 500 * (retryCount + 1)), () {
         _retryInitialize(retryCount: retryCount + 1);
       });
     });
   }
   ```
