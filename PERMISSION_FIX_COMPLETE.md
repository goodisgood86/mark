# 권한 설정 문제 완전 해결

## 적용된 해결책

### 1. 네이티브 카메라의 자동 재초기화 방지

#### 문제
- `onAppDidBecomeActive()`에서 0.2초 후 자동으로 `initializeIfNeeded()`를 호출
- 권한 변경 후 복귀 시 네이티브 카메라가 불안정한 상태에서 재초기화 시도
- 충돌 발생 → SIGKILL

#### 해결
**파일**: `ios/Runner/NativeCamera.swift`

1. **권한 체크 추가**:
   ```swift
   // onAppDidBecomeActive() 시작 시 권한 체크
   let authStatus = AVCaptureDevice.authorizationStatus(for: .video)
   if authStatus == .denied || authStatus == .restricted {
       // 권한이 없으면 자동 재초기화 건너뛰기
       return
   }
   ```

2. **플래그 기반 제어**:
   ```swift
   private var shouldSkipAutoReinit = false
   
   // 0.2초 후 재확인 시 플래그 체크
   if self.shouldSkipAutoReinit {
       // 설정에서 복귀한 경우 자동 재초기화 건너뛰기
       self.shouldSkipAutoReinit = false
       return
   }
   ```

3. **권한 상태 재확인**:
   ```swift
   // 0.2초 후에도 권한 상태 재확인 (권한 변경 가능성 대비)
   let authStatusAfterDelay = AVCaptureDevice.authorizationStatus(for: .video)
   if authStatusAfterDelay == .denied || authStatusAfterDelay == .restricted {
       return
   }
   ```

### 2. Flutter에서 네이티브에 플래그 전달

#### 해결
**파일**: `lib/widgets/permission_wrapper.dart`

1. **설정으로 이동하기 전 플래그 설정**:
   ```dart
   // "설정으로 이동" 버튼 클릭 시
   const cameraChannel = MethodChannel('petgram/native_camera');
   await cameraChannel.invokeMethod('setSkipAutoReinit', {'skip': true});
   ```

2. **설정에서 복귀 후 플래그 리셋**:
   ```dart
   // resumed 상태에서 _returnedFromSettings가 true일 때
   Future.microtask(() async {
     const cameraChannel = MethodChannel('petgram/native_camera');
     await cameraChannel.invokeMethod('setSkipAutoReinit', {'skip': false});
   });
   ```

### 3. 네이티브 메서드 추가

**파일**: `ios/Runner/NativeCamera.swift`

```swift
case "setSkipAutoReinit":
    guard let args = call.arguments as? [String: Any] else {
        result(FlutterError(code: "INVALID_ARGUMENT", message: "Invalid arguments", details: nil))
        return
    }
    let skip = args["skip"] as? Bool ?? false
    cameraVC.shouldSkipAutoReinit = skip
    result(nil)
```

## 동작 흐름

### 정상 흐름 (권한 변경 없음)
1. 사용자가 "설정으로 이동" 버튼 클릭
2. `setSkipAutoReinit(true)` 호출 → 네이티브 플래그 설정
3. 설정 앱으로 이동
4. 네이티브 카메라: `willResignActive` → cleanup 시작
5. 네이티브 카메라: `didEnterBackground` → cleanup 완료
6. 사용자가 설정에서 권한 변경 없이 복귀
7. `didBecomeActive` 호출 → 권한 체크 통과
8. `shouldSkipAutoReinit = true` 체크 → 자동 재초기화 건너뛰기
9. Flutter: `resumed` 상태 → 플래그 리셋
10. 다음 카메라 사용 시 정상 초기화

### 권한 변경 시 흐름
1. 사용자가 "설정으로 이동" 버튼 클릭
2. `setSkipAutoReinit(true)` 호출 → 네이티브 플래그 설정
3. 설정 앱으로 이동
4. 네이티브 카메라: `willResignActive` → cleanup 시작
5. 네이티브 카메라: `didEnterBackground` → cleanup 완료
6. 사용자가 설정에서 권한 변경 후 복귀
7. `didBecomeActive` 호출
8. **권한 체크 실패** 또는 **`shouldSkipAutoReinit = true` 체크** → 자동 재초기화 건너뛰기 ✅
9. Flutter: `resumed` 상태 → 다이얼로그 닫기, 플래그 리셋
10. 다음 카메라 사용 시 권한 상태 확인 후 초기화

## 핵심 개선사항

1. **다층 방어**: 권한 체크 + 플래그 기반 제어 + 상태 재확인
2. **타이밍 문제 해결**: 0.2초 딜레이 전과 후 모두 권한 체크
3. **Flutter-Native 협조**: Flutter에서 네이티브에 명시적으로 플래그 전달
4. **안전한 복귀**: 설정에서 복귀 후 네이티브 카메라가 안전하게 대기

## 테스트 체크리스트

- [ ] 권한 변경 없이 설정에서 복귀 → 정상 동작 확인
- [ ] 권한 허용 후 설정에서 복귀 → 다이얼로그 사라지고 정상 동작
- [ ] 권한 거부 후 설정에서 복귀 → 다이얼로그 유지 및 앱 멈추지 않음
- [ ] 권한 변경 후 카메라 사용 → 정상적으로 권한 체크 및 초기화
- [ ] 로그에서 `setSkipAutoReinit` 호출 확인
- [ ] 로그에서 `SKIPPED auto-reinit` 메시지 확인
