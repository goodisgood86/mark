# 🔐 iOS 서명 문제 해결 가이드

## 현재 오류
- Team "youngmin lee"가 iOS App Store provisioning profile 생성 권한 없음
- iOS Distribution 인증서 없음
- Team ID: VPJHY87G47

---

## 해결 방법

### 방법 1: Xcode에서 자동 서명 설정 (권장)

1. **Xcode 열기**
   ```bash
   open ios/Runner.xcodeproj
   ```

2. **Signing & Capabilities 설정**
   - 왼쪽에서 **Runner** 프로젝트 선택
   - **TARGETS**에서 **Runner** 선택
   - **Signing & Capabilities** 탭 클릭

3. **Team 선택**
   - **Team** 드롭다운에서 올바른 팀 선택
   - **Apple Developer 계정이 있는 팀** 선택
   - 만약 팀이 없다면:
     - Xcode > Preferences > Accounts
     - 왼쪽 하단 **+** 버튼 클릭
     - Apple ID로 로그인

4. **Automatically manage signing 체크**
   - 체크박스 선택
   - Xcode가 자동으로 인증서와 프로비저닝 프로파일 생성

5. **Bundle Identifier 확인**
   - `com.mark.petgram` 확인

---

### 방법 2: Apple Developer 계정 확인

#### Apple Developer Program 가입 확인
1. [Apple Developer](https://developer.apple.com) 접속
2. 로그인 후 **Membership** 확인
3. **Apple Developer Program**에 가입되어 있는지 확인
   - 가입되어 있지 않으면: $99/년 가입 필요
   - 가입되어 있으면: Team ID 확인

#### 팀 권한 확인
- **Account Holder** 또는 **Admin** 권한이 있어야 함
- **Member** 권한만 있으면 App Store 배포 불가

---

### 방법 3: 수동으로 인증서 생성 (고급)

#### 1. Apple Developer 웹사이트에서
1. [Apple Developer](https://developer.apple.com/account) 접속
2. **Certificates, Identifiers & Profiles** 클릭
3. **Certificates** > **+** 클릭
4. **iOS App Store and Ad Hoc** 선택
5. CSR 파일 업로드 (Keychain Access에서 생성)

#### 2. Keychain Access에서 CSR 생성
1. **Keychain Access** 앱 열기
2. **Keychain Access > Certificate Assistant > Request a Certificate From a Certificate Authority**
3. 이메일 주소 입력
4. **Save to disk** 선택
5. 저장

---

### 방법 4: TestFlight으로 먼저 테스트 (권장)

App Store 배포 전에 TestFlight으로 테스트:

1. **Xcode에서 Archive**
   - **Product > Destination > Any iOS Device**
   - **Product > Archive**

2. **TestFlight에 업로드**
   - Archive 완료 후 **Distribute App** 클릭
   - **TestFlight & App Store** 선택
   - **Upload** 선택
   - 업로드 완료

3. **App Store Connect에서**
   - [App Store Connect](https://appstoreconnect.apple.com) 접속
   - **TestFlight** 탭
   - 내부 테스터로 테스트 가능

---

## 빠른 해결 체크리스트

### 1단계: Xcode 설정 확인
- [ ] Xcode > Preferences > Accounts에서 Apple ID 로그인 확인
- [ ] 올바른 Team 선택 (Apple Developer Program 가입된 팀)
- [ ] Signing & Capabilities에서 Team 선택
- [ ] Automatically manage signing 체크

### 2단계: Apple Developer 계정 확인
- [ ] [Apple Developer](https://developer.apple.com)에서 로그인 가능
- [ ] Apple Developer Program 가입 확인 ($99/년)
- [ ] Team ID 확인 (VPJHY87G47)
- [ ] Account Holder 또는 Admin 권한 확인

### 3단계: 인증서 자동 생성
- [ ] Xcode에서 Automatically manage signing 체크
- [ ] Team 선택 후 자동으로 인증서 생성 대기
- [ ] 오류 메시지 확인 및 해결

---

## 일반적인 오류 해결

### "No signing certificate found"
**해결:**
1. Xcode > Preferences > Accounts
2. Apple ID 선택 > **Download Manual Profiles** 클릭
3. 또는 Automatically manage signing 체크

### "Team does not have permission"
**해결:**
1. Apple Developer 계정에서 권한 확인
2. Account Holder 또는 Admin 권한 필요
3. 팀 관리자에게 권한 요청

### "No profiles found"
**해결:**
1. Xcode에서 Automatically manage signing 체크
2. Team 선택
3. Xcode가 자동으로 프로파일 생성

---

## 다음 단계

1. **Xcode에서 Team 설정 완료**
2. **Archive 다시 시도**
3. **TestFlight으로 먼저 테스트** (권장)
4. **문제 없으면 App Store에 제출**

---

## 참고

- **개인 개발자**: Apple Developer Program 가입 필요 ($99/년)
- **회사 계정**: 회사 Apple Developer 계정 사용
- **무료 계정**: App Store 배포 불가, 개발용으로만 사용 가능

