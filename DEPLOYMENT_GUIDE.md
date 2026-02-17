# 배포 가이드

## 📋 배포 전 확인사항

### 현재 설정

- **앱 버전**: 1.0.0+1
- **Android 패키지명**: `com.example.mark_v2`
- **iOS Bundle ID**: `com.example.markV2`
- **iOS Development Team**: VPJHY87G47

### ⚠️ 배포 전 필수 수정사항

1. **패키지명/Bundle ID 변경** (중요!)

   - 현재 `com.example.*`는 예제용입니다
   - 실제 회사/개인 도메인으로 변경 필요
   - 예: `com.yourcompany.petgram` 또는 `com.yourname.petgram`

2. **앱 이름 확인**

   - Android: `android/app/src/main/AndroidManifest.xml`의 `android:label`
   - iOS: `ios/Runner/Info.plist`의 `CFBundleDisplayName` (현재: "Mark V2")

3. **앱 아이콘 및 스플래시 스크린**
   - `assets/images/app_icon.png` 확인
   - `assets/images/splash.png` 확인

---

## 🤖 Android 배포 (Google Play Store)

### 1. 패키지명 변경 (필수)

```bash
# android/app/build.gradle.kts 파일에서
applicationId = "com.yourcompany.petgram"  # 변경 필요
```

### 2. 서명 키 생성 (처음 한 번만)

```bash
cd android
keytool -genkey -v -keystore ~/upload-keystore.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload
```

### 3. 서명 설정 파일 생성

`android/key.properties` 파일 생성:

```properties
storePassword=<위에서 입력한 비밀번호>
keyPassword=<위에서 입력한 비밀번호>
keyAlias=upload
storeFile=<키스토어 파일 경로>
```

### 4. build.gradle.kts에 서명 설정 추가

`android/app/build.gradle.kts`의 `android` 섹션에 추가:

```kotlin
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
```

### 5. App Bundle 빌드

```bash
flutter build appbundle
```

결과물: `build/app/outputs/bundle/release/app-release.aab`

### 6. Google Play Console에 업로드

1. [Google Play Console](https://play.google.com/console) 접속
2. 새 앱 만들기
3. 앱 번들 (.aab) 업로드
4. 스토어 정보 입력 (설명, 스크린샷 등)
5. 검토 제출

---

## 🍎 iOS 배포 (App Store)

### 1. Bundle ID 변경 (필수)

Xcode에서:

1. `ios/Runner.xcodeproj` 열기
2. Runner 타겟 선택
3. Signing & Capabilities 탭
4. Bundle Identifier를 실제 ID로 변경

### 2. Xcode에서 설정 확인

1. Xcode에서 `ios/Runner.xcodeproj` 열기
2. **Signing & Capabilities** 확인:
   - Team: VPJHY87G47 (또는 본인 팀)
   - Bundle Identifier: 실제 ID로 변경
   - Automatically manage signing 체크

### 3. iOS 빌드

```bash
flutter build ios --release
```

### 4. Xcode에서 Archive 및 업로드

1. Xcode에서 **Product > Archive**
2. Archive 완료 후 **Distribute App** 클릭
3. **App Store Connect** 선택
4. 업로드 완료

### 5. App Store Connect에서 설정

1. [App Store Connect](https://appstoreconnect.apple.com) 접속
2. 새 앱 만들기 (Bundle ID와 일치해야 함)
3. 앱 정보 입력 (설명, 스크린샷, 가격 등)
4. 제출 및 검토 대기

---

## 🧪 테스트 빌드

### Android APK (테스트용)

```bash
flutter build apk --release
```

결과물: `build/app/outputs/flutter-apk/app-release.apk`

### iOS (TestFlight)

1. Xcode에서 Archive
2. TestFlight에 업로드
3. 베타 테스터 초대

---

## ✅ 배포 전 체크리스트

- [ ] 패키지명/Bundle ID를 실제 도메인으로 변경
- [ ] 앱 이름 확인 및 변경
- [ ] 앱 아이콘 확인
- [ ] 스플래시 스크린 확인
- [ ] 실제 기기에서 테스트
- [ ] 모든 권한이 정상 작동하는지 확인
- [ ] 카메라 기능 테스트
- [ ] 갤러리 저장 기능 테스트
- [ ] 필터 적용 테스트
- [ ] 프레임 적용 테스트
- [ ] 인앱 결제 테스트 (해당되는 경우)

---

## 📝 참고사항

### 버전 업데이트

다음 배포 시 `pubspec.yaml`에서 버전 업데이트:

```yaml
version: 1.0.1+2 # 버전명+빌드번호
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

### Android 서명 오류

- `key.properties` 파일 경로 확인
- 키스토어 비밀번호 확인

### iOS 서명 오류

- Xcode에서 Signing & Capabilities 확인
- Development Team 확인
- Bundle ID가 App Store Connect와 일치하는지 확인

### 빌드 실패

```bash
flutter clean
flutter pub get
flutter build [platform] --release
```
