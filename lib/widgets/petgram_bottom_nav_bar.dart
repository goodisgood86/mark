import 'package:flutter/material.dart';

import '../models/constants.dart';
import '../models/petgram_nav_tab.dart';

class PetgramBottomNavBar extends StatelessWidget {
  final PetgramNavTab currentTab;
  final VoidCallback onShotTap;
  final VoidCallback onDiaryTap;

  const PetgramBottomNavBar({
    super.key,
    required this.currentTab,
    required this.onShotTap,
    required this.onDiaryTap,
  });

  @override
  Widget build(BuildContext context) {
    // 순수 네비 위젯: 위치 책임 없음, 상위에서 배치
    // 슬림화: 패딩 최소화, 높이 최소화
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        color: kPetgramNavColor, // 네비게이션 바 배경색 (공통 상수 사용)
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _buildItem(
            icon: Icons.camera_alt,
            isSelected: currentTab == PetgramNavTab.shot,
            onTap: onShotTap,
          ),
          const SizedBox(width: 24),
          _buildItem(
            icon: Icons.menu_book_outlined,
            isSelected: currentTab == PetgramNavTab.diary,
            onTap: onDiaryTap,
          ),
        ],
      ),
    );
  }

  Widget _buildItem({
    required IconData icon,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    // 텍스트 제거, 아이콘만 표시
    final color = isSelected ? const Color(0xFFF8C7D8) : Colors.black54;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(4),
        child: Icon(icon, size: 22, color: color),
      ),
    );
  }
}
