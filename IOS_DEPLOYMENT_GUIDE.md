# iOS 배포 가이드

## ✅ 빌드 확인 완료

- Release 빌드 성공: `build/ios/iphoneos/Runner.app` (33.0MB)
- 버전: 1.0.0+7

## 📋 배포 전 체크리스트

### 1. Xcode 프로젝트 설정 확인

```bash
open ios/Runner.xcworkspace
```

Xcode에서 확인할 사항:

- [ ] Bundle Identifier 설정 (예: `com.mark.petgram`)
- [ ] Signing & Capabilities에서 Team 선택
- [ ] Deployment Target 확인 (최소 iOS 버전)
- [ ] Version 및 Build Number 확인 (1.0.0, 7)

### 2. 권한 설정 확인 (Info.plist)

✅ 다음 권한이 이미 설정되어 있습니다:

- `NSCameraUsageDescription` - 카메라 권한
- `NSPhotoLibraryAddUsageDescription` - 갤러리 저장 권한
- `NSPhotoLibraryUsageDescription` - 갤러리 읽기 권한
- `NSLocationWhenInUseUsageDescription` - 위치 정보 권한

### 3. App Store Connect 설정

1. [App Store Connect](https://appstoreconnect.apple.com) 접속
2. 새 앱 생성 또는 기존 앱 선택
3. 앱 정보 입력:
   - 이름: Petgram
   - 기본 언어: 한국어
   - 번들 ID: `com.mark.petgram` (실제 번들 ID로 변경)
   - SKU: 고유 식별자

### 4. Archive 및 업로드

#### 방법 1: Xcode를 통한 배포 (권장)

```bash
# Xcode 열기
open ios/Runner.xcworkspace
```

Xcode에서:

1. Product → Destination → Any iOS Device 선택
2. Product → Archive 실행
3. Organizer 창에서:
   - Validate App 클릭 (검증)
   - Distribute App 클릭 (배포)
   - App Store Connect 선택
   - 업로드 완료

#### 방법 2: 명령어를 통한 배포

```bash
# Archive 생성
flutter build ipa --release

# 생성된 IPA 파일 위치
# build/ios/ipa/mark_v2.ipa
```

그 다음:

1. [Transporter 앱](https://apps.apple.com/app/transporter/id1450874784) 사용
2. 또는 Xcode Organizer에서 수동 업로드

### 5. 테스트 빌드 (TestFlight)

1. App Store Connect에서 TestFlight 탭으로 이동
2. 빌드 업로드 후 테스터 초대
3. 테스트 완료 후 App Store 심사 제출

## 🔧 빌드 명령어

### Release 빌드 (코드사인 없음)

```bash
flutter build ios --release --no-codesign
```

### IPA 파일 생성 (코드사인 필요)

```bash
flutter build ipa --release
```

### 특정 구성으로 빌드

```bash
flutter build ios --release --flavor production
```

## ⚠️ 주의사항

### 코드사인

- 배포용 빌드는 반드시 코드사인이 필요합니다
- Xcode에서 Team을 선택하면 자동으로 코드사인됩니다
- 또는 `--codesign` 옵션 사용

### 버전 관리

- `pubspec.yaml`의 `version: 1.0.0+7` 확인
- App Store Connect의 버전과 일치해야 합니다

### 최소 iOS 버전

- 현재 설정된 최소 iOS 버전 확인 필요
- `ios/Podfile`에서 `platform :ios` 확인

## 📱 배포 후 확인 사항

1. [ ] 앱이 정상적으로 설치되는지 확인
2. [ ] 카메라 권한 요청 정상 동작
3. [ ] 갤러리 저장 정상 동작
4. [ ] 위치 정보 권한 정상 동작
5. [ ] 모든 비율 모드(1:1, 3:4, 9:16) 정상 동작
6. [ ] 프레임 오버레이 정상 표시
7. [ ] 필터 및 밝기 조절 정상 동작

## 🚀 빠른 배포 명령어

```bash
# 1. 코드 정리 및 의존성 확인
flutter clean
flutter pub get

# 2. iOS 빌드
flutter build ios --release

# 3. Xcode에서 Archive 및 업로드
open ios/Runner.xcworkspace
```

## 📝 현재 설정 요약

- **앱 이름**: Petgram
- **버전**: 1.0.0+7
- **Bundle ID**: `com.mark.petgram` ✅
- **최소 iOS 버전**: 15.5
- **권한**: 카메라, 갤러리, 위치 정보 ✅
- **빌드 상태**: ✅ 성공 (33.0MB)
