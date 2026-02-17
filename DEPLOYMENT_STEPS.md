# 🚀 배포 단계 가이드

## ✅ 빌드 완료 상태

### iOS 빌드 ✅
- **빌드 경로**: `build/ios/iphoneos/Runner.app`
- **빌드 크기**: 33.0MB
- **상태**: 성공적으로 빌드 완료
- **버전**: 1.0.0+4

### Android 빌드
- 아직 빌드하지 않음 (필요 시 `flutter build appbundle` 실행)

---

## 📱 iOS 배포 (App Store)

### 1단계: Xcode에서 Archive 생성

```bash
# Xcode 열기
open ios/Runner.xcworkspace
```

**Xcode에서:**
1. 상단 메뉴에서 **Product > Destination > Any iOS Device** 선택
2. **Product > Archive** 클릭
3. Archive 완료까지 대기 (몇 분 소요)

### 2단계: App Store Connect에 업로드

Archive 완료 후:
1. **Distribute App** 버튼 클릭
2. **App Store Connect** 선택
3. **Upload** 선택
4. 다음 단계 진행:
   - Distribution options: 기본값 유지
   - App Thinning: All compatible device variants
   - Re-sign: 필요 시 자동으로 처리
5. **Upload** 클릭하여 업로드 시작

### 3단계: App Store Connect 설정

1. [App Store Connect](https://appstoreconnect.apple.com) 접속
2. **내 앱** 클릭
3. 앱이 없으면 **+** 버튼으로 새 앱 만들기:
   - **플랫폼**: iOS
   - **이름**: Petgram
   - **기본 언어**: 한국어
   - **번들 ID**: `com.mark.petgram` 선택
   - **SKU**: `petgram-001` (고유한 값)
4. **앱 정보** 입력:
   - 카테고리: 사진/비디오
   - 콘텐츠 권한: 연령 등급 설정
5. **스크린샷** 업로드 (최소 2장, 권장 5장)
6. **앱 설명** 입력
7. 업로드한 **빌드 선택**
8. **검토를 위해 제출** 클릭

---

## 🤖 Android 배포 (Google Play Store)

### 1단계: App Bundle 빌드

```bash
cd /Users/grepp/mark_v2
flutter build appbundle
```

**결과물**: `build/app/outputs/bundle/release/app-release.aab`

### 2단계: Google Play Console에 업로드

1. [Google Play Console](https://play.google.com/console) 접속
2. **앱 만들기** 클릭 (앱이 없는 경우)
3. 앱 정보 입력:
   - 앱 이름: Petgram
   - 기본 언어: 한국어
   - 앱 또는 게임: 앱
   - 무료 또는 유료: 선택
4. **프로덕션** 트랙으로 이동
5. **새 버전 만들기** 클릭
6. **앱 번들 업로드** 클릭
7. `app-release.aab` 파일 업로드
8. **릴리스 노트** 입력
9. **검토 제출** 클릭

---

## 📋 배포 전 최종 체크리스트

### iOS
- [x] iOS 빌드 완료
- [ ] Xcode에서 Archive 생성
- [ ] App Store Connect에 업로드
- [ ] 앱 정보 입력 완료
- [ ] 스크린샷 업로드 완료
- [ ] 검토 제출 완료

### Android
- [ ] Android App Bundle 빌드
- [ ] Google Play Console에 업로드
- [ ] 앱 정보 입력 완료
- [ ] 스크린샷 업로드 완료
- [ ] 검토 제출 완료

---

## 🎯 다음 단계

### iOS 배포
1. Xcode 열기: `open ios/Runner.xcworkspace`
2. Product > Archive 실행
3. App Store Connect에 업로드
4. App Store Connect에서 앱 정보 입력 및 제출

### Android 배포
1. `flutter build appbundle` 실행
2. Google Play Console에 업로드
3. 앱 정보 입력 및 제출

---

## 📝 참고사항

### 현재 설정
- **앱 이름**: Petgram
- **버전**: 1.0.0+4
- **iOS Bundle ID**: `com.mark.petgram`
- **Android 패키지명**: `com.mark.petgram`

### 버전 업데이트
다음 업데이트 시 `pubspec.yaml`에서:
```yaml
version: 1.0.1+5  # 버전명+빌드번호
```

---

## 🎉 배포 준비 완료!

iOS 빌드가 완료되었습니다. 이제 Xcode에서 Archive하고 App Store Connect에 업로드하면 됩니다!

