import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_datetime_picker_plus/flutter_datetime_picker_plus.dart'
    as dtp;

import '../models/constants.dart';
import '../models/pet_info.dart';
import '../models/petgram_nav_tab.dart';
import '../widgets/petgram_bottom_nav_bar.dart';
import 'diary_page.dart';

class FrameSettingsPage extends StatefulWidget {
  final List<PetInfo> petList;
  final Function(List<PetInfo>, String?) onPetListChanged;
  final bool frameEnabled;
  final Function(bool) onFrameEnabledChanged;
  final String? selectedPetId;
  final Function(String?) onSelectedPetChanged;

  const FrameSettingsPage({
    super.key,
    required this.petList,
    required this.onPetListChanged,
    required this.frameEnabled,
    required this.onFrameEnabledChanged,
    required this.selectedPetId,
    required this.onSelectedPetChanged,
  });

  @override
  State<FrameSettingsPage> createState() => _FrameSettingsPageState();
}

class _FrameSettingsPageState extends State<FrameSettingsPage> {
  late List<PetInfo> _petList;
  late bool _frameEnabled;
  String? _selectedPetId;

  @override
  void initState() {
    super.initState();
    _petList = List.from(widget.petList);
    _frameEnabled = widget.frameEnabled;
    _selectedPetId = widget.selectedPetId;
  }

  Future<void> _savePetList() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonList = _petList.map((pet) => jsonEncode(pet.toJson())).toList();
    await prefs.setStringList(kPetListKey, jsonList);
    // 선택된 반려동물 ID 저장
    if (_selectedPetId != null) {
      await prefs.setString(kSelectedPetIdKey, _selectedPetId!);
    }
    widget.onPetListChanged(_petList, _selectedPetId);
  }

  Future<void> _saveSelectedPetId() async {
    final prefs = await SharedPreferences.getInstance();
    if (_selectedPetId != null) {
      await prefs.setString(kSelectedPetIdKey, _selectedPetId!);
    }
    widget.onSelectedPetChanged(_selectedPetId);
  }

  void _addPet() {
    _showPetEditDialog(null);
  }

  void _editPet(PetInfo pet) {
    _showPetEditDialog(pet);
  }

  void _deletePet(PetInfo pet) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text(
          '정말 삭제하시겠습니까?',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
        content: const Text(
          '삭제 시, 복구할 수 없습니다.',
          style: TextStyle(fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('취소', style: TextStyle(color: Colors.grey)),
          ),
          TextButton(
            onPressed: () {
              final index = _petList.indexWhere((p) => p.id == pet.id);
              if (index != -1) {
                setState(() {
                  _petList.removeAt(index);
                  if (_selectedPetId == pet.id) {
                    _selectedPetId = _petList.isNotEmpty
                        ? _petList.first.id
                        : null;
                  }
                });
                _savePetList();
                Navigator.of(context).pop();
              }
            },
            child: const Text(
              '삭제',
              style: TextStyle(color: Colors.red, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  void _showPetEditDialog(PetInfo? pet) {
    final nameController = TextEditingController(text: pet?.name ?? '');
    final breedController = TextEditingController(text: pet?.breed ?? '');
    String selectedType = pet?.type ?? 'dog';
    String? selectedGender =
        pet?.gender ?? 'male'; // 'male' or 'female' (기본값: male)
    DateTime? selectedDate = pet?.birthDate;
    int framePattern = pet?.framePattern ?? 1;
    bool locationEnabled = pet?.locationEnabled ?? false;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          return Dialog(
            backgroundColor: Colors.transparent,
            insetPadding: const EdgeInsets.symmetric(horizontal: 20),
            child: Container(
              constraints: const BoxConstraints(maxHeight: 600),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(24),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 헤더
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: kMainPink.withValues(alpha: 0.1),
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(24),
                        topRight: Radius.circular(24),
                      ),
                    ),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: kMainPink.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(
                            pet == null
                                ? Icons.add_circle_outline
                                : Icons.edit_outlined,
                            color: kMainPink,
                            size: 24,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            pet == null ? '반려동물 추가' : '반려동물 수정',
                            style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w700,
                              color: Colors.black87,
                            ),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, size: 20),
                          color: Colors.grey[600],
                          onPressed: () => Navigator.of(context).pop(),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                        ),
                      ],
                    ),
                  ),
                  // 내용
                  Flexible(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // 반려동물 종류
                          const Text(
                            '반려동물 종류',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: Colors.black87,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            children: [
                              ChoiceChip(
                                label: const Text('강아지'),
                                selected: selectedType == 'dog',
                                onSelected: (selected) {
                                  setDialogState(() {
                                    selectedType = 'dog';
                                  });
                                },
                                selectedColor: kMainPink,
                                labelStyle: TextStyle(
                                  color: selectedType == 'dog'
                                      ? Colors.white
                                      : Colors.black87,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              ChoiceChip(
                                label: const Text('고양이'),
                                selected: selectedType == 'cat',
                                onSelected: (selected) {
                                  setDialogState(() {
                                    selectedType = 'cat';
                                  });
                                },
                                selectedColor: kMainPink,
                                labelStyle: TextStyle(
                                  color: selectedType == 'cat'
                                      ? Colors.white
                                      : Colors.black87,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 20),
                          // 이름 입력
                          const Text(
                            '이름',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: Colors.black87,
                            ),
                          ),
                          const SizedBox(height: 8),
                          TextField(
                            controller: nameController,
                            decoration: InputDecoration(
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: BorderSide(
                                  color: kMainPink,
                                  width: 2,
                                ),
                              ),
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 14,
                              ),
                            ),
                            maxLength: 9,
                            textCapitalization: TextCapitalization.words,
                          ),
                          const SizedBox(height: 20),
                          // 생년월일 선택
                          const Text(
                            '생년월일',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: Colors.black87,
                            ),
                          ),
                          const SizedBox(height: 8),
                          InkWell(
                            onTap: () {
                              dtp.DatePicker.showDatePicker(
                                context,
                                showTitleActions: true,
                                minTime: DateTime(2000, 1, 1),
                                maxTime: DateTime.now(),
                                onChanged: (date) {},
                                onConfirm: (date) {
                                  setDialogState(() {
                                    selectedDate = date;
                                  });
                                },
                                currentTime: selectedDate ?? DateTime.now(),
                                locale: dtp.LocaleType.ko,
                                theme: dtp.DatePickerTheme(
                                  itemStyle: const TextStyle(
                                    color: Colors.black,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 18,
                                  ),
                                  doneStyle: TextStyle(
                                    color: kMainPink,
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                  ),
                                  cancelStyle: TextStyle(
                                    color: Colors.grey[600],
                                    fontSize: 16,
                                  ),
                                ),
                              );
                            },
                            child: Container(
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                border: Border.all(color: Colors.grey[300]!),
                                borderRadius: BorderRadius.circular(12),
                                color: Colors.white,
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.calendar_today,
                                    color: kMainPink,
                                    size: 20,
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text(
                                      selectedDate != null
                                          ? '${selectedDate!.year}.${selectedDate!.month.toString().padLeft(2, '0')}.${selectedDate!.day.toString().padLeft(2, '0')}'
                                          : '생년월일을 선택해주세요',
                                      style: TextStyle(
                                        fontSize: 15,
                                        color: selectedDate != null
                                            ? Colors.black87
                                            : Colors.grey[400],
                                        fontWeight: selectedDate != null
                                            ? FontWeight.w500
                                            : FontWeight.normal,
                                      ),
                                    ),
                                  ),
                                  Icon(
                                    Icons.arrow_forward_ios,
                                    size: 16,
                                    color: Colors.grey[400],
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 20),
                          // 성별 선택
                          const Text(
                            '성별',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: Colors.black87,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            children: [
                              ChoiceChip(
                                label: const Text('Male'),
                                selected: selectedGender == 'male',
                                onSelected: (selected) {
                                  if (selected) {
                                    setDialogState(() {
                                      selectedGender = 'male';
                                    });
                                  }
                                },
                                selectedColor: kMainPink,
                                labelStyle: TextStyle(
                                  color: selectedGender == 'male'
                                      ? Colors.white
                                      : Colors.black87,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              ChoiceChip(
                                label: const Text('Female'),
                                selected: selectedGender == 'female',
                                onSelected: (selected) {
                                  if (selected) {
                                    setDialogState(() {
                                      selectedGender = 'female';
                                    });
                                  }
                                },
                                selectedColor: kMainPink,
                                labelStyle: TextStyle(
                                  color: selectedGender == 'female'
                                      ? Colors.white
                                      : Colors.black87,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 20),
                          // 종 입력
                          const Text(
                            '품종',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: Colors.black87,
                            ),
                          ),
                          const SizedBox(height: 8),
                          TextField(
                            controller: breedController,
                            decoration: InputDecoration(
                              hintText: '예: 골든 리트리버, 페르시안 등',
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: BorderSide(
                                  color: kMainPink,
                                  width: 2,
                                ),
                              ),
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 14,
                              ),
                            ),
                            maxLength: 12,
                            textCapitalization: TextCapitalization.words,
                          ),
                          const SizedBox(height: 20),
                          // 위치 정보 활성화 옵션
                          const Text(
                            '촬영 위치 정보 표시',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: Colors.black87,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Expanded(
                                child: Text(
                                  '사진 촬영 위치를 추가하여 표기하기 위해 위치정보를 사용합니다.',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey[600],
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Switch(
                                value: locationEnabled,
                                onChanged: (value) {
                                  setDialogState(() {
                                    locationEnabled = value;
                                  });
                                },
                                activeThumbColor: kMainPink,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  // 하단 버튼
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      border: Border(top: BorderSide(color: Colors.grey[200]!)),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => Navigator.of(context).pop(),
                            style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              side: BorderSide(color: Colors.grey[300]!),
                            ),
                            child: const Text(
                              '취소',
                              style: TextStyle(
                                color: Colors.grey,
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          flex: 2,
                          child: ElevatedButton(
                            onPressed: () async {
                              final name = nameController.text.trim();
                              final breed = breedController.text.trim();
                              if (name.isEmpty ||
                                  selectedDate == null ||
                                  selectedGender == null ||
                                  breed.isEmpty) {
                                showDialog(
                                  context: context,
                                  builder: (context) => AlertDialog(
                                    backgroundColor: Colors.white,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(20),
                                    ),
                                    title: const Text(
                                      '입력 오류',
                                      style: TextStyle(
                                        fontSize: 18,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    content: const Text(
                                      '모든 정보를 입력해주세요',
                                      style: TextStyle(fontSize: 14),
                                    ),
                                    actions: [
                                      TextButton(
                                        onPressed: () =>
                                            Navigator.of(context).pop(),
                                        child: const Text(
                                          '확인',
                                          style: TextStyle(color: kMainPink),
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                                return;
                              }
                              if (pet == null) {
                                // 추가
                                final newPet = PetInfo(
                                  id: DateTime.now().millisecondsSinceEpoch
                                      .toString(),
                                  name: name,
                                  type: selectedType,
                                  birthDate: selectedDate!,
                                  framePattern: framePattern,
                                  gender: selectedGender!,
                                  breed: breed,
                                  locationEnabled: locationEnabled,
                                );
                                setState(() {
                                  _petList.add(newPet);
                                  if (_selectedPetId == null) {
                                    _selectedPetId = newPet.id;
                                  }
                                });
                              } else {
                                // 수정
                                final index = _petList.indexWhere(
                                  (p) => p.id == pet.id,
                                );
                                if (index != -1) {
                                  setState(() {
                                    _petList[index] = PetInfo(
                                      id: pet.id,
                                      name: name,
                                      type: selectedType,
                                      birthDate: selectedDate!,
                                      framePattern: framePattern,
                                      gender: selectedGender!,
                                      breed: breed,
                                      locationEnabled: locationEnabled,
                                    );
                                  });
                                }
                              }
                              await _savePetList();
                              if (mounted) {
                                Navigator.of(context).pop();
                                setState(() {});
                              }
                            },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: kMainPink,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              elevation: 0,
                            ),
                            child: Text(
                              pet == null ? '추가하기' : '저장하기',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFFF5F8),
      appBar: AppBar(
        title: const Text('프레임 설정'),
        backgroundColor: const Color(0xFFFFF5F8),
        elevation: 0,
      ),
      body: SafeArea(
        top: true,
        bottom: false,
        child: _petList.isEmpty
            ? Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.photo_filter_outlined,
                      size: 64,
                      color: Colors.grey[400],
                    ),
                    const SizedBox(height: 16),
                    Text(
                      '등록된 반려동물이 없습니다',
                      style: TextStyle(color: Colors.grey[600], fontSize: 16),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '반려동물을 먼저 등록해주세요',
                      style: TextStyle(color: Colors.grey[500], fontSize: 14),
                    ),
                    const SizedBox(height: 24),
                    ElevatedButton.icon(
                      onPressed: () => _addPet(),
                      icon: const Icon(Icons.add_circle_outline),
                      label: const Text('반려동물 추가'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: kMainPink,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 12,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ],
                ),
              )
            : ListView(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 16,
                ),
                children: [
                  // 프레임 활성화 (간소화)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Icon(
                            _frameEnabled
                                ? Icons.photo_filter
                                : Icons.photo_filter_outlined,
                            color: _frameEnabled ? kMainPink : Colors.grey[400],
                            size: 22,
                          ),
                          const SizedBox(width: 12),
                          Text(
                            '프레임 활성화',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: _frameEnabled
                                  ? Colors.black87
                                  : Colors.grey[600],
                            ),
                          ),
                        ],
                      ),
                      Switch(
                        value: _frameEnabled,
                        onChanged: _petList.isEmpty
                            ? null
                            : (value) {
                                setState(() {
                                  _frameEnabled = value;
                                });
                                widget.onFrameEnabledChanged(value);
                              },
                        activeThumbColor: kMainPink,
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  // 안내 문구 (간소화)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      '반려동물을 탭하여 프레임을 적용할 반려동물을 선택하세요',
                      style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  // 반려동물별 프레임 설정
                  ..._petList.map((pet) {
                    final isSelected = _selectedPetId == pet.id;
                    return Container(
                      margin: const EdgeInsets.only(bottom: 10),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: isSelected ? kMainPink : Colors.grey[200]!,
                          width: isSelected ? 2 : 1,
                        ),
                      ),
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: () {
                            setState(() {
                              _selectedPetId = pet.id;
                            });
                            _saveSelectedPetId();
                            // 프레임 선택이 바뀌면 위치정보를 다시 불러오기
                            widget.onSelectedPetChanged(pet.id);
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 14,
                            ),
                            child: Row(
                              children: [
                                // 아이콘
                                Container(
                                  width: 40,
                                  height: 40,
                                  decoration: BoxDecoration(
                                    color: isSelected
                                        ? kMainPink.withValues(alpha: 0.15)
                                        : Colors.grey[100],
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Icon(
                                    pet.type == 'dog'
                                        ? Icons.pets
                                        : Icons.favorite_rounded,
                                    color: isSelected
                                        ? kMainPink
                                        : Colors.grey[600],
                                    size: 22,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                // 이름과 정보
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Text(
                                            pet.name,
                                            style: TextStyle(
                                              fontSize: 16,
                                              fontWeight: FontWeight.w600,
                                              color: isSelected
                                                  ? Colors.black87
                                                  : Colors.black,
                                            ),
                                          ),
                                          if (isSelected) ...[
                                            const SizedBox(width: 6),
                                            Icon(
                                              Icons.check_circle,
                                              color: kMainPink,
                                              size: 18,
                                            ),
                                          ],
                                        ],
                                      ),
                                      if (pet.locationEnabled) ...[
                                        const SizedBox(height: 4),
                                        Row(
                                          children: [
                                            const SizedBox(width: 8),
                                            Icon(
                                              Icons.location_on,
                                              size: 14,
                                              color: Colors.grey[600],
                                            ),
                                            const SizedBox(width: 2),
                                            Text(
                                              '위치정보',
                                              style: TextStyle(
                                                fontSize: 12,
                                                color: Colors.grey[600],
                                              ),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                                // 편집/삭제 버튼
                                IconButton(
                                  icon: const Icon(
                                    Icons.edit_outlined,
                                    size: 18,
                                  ),
                                  color: Colors.blue[400],
                                  onPressed: () => _editPet(pet),
                                  tooltip: '수정',
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(
                                    minWidth: 36,
                                    minHeight: 36,
                                  ),
                                ),
                                IconButton(
                                  icon: const Icon(
                                    Icons.delete_outline,
                                    size: 18,
                                  ),
                                  color: Colors.red[400],
                                  onPressed: () => _deletePet(pet),
                                  tooltip: '삭제',
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(
                                    minWidth: 36,
                                    minHeight: 36,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                  const SizedBox(height: 20),
                  // 반려동물 추가 버튼
                  OutlinedButton.icon(
                    onPressed: () => _addPet(),
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text(
                      '반려동물 추가',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: kMainPink,
                      side: BorderSide(color: kMainPink, width: 1.5),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                ],
              ),
      ),
      bottomNavigationBar: Container(
        color: const Color(0xFFFCE4EC), // SafeArea bottom 포함 전체 백그라운드
        child: SafeArea(
          top: false,
          bottom: true,
          child: PetgramBottomNavBar(
            currentTab: PetgramNavTab.shot,
            onShotTap: () {
              // FrameSettingsPage에서 Shot으로 돌아가기
              Navigator.of(context).popUntil((route) => route.isFirst);
            },
            onDiaryTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const DiaryPage()),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// ========================
///  필터 편집 / 저장 화면
/// ========================
