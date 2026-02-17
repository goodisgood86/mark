# 🔍 iOS 서명 문제 체크리스트 (유료 계정)

## ✅ 단계별 확인 사항

### 1단계: Xcode 계정 확인

#### Xcode > Preferences > Accounts
1. **Apple ID 확인**
   - [ ] Apple Developer Program 가입된 Apple ID로 로그인되어 있는지 확인
   - [ ] 여러 계정이 있다면 올바른 계정 선택

2. **Team 확인**
   - [ ] Team 목록에 가입된 팀이 표시되는지 확인
   - [ ] Team ID가 올바른지 확인 (VPJHY87G47)
   - [ ] Team 이름이 올바른지 확인

3. **Role 확인**
   - [ ] Account Holder 또는 Admin 권한인지 확인
   - [ ] Member만 있으면 App Store 배포 불가

---

### 2단계: Xcode 프로젝트 설정

#### Signing & Capabilities
1. **Runner 타겟 선택**
   - [ ] 왼쪽에서 Runner 프로젝트 선택
   - [ ] TARGETS에서 Runner 선택
   - [ ] Signing & Capabilities 탭 클릭

2. **Team 선택**
   - [ ] Team 드롭다운에서 올바른 팀 선택
   - [ ] "youngmin lee"가 아닌 올바른 팀 선택
   - [ ] Team 선택 후 오류 메시지 확인

3. **Automatically manage signing**
   - [ ] 체크박스 선택
   - [ ] 체크 후 Xcode가 자동으로 처리하는지 확인

4. **Bundle Identifier**
   - [ ] `com.mark.petgram` 확인
   - [ ] Apple Developer 계정에 등록되어 있는지 확인

---

### 3단계: Apple Developer 웹사이트 확인

#### [developer.apple.com/account](https://developer.apple.com/account)

1. **Certificates 확인**
   - [ ] Certificates, Identifiers & Profiles 접속
   - [ ] Certificates > Production 확인
   - [ ] iOS Distribution 인증서가 있는지 확인
   - [ ] 인증서가 만료되지 않았는지 확인

2. **Identifiers 확인**
   - [ ] Identifiers 클릭
   - [ ] `com.mark.petgram`이 등록되어 있는지 확인
   - [ ] 없으면 + 버튼으로 새로 등록

3. **Profiles 확인**
   - [ ] Profiles > Production 확인
   - [ ] `com.mark.petgram`용 App Store 프로파일이 있는지 확인
   - [ ] 없으면 Xcode에서 자동 생성되거나 수동 생성 필요

---

### 4단계: Bundle ID 등록 확인

#### Bundle ID가 등록되지 않은 경우
1. **Apple Developer 웹사이트에서 등록**
   - [developer.apple.com/account](https://developer.apple.com/account) 접속
   - Certificates, Identifiers & Profiles > Identifiers
   - + 버튼 클릭
   - App 선택
   - Bundle ID: `com.mark.petgram` 입력
   - Capabilities 설정 (필요한 경우)
   - Register 클릭

2. **또는 Xcode에서 자동 등록**
   - Automatically manage signing 체크
   - Team 선택
   - Xcode가 자동으로 Bundle ID 등록 시도

---

### 5단계: 인증서 및 프로파일 재생성

#### Xcode에서 자동 생성
1. **Signing & Capabilities에서**
   - Automatically manage signing 체크 해제
   - 다시 체크
   - Team 선택
   - Xcode가 자동으로 생성 시도

2. **수동으로 다운로드**
   - Xcode > Preferences > Accounts
   - Apple ID 선택
   - Team 선택
   - **Download Manual Profiles** 클릭

---

## 🔧 일반적인 해결 방법

### 방법 1: Xcode 완전 재설정
```bash
# 1. Xcode 완전 종료
# 2. Derived Data 삭제
rm -rf ~/Library/Developer/Xcode/DerivedData

# 3. Xcode 다시 열기
open ios/Runner.xcodeproj
```

### 방법 2: 프로비저닝 프로파일 수동 다운로드
1. Xcode > Preferences > Accounts
2. Apple ID 선택
3. Team 선택
4. **Download Manual Profiles** 클릭
5. Xcode 재시작

### 방법 3: Bundle ID 수동 등록
1. [Apple Developer](https://developer.apple.com/account) 접속
2. Certificates, Identifiers & Profiles > Identifiers
3. + 버튼 > App 선택
4. Bundle ID: `com.mark.petgram` 입력
5. Register

### 방법 4: 인증서 확인 및 재생성
1. [Apple Developer](https://developer.apple.com/account) 접속
2. Certificates, Identifiers & Profiles > Certificates
3. Production > iOS Distribution 확인
4. 없으면 + 버튼으로 생성

---

## 🎯 가장 가능성 높은 원인

### 1. Bundle ID 미등록
- `com.mark.petgram`이 Apple Developer 계정에 등록되지 않음
- **해결**: Apple Developer 웹사이트에서 수동 등록

### 2. 잘못된 Team 선택
- "youngmin lee" 팀이 App Store 배포 권한 없음
- **해결**: 올바른 팀 선택 (Account Holder/Admin 권한)

### 3. 인증서 만료 또는 없음
- iOS Distribution 인증서가 없거나 만료됨
- **해결**: Xcode에서 자동 생성 또는 수동 생성

### 4. Xcode 계정 동기화 문제
- Xcode가 Apple Developer 계정과 동기화되지 않음
- **해결**: Xcode > Preferences > Accounts에서 재로그인

---

## 📝 확인 순서

1. ✅ Xcode > Preferences > Accounts에서 올바른 Apple ID 로그인 확인
2. ✅ 올바른 Team 선택 확인 (Account Holder/Admin 권한)
3. ✅ Signing & Capabilities에서 Team 선택 확인
4. ✅ Bundle ID `com.mark.petgram`이 Apple Developer에 등록되어 있는지 확인
5. ✅ Automatically manage signing 체크 확인
6. ✅ Xcode 재시작 후 다시 시도

---

## 💡 빠른 해결 팁

### 가장 빠른 해결 방법
1. **Xcode 완전 종료**
2. **Xcode > Preferences > Accounts**
3. **Apple ID 제거 후 다시 추가**
4. **올바른 Team 선택**
5. **Xcode 재시작**
6. **Signing & Capabilities에서 Team 선택**
7. **Automatically manage signing 체크**

이렇게 하면 대부분의 문제가 해결됩니다!

