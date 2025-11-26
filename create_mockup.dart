import 'dart:io';
import 'dart:math' as math;
import 'package:image/image.dart' as img;

void main() async {
  // 9:16 비율 이미지 생성 (1080x1920)
  final width = 1080;
  final height = 1920;
  
  // 새 이미지 생성 (어두운 회색 배경)
  final image = img.Image(width: width, height: height);
  
  // 그라데이션 배경 그리기
  for (int y = 0; y < height; y++) {
    // 위에서 아래로 어두운 회색에서 약간 밝은 회색으로
    final ratio = y / height;
    final r = (26 + ratio * 30).toInt();
    final g = (26 + ratio * 30).toInt();
    final b = (26 + ratio * 30).toInt();
    final color = img.ColorRgb8(r, g, b);
    
    for (int x = 0; x < width; x++) {
      image.setPixel(x, y, color);
    }
  }
  
  // 중앙에 원형 패턴 추가
  final centerX = width ~/ 2;
  final centerY = height ~/ 2;
  final radius = (width * 0.3).toInt();
  
  // 여러 개의 원 그리기
  for (int i = 0; i < 5; i++) {
    final r = radius - (i * 40);
    if (r > 0) {
      final alpha = (100 - i * 20).clamp(0, 255);
      final color = img.ColorRgba8(150, 150, 200, alpha);
      
      // 원의 테두리 그리기
      for (int angle = 0; angle < 360; angle += 2) {
        final rad = angle * math.pi / 180;
        final x = (centerX + r * math.cos(rad)).round();
        final y = (centerY + r * math.sin(rad)).round();
        if (x >= 0 && x < width && y >= 0 && y < height) {
          image.setPixel(x, y, color);
        }
      }
    }
  }
  
  // 격자 패턴 추가
  final gridColor = img.ColorRgba8(100, 100, 100, 50);
  for (int x = 0; x < width; x += width ~/ 3) {
    for (int y = 0; y < height; y++) {
      image.setPixel(x, y, gridColor);
    }
  }
  for (int y = 0; y < height; y += height ~/ 3) {
    for (int x = 0; x < width; x++) {
      image.setPixel(x, y, gridColor);
    }
  }
  
  // 파일로 저장
  final pngBytes = img.encodePng(image);
  final file = File('assets/Images/mockup.png');
  await file.writeAsBytes(pngBytes);
  
  print('✅ Created mockup.png: ${width}x${height} (9:16 ratio)');
}
