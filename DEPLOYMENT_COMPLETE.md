# iOS 배포 완료 (Build 7)

## 배포 상태

✅ **Archive 생성 완료**
✅ **Export 완료**

## 생성된 파일 위치

- **Archive**: `~/Library/Developer/Xcode/Archives/2025-11-26/Runner 11-26-25, 8.43 PM.xcarchive`
- **Export**: `/Users/grepp/mark_v2/ios/build/export/`

## 다음 단계: App Store Connect 업로드

### 방법 1: Xcode Organizer 사용 (권장)

1. Xcode 열기
2. Window > Organizer 선택
3. Archives 탭에서 방금 생성된 Archive 선택
4. "Distribute App" 버튼 클릭
5. "App Store Connect" 선택
6. 업로드 옵션 선택 후 진행

### 방법 2: Transporter 앱 사용

1. Mac App Store에서 "Transporter" 앱 다운로드
2. Transporter 앱 열기
3. `/Users/grepp/mark_v2/ios/build/export/` 폴더의 `.ipa` 파일 드래그 앤 드롭
4. "Deliver" 버튼 클릭

### 방법 3: 명령줄 (API 키 필요)

```bash
cd /Users/grepp/mark_v2/ios/build/export
xcrun altool --upload-app \
  --type ios \
  --file "*.ipa" \
  --apiKey "YOUR_API_KEY" \
  --apiIssuer "YOUR_ISSUER_ID"
```

## 배포 정보

- **버전**: 1.0.0
- **빌드 번호**: 7
- **배포 날짜**: 2025-11-26

## 주요 변경 사항

1. 프리뷰와 촬영본 프레임 위치 동기화 (정규화 비율 적용)
2. 프리뷰 박스 비율 개선 (1:1, 3:4, 9:16 정확히 표시)
3. 프레임 오버레이 위치 정확도 개선
4. 필터 선택 깜박임 문제 해결

## 확인 사항

- [ ] App Store Connect에 업로드 완료
- [ ] 버전 정보 확인
- [ ] 스크린샷 업데이트 (필요시)
- [ ] 앱 설명 확인
- [ ] 심사 제출
