# iOS 배포 체크리스트 (Build 7)

## 버전 정보

- **버전**: 1.0.0
- **빌드 번호**: 7
- **배포 날짜**: $(date)

## 주요 변경 사항

1. 프리뷰와 촬영본의 프레임 위치 동기화

   - 정규화 비율 기반 계산으로 프리뷰와 촬영본의 프레임 위치 일치
   - `overlayTop / imageHeight = normalizedTop` 공식 적용
   - 프리뷰 박스 로컬 좌표계 사용

2. 프리뷰 박스 비율 개선

   - targetRatio 기반 previewBoxW/previewBoxH 계산
   - 1:1, 3:4, 9:16 비율 정확히 표시
   - 카메라 비율 왜곡 없이 프리뷰 표시

3. 프레임 오버레이 위치 정확도 개선

   - 프리뷰 박스 내부 로컬 좌표계 사용
   - 화면 기준 좌표와 분리하여 정확한 위치 계산

4. 필터 선택 깜박임 문제 해결
   - 카테고리 변경 시 필터 선택 로직 개선
   - 필터 버튼에 Key 추가하여 상태 변경 즉시 반영
   - 이전 필터와 새 필터 동시 선택 문제 해결

## 사전 배포 체크리스트

### 1. 코드 품질

- [x] Linter 오류 확인 (경고 3개, Info 25개, 에러 없음)
- [x] `flutter analyze` 통과 (에러 없음)
- [x] 주요 기능 테스트 완료
- [x] 프리뷰와 촬영본 프레임 위치 동기화 확인
- [x] 필터 선택 깜박임 문제 해결 확인

### 2. iOS 설정

- [x] Info.plist 권한 설정 확인
  - NSCameraUsageDescription
  - NSPhotoLibraryAddUsageDescription
  - NSPhotoLibraryUsageDescription
  - NSLocationWhenInUseUsageDescription
  - NSLocationAlwaysAndWhenInUseUsageDescription
- [x] CFBundleDisplayName: Petgram
- [x] 버전 번호: 1.0.0+7

### 3. 빌드 준비

- [x] `flutter clean` 실행 완료
- [x] `flutter pub get` 실행 완료
- [x] iOS 빌드 테스트 완료 (이전 빌드 성공)

### 4. 기능 테스트

- [ ] 카메라 프리뷰 정상 작동
- [ ] 프레임 오버레이 위치 정확성 (프리뷰와 촬영본 일치)
- [ ] 1:1, 3:4, 9:16 비율 모두 정상 표시
- [ ] 촬영 및 저장 기능
- [ ] 필터 적용 (깜박임 문제 해결 확인)
- [ ] 위치 정보 표시
- [ ] 인앱 결제 (테스트)

### 5. 성능 체크

- [ ] 메모리 누수 없음
- [ ] 카메라 프리뷰 부드러움
- [ ] 이미지 처리 속도

### 6. 배포 전 최종 확인

- [ ] 실제 기기에서 테스트 완료
- [ ] 다양한 iPhone 모델에서 테스트 (선택사항)
- [ ] App Store Connect 업로드 준비

## 배포 명령어

### 1. iOS 빌드 (Release)

```bash
cd /Users/grepp/mark_v2
flutter clean
flutter pub get
flutter build ios --release
```

### 2. Xcode에서 Archive

1. Xcode에서 `ios/Runner.xcworkspace` 열기
2. Product > Archive 선택
3. Archive 완료 후 Distribute App 선택
4. App Store Connect에 업로드

### 3. App Store Connect

- [ ] 버전 정보 입력
- [ ] 스크린샷 업로드
- [ ] 앱 설명 작성
- [ ] 심사 제출

## 알려진 이슈

- 경고: `_lastTapPosition` 미사용 변수 (기능에 영향 없음)
- 경고: `actualOverlayBottom` 미사용 변수 (기능에 영향 없음)
- 경고: `overlayBottom` 미사용 변수 (기능에 영향 없음)

## 다음 배포 예정 사항

- 경고 제거
- 추가 기능 개선
