import 'dart:convert';

/// 프레임 오버레이 칩 모델
class FrameChip {
  final String label;
  final String value;
  final String? iconType; // 🔥 아이콘 타입: "dog" 또는 "cat" (프리뷰와 동일하게)
  final String? iconBase64; // 🔥 아이콘 이미지 Base64 (프리뷰와 동일하게)

  FrameChip({
    required this.label,
    required this.value,
    this.iconType, // 아이콘 타입 (dog/cat)
    this.iconBase64, // 아이콘 이미지 Base64 데이터
  });

  Map<String, dynamic> toJson() => {
    'label': label,
    'value': value,
    if (iconType != null) 'iconType': iconType,
    if (iconBase64 != null) 'iconBase64': iconBase64,
  };

  factory FrameChip.fromJson(Map<String, dynamic> json) => FrameChip(
    label: json['label'] as String,
    value: json['value'] as String,
    iconType: json['iconType'] as String?,
    iconBase64: json['iconBase64'] as String?,
  );
}

/// 프레임 오버레이 설정 모델
/// 프리뷰와 저장 모두 이 모델을 사용하여 일관성 유지
/// 🔥 프리뷰와 동일: 상단 칩 2개 + 하단 칩 (날짜, 위치)
class FrameOverlayConfig {
  final List<FrameChip> topChips; // 최대 2개까지만 (이름, 정보)
  final List<FrameChip> bottomChips; // 하단 칩 (날짜, 위치) - 프리뷰와 동일하게

  FrameOverlayConfig({required this.topChips, required this.bottomChips})
    : assert(topChips.length <= 2, 'topChips는 최대 2개까지만 허용됩니다');

  /// JSON으로 변환 (네이티브에 전달)
  Map<String, dynamic> toJson() => {
    'topChips': topChips.take(2).map((chip) => chip.toJson()).toList(),
    'bottomChips': bottomChips.map((chip) => chip.toJson()).toList(),
  };

  factory FrameOverlayConfig.fromJson(Map<String, dynamic> json) =>
      FrameOverlayConfig(
        topChips:
            (json['topChips'] as List<dynamic>?)
                ?.map((e) => FrameChip.fromJson(e as Map<String, dynamic>))
                .toList() ??
            [],
        bottomChips:
            (json['bottomChips'] as List<dynamic>?)
                ?.map((e) => FrameChip.fromJson(e as Map<String, dynamic>))
                .toList() ??
            [],
      );

  /// JSON 문자열로 변환
  String toJsonString() => jsonEncode(toJson());
}
