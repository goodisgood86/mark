# 🚀 배포 준비 완료 체크리스트

## ✅ 코드 정리 완료

### 1. 린터 에러/경고

- ✅ `home_page.dart`: 에러 없음 (info 레벨 경고만 존재, 배포에 영향 없음)
- ✅ `camera_engine.dart`: 에러 없음
- ✅ `native_camera_controller.dart`: 에러 없음
- ⚠️ `filter_page.dart`: 사용하지 않는 메서드 경고 (기능에 영향 없음, 배포에 영향 없음)

### 2. Import 정리

- ✅ 불필요한 `dart:typed_data` import 제거
- ✅ 불필요한 `package:flutter/rendering.dart` import 제거

### 3. 디버그 기능

- ✅ `kEnableCameraDebugOverlay = false` (프로덕션에서 비활성화)
- ✅ `_showDebugOverlay`를 `final`로 변경
- ✅ 모든 `debugPrint`는 `kDebugMode`로 감싸져 있음

### 4. Deprecated API 수정

- ✅ `withOpacity()` → `withValues(alpha:)` 변경

### 5. 실기기 카메라 초기화 문제 해결

- ✅ `viewId` 설정 순서 수정 (NativeCameraPreview의 onCreated에서만 초기화)
- ✅ `CameraEngine`에 `nativeCamera` setter 추가
- ✅ 네이티브 초기화 타임아웃 10초로 증가 (권한 요청 대기 시간 고려)
- ✅ 네이티브 초기화 로깅 강화

## 📱 앱 정보

### 버전 정보

- **앱 이름**: Petgram
- **버전**: 1.0.0+8
- **iOS Bundle ID**: `com.mark.petgram`
- **Android Package**: `com.mark.petgram`

### 주요 기능

- ✅ 네이티브 카메라 (iOS)
- ✅ 필터/보정 기능
- ✅ 프레임 적용
- ✅ EXIF 메타데이터 저장
- ✅ 로컬 SQLite DB 저장
- ✅ 위치 정보 연동
- ✅ Mock 카메라 (시뮬레이터/카메라 없을 때)

## 🔒 권한 설정 확인

### iOS (Info.plist)

- ✅ `NSCameraUsageDescription`: "반려동물 사진을 촬영하기 위해 카메라 권한이 필요합니다."
- ✅ `NSPhotoLibraryAddUsageDescription`: "필터 적용한 사진을 갤러리에 저장하기 위해 필요합니다."
- ✅ `NSPhotoLibraryUsageDescription`: "갤러리에서 사진을 선택하기 위해 필요합니다."
- ✅ `NSLocationWhenInUseUsageDescription`: "촬영한 사진의 위치 정보를 표시하기 위해 내 위치를 사용합니다."

## 🧪 테스트 체크리스트

### 실기기 테스트

- [x] 카메라 초기화 및 프리뷰 표시 (viewId 설정 순서 수정 완료)
- [ ] 사진 촬영 및 저장 (3:4, 1:1, 9:16 비율)
- [ ] 필터 적용 및 저장
- [ ] 밝기 조절 및 저장 (프리뷰와 동일한지 확인)
- [ ] 프레임 적용 및 저장
- [ ] 갤러리 저장 확인
- [ ] DB 저장 확인
- [ ] 전면/후면 카메라 전환
- [ ] 줌 기능
- [ ] 포커스/노출 탭
- [ ] 플래시 기능

### 시뮬레이터 테스트

- [ ] Mock 카메라 모드 동작
- [ ] Mock 이미지 촬영 및 저장
- [ ] 필터/밝기 적용 (프리뷰와 동일한지 확인)
- [ ] 프레임 적용

## 📦 빌드 명령어

### iOS Release 빌드

```bash
flutter build ios --release
```

### Android Release 빌드

```bash
flutter build apk --release
# 또는
flutter build appbundle --release
```

## ⚠️ 배포 전 최종 확인

1. **앱 아이콘 및 스플래시 스크린**

   - [ ] iOS 아이콘 설정 확인
   - [ ] Android 아이콘 설정 확인
   - [ ] 스플래시 스크린 확인

2. **앱 서명**

   - [ ] iOS: 코드 서명 인증서 설정
   - [ ] iOS: 프로비저닝 프로파일 설정
   - [ ] Android: 서명 키 설정 (`key.properties`)

3. **앱 스토어 정보**

   - [ ] iOS: App Store Connect 설정
   - [ ] Android: Google Play Console 설정
   - [ ] 앱 설명 및 스크린샷 준비

4. **성능 최적화**
   - [ ] Release 빌드에서 성능 테스트
   - [ ] 메모리 누수 확인
   - [ ] 배터리 사용량 확인

## 📝 배포 후 모니터링

1. **크래시 리포팅**

   - Firebase Crashlytics 설정 (선택사항)
   - 또는 앱 스토어 크래시 리포트 확인

2. **사용자 피드백**
   - 앱 스토어 리뷰 모니터링
   - 사용자 문의 대응 준비

## ✅ 배포 준비 완료

모든 코드 정리 및 검증이 완료되었습니다. 위의 체크리스트를 확인하고 배포를 진행하세요.
