# 🚀 배포 준비 완료

## ✅ 완료된 작업

### 1. 코드 정리
- ✅ 디버그 로그를 `kDebugMode`로 감싸기 완료
- ✅ 에러 처리 및 메모리 관리 확인 완료

### 2. 패키지 설정
- ✅ **Android 패키지명**: `com.petgram.app`
- ✅ **iOS Bundle ID**: `com.petgram.app`
- ✅ **앱 이름**: `Petgram`

### 3. 빌드 상태
- ✅ iOS 빌드 성공 (32.8MB)
- ⚠️ Android 빌드: Android SDK 설정 필요

---

## 📱 현재 설정 정보

### 앱 정보
- **앱 이름**: Petgram
- **버전**: 1.0.0+1
- **패키지명**: com.petgram.app

### 권한 설정
- ✅ 카메라 권한
- ✅ 갤러리 읽기/쓰기 권한
- ✅ 위치 정보 권한

---

## 🎯 다음 단계

### Android 배포 (Google Play Store)

#### 1. Android SDK 설정
```bash
# 환경 변수 설정 (~/.zshrc 또는 ~/.bash_profile에 추가)
export ANDROID_HOME=$HOME/Library/Android/sdk
export PATH=$PATH:$ANDROID_HOME/tools
export PATH=$PATH:$ANDROID_HOME/platform-tools
```

#### 2. 서명 키 생성 (처음 한 번만)
```bash
cd android
keytool -genkey -v -keystore ~/upload-keystore.jks \
  -keyalg RSA -keysize 2048 -validity 10000 -alias upload
```

#### 3. 서명 설정 파일 생성
`android/key.properties` 파일 생성:
```properties
storePassword=<키스토어 비밀번호>
keyPassword=<키 비밀번호>
keyAlias=upload
storeFile=/Users/grepp/upload-keystore.jks
```

#### 4. build.gradle.kts에 서명 설정 추가
`android/app/build.gradle.kts` 파일의 `android` 섹션에 추가:

```kotlin
android {
    // ... 기존 설정 ...
    
    signingConfigs {
        create("release") {
            val keystoreProperties = Properties()
            val keystorePropertiesFile = rootProject.file("key.properties")
            if (keystorePropertiesFile.exists()) {
                keystoreProperties.load(FileInputStream(keystorePropertiesFile))
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
        }
    }
}
```

#### 5. App Bundle 빌드
```bash
flutter build appbundle
```

#### 6. Google Play Console 업로드
1. [Google Play Console](https://play.google.com/console) 접속
2. 새 앱 만들기
3. 앱 번들 업로드: `build/app/outputs/bundle/release/app-release.aab`
4. 스토어 정보 입력 및 검토 제출

---

### iOS 배포 (App Store)

#### 1. Xcode에서 서명 설정
1. `ios/Runner.xcodeproj`를 Xcode로 열기
2. Runner 타겟 선택
3. **Signing & Capabilities** 탭에서:
   - Team: 본인의 개발자 팀 선택
   - Bundle Identifier: `com.petgram.app` (이미 설정됨)
   - Automatically manage signing 체크

#### 2. Archive 및 업로드
1. Xcode에서 **Product > Archive**
2. Archive 완료 후 **Distribute App** 클릭
3. **App Store Connect** 선택
4. 업로드 완료

#### 3. App Store Connect 설정
1. [App Store Connect](https://appstoreconnect.apple.com) 접속
2. 새 앱 만들기 (Bundle ID: `com.petgram.app`)
3. 앱 정보 입력:
   - 이름: Petgram
   - 카테고리: 사진/비디오
   - 설명, 스크린샷, 가격 등
4. 제출 및 검토 대기

---

## 🧪 테스트 빌드

### Android APK (테스트용)
```bash
flutter build apk --release
```
결과물: `build/app/outputs/flutter-apk/app-release.apk`

### iOS (시뮬레이터/기기)
```bash
flutter run --release
```

---

## ✅ 배포 전 최종 체크리스트

### 필수 확인사항
- [ ] 실제 기기에서 테스트 완료
- [ ] 카메라 촬영 기능 정상 작동
- [ ] 필터 적용 정상 작동
- [ ] 갤러리 저장 정상 작동
- [ ] 프레임 적용 정상 작동
- [ ] 모든 권한 정상 작동
- [ ] 인앱 결제 테스트 (해당되는 경우)

### 스토어 등록 정보 준비
- [ ] 앱 아이콘 (1024x1024)
- [ ] 스크린샷 (최소 2장, 권장 5장)
- [ ] 앱 설명 (한국어/영어)
- [ ] 개인정보 처리방침 URL (필요한 경우)
- [ ] 지원 이메일 주소

---

## 📝 참고사항

### 버전 업데이트
다음 배포 시 `pubspec.yaml`에서 버전 업데이트:
```yaml
version: 1.0.1+2  # 버전명+빌드번호
```

### 빌드 명령어 요약
```bash
# Android
flutter build appbundle          # Play Store용
flutter build apk --release      # 테스트용 APK

# iOS
flutter build ios --release      # iOS 빌드
# 이후 Xcode에서 Archive 필요
```

---

## 🆘 문제 해결

### Android 빌드 오류
- Android SDK 경로 확인: `echo $ANDROID_HOME`
- Android Studio에서 SDK 설치 확인

### iOS 빌드 오류
- Xcode에서 Signing & Capabilities 확인
- Development Team 확인
- Bundle ID가 App Store Connect와 일치하는지 확인

### 일반적인 빌드 오류
```bash
flutter clean
flutter pub get
flutter build [platform] --release
```

---

## 🎉 배포 준비 완료!

모든 설정이 완료되었습니다. 실제 기기에서 테스트 후 스토어에 제출하세요!

