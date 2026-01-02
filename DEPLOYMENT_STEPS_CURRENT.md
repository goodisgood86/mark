# 🚀 현재 배포 단계 (v1.0.0+8)

## 📱 현재 설정

- **앱 이름**: Petgram
- **버전**: 1.0.0+8
- **iOS Bundle ID**: `com.mark.petgram`
- **Android Package**: `com.mark.petgram`

## 🍎 iOS 배포 (App Store)

### 1. iOS Release 빌드

```bash
flutter build ios --release
```

### 2. Xcode에서 Archive 및 업로드

1. Xcode에서 `ios/Runner.xcworkspace` 열기
2. **Product > Scheme > Runner** 선택
3. **Product > Destination > Any iOS Device** 선택
4. **Product > Archive** 클릭
5. Archive 완료 후 **Distribute App** 클릭
6. **App Store Connect** 선택
7. 업로드 완료

### 3. App Store Connect에서 설정

1. [App Store Connect](https://appstoreconnect.apple.com) 접속
2. 앱 정보 입력 (설명, 스크린샷 등)
3. 제출 및 검토 대기

---

## 🤖 Android 배포 (Google Play Store)

### 1. Android App Bundle 빌드

```bash
flutter build appbundle --release
```

결과물: `build/app/outputs/bundle/release/app-release.aab`

### 2. Google Play Console에 업로드

1. [Google Play Console](https://play.google.com/console) 접속
2. 앱 선택 또는 새 앱 만들기
3. Production 또는 Internal testing에 앱 번들 업로드
4. 앱 정보 입력
5. 검토 제출

---

## 🧪 테스트 빌드 (선택사항)

### Android APK (테스트용)

```bash
flutter build apk --release
```

결과물: `build/app/outputs/flutter-apk/app-release.apk`

---

## ✅ 배포 전 최종 확인

- [x] 디버그 오버레이 활성화 (릴리즈 빌드에서도 표시)
- [x] 카메라 초기화 로깅 추가
- [x] 권한 체크 로직 추가
- [x] 린트 에러 0개
- [ ] 실기기에서 최종 테스트
- [ ] 앱 아이콘 확인
- [ ] 스플래시 스크린 확인

---

**배포 준비 완료!** 위의 빌드 명령어를 실행하여 배포를 진행하세요.

