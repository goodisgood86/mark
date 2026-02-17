class OneLineDiaryEntry {
  final String id;
  final String filePath;
  final DateTime takenAt;
  final String fileName;
  final String? petName;
  final String? petType;
  final String comment;
  final List<String> userTags;
  final bool isHidden;

  const OneLineDiaryEntry({
    required this.id,
    required this.filePath,
    required this.takenAt,
    required this.fileName,
    this.petName,
    this.petType,
    required this.comment,
    required this.userTags,
    required this.isHidden,
  });

  List<String> get allTags {
    final merged = <String>{};
    merged.addAll(userTags.where((e) => e.trim().isNotEmpty));
    return merged.toList(growable: false);
  }

  OneLineDiaryEntry copyWith({
    String? comment,
    List<String>? userTags,
    bool? isHidden,
  }) {
    return OneLineDiaryEntry(
      id: id,
      filePath: filePath,
      takenAt: takenAt,
      fileName: fileName,
      petName: petName,
      petType: petType,
      comment: comment ?? this.comment,
      userTags: userTags ?? this.userTags,
      isHidden: isHidden ?? this.isHidden,
    );
  }
}
