import 'package:flutter/material.dart';

import '../models/constants.dart';
import '../models/petgram_nav_tab.dart';

class PetgramBottomNavBar extends StatelessWidget {
  final PetgramNavTab currentTab;
  final VoidCallback onShotTap;
  final VoidCallback onDiaryTap;
  final VoidCallback onBackupTap;

  const PetgramBottomNavBar({
    super.key,
    required this.currentTab,
    required this.onShotTap,
    required this.onDiaryTap,
    required this.onBackupTap,
  });

  @override
  Widget build(BuildContext context) {
    // 순수 네비 위젯: 위치 책임 없음, 상위에서 배치
    // 슬림화: 패딩 최소화, 높이 최소화
    final media = MediaQuery.of(context);
    final double horizontalSafeInset =
        (media.padding.left > media.padding.right
            ? media.padding.left
            : media.padding.right) +
        (media.systemGestureInsets.left > media.systemGestureInsets.right
            ? media.systemGestureInsets.left
            : media.systemGestureInsets.right);
    const double sideSlotWidth = 48;
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: kPetgramNavColor,
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: SizedBox(
        width: double.infinity,
        height: 44,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 16 + horizontalSafeInset),
          child: Row(
            children: [
              const SizedBox(width: sideSlotWidth),
              Expanded(
                child: Center(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
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
                ),
              ),
              SizedBox(
                width: sideSlotWidth,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: _buildItem(
                    icon: Icons.cloud_sync_outlined,
                    isSelected: currentTab == PetgramNavTab.backup,
                    onTap: onBackupTap,
                  ),
                ),
              ),
            ],
          ),
        ),
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
