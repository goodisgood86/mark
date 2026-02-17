# 🔄 리팩토링 완료 계획

## 현재 진행 상황

✅ 완료:
1. RootViewController.swift 생성
2. AppDelegate 수정 (RootViewController 설정)
3. CameraManager.swift 생성
4. RootViewController와 CameraManager 연결 준비

## 전체 리팩토링 작업 목록

### 단계 1: RootViewController 구조 완성 ✅
- RootViewController 생성
- AppDelegate에서 RootViewController 설정
- CameraManager 생성

### 단계 2: NativeCameraViewController 수정
- loadView() 단순화 (PlatformView 구조 제거)
- SafeOuterContainer, SafeRootView 등 PlatformView용 래퍼 제거
- 카메라 프리뷰를 직접 cameraContainer에 추가하는 구조로 변경

### 단계 3: PlatformView 완전 제거
- NativeCameraView 클래스 삭제
- FlutterPlatformViewFactory 구현 제거
- PlatformView 등록 코드 제거

### 단계 4: MethodChannel 단순화
- viewId 개념 제거
- 전역 카메라 인스턴스로 직접 접근
- CameraManager를 통한 카메라 제어

### 단계 5: Flutter UI 변경
- NativeCameraPreview 위젯 제거
- home_page.dart에서 투명 배경으로 변경
- 카메라 제어는 MethodChannel만 사용

### 단계 6: 코드 정리
- 불필요한 GeometrySafety 코드 정리
- PlatformView 관련 주석/코드 삭제
- SafeCALayer, SafeStandardLayer 등 불필요한 방어 코드 정리

## 주의사항

이 리팩토링은 매우 큰 작업입니다. 각 단계마다:
- 빌드 가능한 상태 유지
- 기존 기능 손실 없음 확인
- 테스트 가능한 상태 유지

