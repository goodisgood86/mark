import 'package:flutter/material.dart';

import '../models/petgram_nav_tab.dart';
import '../widgets/petgram_bottom_nav_bar.dart';

class DiaryPage extends StatelessWidget {
  const DiaryPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFFF0F5), // 연핑크로 통일
      appBar: AppBar(
        backgroundColor: const Color(0xFFFFF0F5), // 연핑크로 통일
        elevation: 0,
        leading: IconButton(
          icon: const Icon(
            Icons.arrow_back_ios,
            color: Colors.black87,
            size: 20,
          ),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: SafeArea(
        top: true,
        bottom: false,
        child: IgnorePointer(
          ignoring: false,
          child: GestureDetector(
            onLongPress: () {},
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const SizedBox(height: 60),
                    // 일러스트 아이콘
                    Container(
                      width: 120,
                      height: 120,
                      decoration: BoxDecoration(
                        color: Color(0xFFF8C7D8).withOpacity(0.15),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.menu_book_rounded,
                        size: 60,
                        color: Color(0xFFF8C7D8),
                      ),
                    ),
                    const SizedBox(height: 48),
                    // 메인 타이틀
                    IgnorePointer(
                      child: Text(
                        '곧 업데이트 예정입니다',
                        style: const TextStyle(
                          fontSize: 26,
                          color: Colors.black87,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.5,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    const SizedBox(height: 32),
                    // 안내 카드
                    Container(
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: Colors.grey.withOpacity(0.2),
                          width: 1,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.05),
                            blurRadius: 10,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Column(
                        children: [
                          _buildInfoItem(
                            icon: Icons.camera_alt_rounded,
                            text: 'Petgram에서 촬영한 사진은\n자동으로 다이어리에 업데이트 됩니다.',
                          ),
                          const SizedBox(height: 20),
                          Container(
                            height: 1,
                            color: Colors.grey.withOpacity(0.2),
                          ),
                          const SizedBox(height: 20),
                          _buildInfoItem(
                            icon: Icons.pets_rounded,
                            text: '프레임 설정 후 촬영 시,\n반려동물 정보도 함께 업데이트 됩니다.',
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 100),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
      bottomNavigationBar: Container(
        color: const Color(0xFFFCE4EC), // SafeArea bottom 포함 전체 백그라운드
        child: SafeArea(
          top: false,
          bottom: true,
          child: PetgramBottomNavBar(
            currentTab: PetgramNavTab.diary,
            onShotTap: () {
              Navigator.of(context).pop();
            },
            onDiaryTap: () {
              // 이미 Diary 페이지이므로 별도 동작 없음
            },
          ),
        ),
      ),
    );
  }

  Widget _buildInfoItem({required IconData icon, required String text}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: Color(0xFFF8C7D8).withOpacity(0.2),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, size: 20, color: const Color(0xFFF8C7D8)),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: IgnorePointer(
              child: Text(
                text,
                style: const TextStyle(
                  fontSize: 15,
                  color: Colors.black87,
                  height: 1.5,
                  letterSpacing: -0.2,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
