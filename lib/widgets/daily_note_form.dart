/// 睡前总结的四个输入栏（抽取共用，避免睡前总结页与日期详情页两处 UI 分叉）。
library;

import 'package:flutter/material.dart';

import '../app.dart';

/// 四个字段的定义：收获 / 卡点 / 明天 / 其他
const List<({IconData icon, String label, String hint, int maxLines})>
    kNoteFieldDefs = [
  (
    icon: Icons.emoji_objects_outlined,
    label: '今天最有收获的一件事？',
    hint: '哪怕很小，写下来就是积累',
    maxLines: 3
  ),
  (
    icon: Icons.report_problem_outlined,
    label: '今天遇到的卡点或困难？',
    hint: '卡在哪里了？下次可以怎么绕开',
    maxLines: 3
  ),
  (
    icon: Icons.flag_outlined,
    label: '明天最重要的一件事？',
    hint: '只写一件，明早直接开干',
    maxLines: 2
  ),
  (
    icon: Icons.edit_note_outlined,
    label: '其他想记的',
    hint: '随手记，不设限',
    maxLines: 4
  ),
];

/// 四个字段的输入区。调用方持有 controller 并负责保存。
class DailyNoteForm extends StatelessWidget {
  final List<TextEditingController> controllers;
  final VoidCallback onChanged;

  const DailyNoteForm({
    super.key,
    required this.controllers,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (var i = 0;
            i < kNoteFieldDefs.length && i < controllers.length;
            i++)
          _field(def: kNoteFieldDefs[i], controller: controllers[i]),
      ],
    );
  }

  Widget _field({
    required ({IconData icon, String label, String hint, int maxLines}) def,
    required TextEditingController controller,
  }) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(def.icon, size: 17, color: kRed),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(def.label,
                      style: const TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          color: kInk)),
                ),
              ],
            ),
            TextField(
              controller: controller,
              onChanged: (_) => onChanged(),
              maxLines: def.maxLines,
              minLines: 1,
              textInputAction: TextInputAction.newline,
              decoration: InputDecoration(
                hintText: def.hint,
                hintStyle:
                    const TextStyle(fontSize: 13, color: Color(0xFFB3A99C)),
                border: InputBorder.none,
                isDense: true,
                contentPadding: const EdgeInsets.only(top: 8),
              ),
              style: const TextStyle(fontSize: 14.5, height: 1.5, color: kInk),
            ),
          ],
        ),
      ),
    );
  }
}
