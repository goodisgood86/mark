# 핑크 오버레이 및 크래시 문제 근본 해결

## 🔍 발견된 근본 원인

### 1. 재초기화 무한 루프 문제
**원인**:
- `_forceReinitCamera()` 호출 → dispose → PlatformView 재생성 → 새 인스턴스 생성
- 새 인스턴스는 `hasFirstFrame=false`로 시작
- `_pollDebugState()`가 1초마다 호출되면서 `hasFirstFrame=false`를 감지
- `isPinkFallback=true`로 계산됨 (hasCurrentImage=false, renderSuccessCount=0)
- 다시 `pinkFallbackDetected`로 재초기화 호출 → 무한 루프

### 2. 촬영 중 재초기화 문제
**원인**:
- 촬영 중에도 `_pollDebugState()`에서 재초기화 호출 가능
- 재초기화로 세션 객체가 무효화되어 크래시 발생

### 3. 재초기화 후 상태 복구 시간 부족
**원인**:
- 재초기화 완료 후 `_isReinitializing = false`로 즉시 리셋
- 하지만 실제로 `hasFirstFrame=true`가 되기까지는 sampleBuffer가 최소 1개 오고, display가 호출되고, 렌더링이 성공해야 함
- 이 시간 동안 `isPinkFallback=true`로 감지되어 다시 재초기화 호출

## ✅ 적용된 해결책

### 1. 재초기화 후 보호 기간 추가
```dart
DateTime? _lastReinitTime; // 마지막 재초기화 시각

// 재초기화 후 3초간은 PINK FALLBACK 체크 스킵
final timeSinceReinit = _lastReinitTime != null 
    ? DateTime.now().difference(_lastReinitTime!).inSeconds 
    : 999;
final isWithinReinitProtection = timeSinceReinit < 3;

// 재초기화 후 보호 기간 중에는 스킵
if (pinkFallbackDetected && !_isReinitializing && !isCapturing && !isWithinReinitProtection) {
  _forceReinitCamera();
}
```

### 2. 촬영 중 재초기화 차단 강화
```dart
// _pollDebugState()에서 촬영 중 체크
final isCapturing = _isProcessing || _cameraEngine.isCapturingPhoto;
if (sessionLost && !_isReinitializing && !isCapturing) {
  _forceReinitCamera();
}

// canUseCamera 체크에서도 차단
if (!canUseCamera) {
  if (!_isReinitializing && !_isProcessing && !_cameraEngine.isCapturingPhoto) {
    _forceReinitCamera();
  }
  return;
}
```

### 3. 네이티브 초기화 중 촬영 차단
```swift
// _performInitialize() 시작 시 촬영 중이면 차단
guard !self.isCapturingPhoto else {
    self.log("[Native] ❌ _performInitialize blocked: photo capture in progress")
    self.isRunningOperationInProgress = false
    completion(.failure(...))
    return
}
```

### 4. 재초기화 완료 시각 기록
```dart
} finally {
  _isReinitializing = false;
  _lastReinitTime = DateTime.now(); // 보호 기간 시작
  _addDebugLog('[ForceReinit] END: Reinitialization flag reset, protection period started (3s)');
}
```

## 📊 개선 효과

1. **재초기화 무한 루프 방지**: 재초기화 후 3초간 PINK FALLBACK 체크 스킵
2. **크래시 방지**: 촬영 중 재초기화 차단, 네이티브 초기화 중 촬영 차단
3. **상태 복구 시간 확보**: 재초기화 후 첫 프레임 수신 시간 확보

## 🧪 테스트 시나리오

1. **재초기화 후 프리뷰 복구 테스트**
   - 재초기화 발생 → 3초 보호 기간 → 프리뷰 복구 확인

2. **촬영 중 재초기화 차단 테스트**
   - 촬영 시작 → 재초기화 요청 → 차단 확인

3. **무한 루프 방지 테스트**
   - 재초기화 → 보호 기간 중 PINK FALLBACK 감지 → 스킵 확인
