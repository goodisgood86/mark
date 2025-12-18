/// 반려동물 정보 클래스
class PetInfo {
  final String id;
  final String name;
  final String type; // 'dog' or 'cat'
  final DateTime birthDate;
  final int framePattern; // 1 or 2
  final String? gender; // 'male' or 'female' or null
  final String? breed; // 종 (텍스트 입력)
  final bool locationEnabled; // GPS 위치 정보 활성화 여부

  PetInfo({
    required this.id,
    required this.name,
    required this.type,
    required this.birthDate,
    this.framePattern = 1,
    this.gender,
    this.breed,
    this.locationEnabled = false,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'type': type,
        'birthDate': birthDate.toIso8601String(),
        'framePattern': framePattern,
        'gender': gender,
        'breed': breed,
        'locationEnabled': locationEnabled,
      };

  factory PetInfo.fromJson(Map<String, dynamic> json) => PetInfo(
        id: json['id'] as String,
        name: json['name'] as String,
        type: json['type'] as String,
        birthDate: DateTime.parse(json['birthDate'] as String),
        framePattern: json['framePattern'] as int? ?? 1,
        gender: json['gender'] as String?,
        breed: json['breed'] as String?,
        locationEnabled: json['locationEnabled'] as bool? ?? false,
      );

  int getAge() {
    final now = DateTime.now();
    int age = now.year - birthDate.year;
    if (now.month < birthDate.month ||
        (now.month == birthDate.month && now.day < birthDate.day)) {
      age--;
    }
    return age;
  }
}

