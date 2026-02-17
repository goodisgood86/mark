# 스플래시와 프리뷰 문제 근본 원인 분석

## 문제 현상
1. 스플래시 화면이 사라지지 않음
2. 화면이 들어와도 프리뷰가 안 나옴
3. 두 문제가 연관되어 있음

## 근본 원인 분석

### 1. iOS 스플래시 제거 조건
iOS는 **첫 Flutter 프레임이 실제로 화면에 렌더링**되면 자동으로 스플래시를 제거합니다.

하지만 현재 구조에서는:
- `RootViewController`로 FlutterViewController를 래핑
- Flutter 뷰가 실제로 화면에 표시되지 않으면 스플래시가 사라지지 않음
- `setupRootViewController()`가 `DispatchQueue.main.async`로 지연 실행됨

### 2. 프리뷰가 안 나오는 문제와 스플래시의 연관성

**핵심 발견**: 프리뷰가 안 나오면 Flutter 뷰가 실제로 렌더링되지 않을 수 있고, 이는 스플래시가 사라지지 않는 원인입니다.

#### 현재 구조:
```
RootViewController
├── cameraContainer (배경, 네이티브 카메라)
└── FlutterViewController.view (위, 투명 배경)
    └── HomePage
        └── NativeCameraPreview (iOS에서는 Container만 반환)
```

#### 문제점:
1. `NativeCameraPreview`는 iOS에서 `Container(color: Colors.transparent)`만 반환
2. 실제 카메라 프리뷰는 `RootViewController`의 `cameraContainer`에 표시
3. Flutter 뷰가 실제로 렌더링되지 않으면 스플래시가 사라지지 않음

### 3. 타이밍 문제

#### 현재 흐름:
1. 앱 시작 → 스플래시 표시
2. `AppDelegate.didFinishLaunchingWithOptions` → Flutter 엔진 초기화
3. `setupRootViewController()` → `DispatchQueue.main.async`로 지연 실행
4. `RootViewController.viewDidLoad` → 카메라 컨테이너 설정
5. Flutter 첫 프레임 렌더링 시도
6. **문제**: Flutter 뷰가 실제로 화면에 표시되지 않으면 스플래시가 사라지지 않음
7. `viewDidAppear` → 카메라 초기화 시작
8. **문제**: 카메라 초기화가 완료되어도 스플래시가 이미 막혀있음

### 4. 근본 원인

**핵심 문제**: Flutter 뷰가 실제로 화면에 렌더링되지 않아서 iOS가 스플래시를 제거하지 않음

#### 가능한 원인들:
1. `RootViewController` 설정이 너무 늦게 실행됨 (`DispatchQueue.main.async`)
2. Flutter 뷰의 `backgroundColor`가 투명하여 iOS가 렌더링을 감지하지 못함
3. 카메라 초기화가 완료되기 전까지 Flutter 뷰가 실제로 화면에 표시되지 않음

## 해결 방안

### 방안 1: Flutter 뷰 렌더링 보장 (권장)
- `RootViewController` 설정을 동기적으로 실행
- Flutter 뷰가 실제로 화면에 표시되도록 보장
- 스플래시 제거를 Flutter 뷰 렌더링과 연동

### 방안 2: 스플래시 제거 조건 변경
- 카메라 초기화 완료를 기다리지 않고, Flutter 뷰가 렌더링되면 즉시 제거
- `viewDidAppear`에서 스플래시 강제 제거

### 방안 3: 구조 변경
- `RootViewController` 없이 Flutter 뷰를 직접 사용
- 카메라는 별도 레이어로 관리

## 권장 해결책

1. **`setupRootViewController()`를 동기적으로 실행**하거나 더 빠르게 실행
2. **Flutter 뷰의 렌더링을 보장**하기 위해 `viewDidAppear`에서 스플래시 강제 제거
3. **카메라 초기화와 스플래시 제거를 분리**: 카메라 초기화를 기다리지 않고 Flutter 뷰가 렌더링되면 즉시 스플래시 제거

