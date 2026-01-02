/// 화면 비율 모드
enum AspectRatioMode { nineSixteen, threeFour, oneOne }

/// 비율 모드에 따른 실제 비율 값 반환
double aspectRatioOf(AspectRatioMode mode) {
  switch (mode) {
    case AspectRatioMode.nineSixteen:
      return 9.0 / 16.0;
    case AspectRatioMode.threeFour:
      return 3.0 / 4.0;
    case AspectRatioMode.oneOne:
      return 1.0;
  }
}

