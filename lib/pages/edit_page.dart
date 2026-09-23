/// 新建 / 编辑任务页。
///
/// 新模型下这里只有三个属性：**归属日期 + 是否每天重复 + 截止日期**，
/// 三种形态由字段派生（见 models.dart 的 TaskKind），不再有类型选择器：
///   不重复、无截止 → 一天的任务（只在归属日出现）
///   打开重复       → 每天出现，可随时关掉
///   填了截止日期   → 周期任务（跨天大事），区间内每天出现，完成一次即达成
library;

import 'package:flutter/material.dart';

import '../app.dart';
import '../core_logic.dart';
import '../db.dart';
import '../models.dart';

class EditPage extends StatefulWidget {
  final Task? task;
  const EditPage({super.key, this.task});

  @override
  State<EditPage> createState() => _EditPageState();
}

class _EditPageState extends State<EditPage> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameCtrl;
  late final TextEditingController _noteCtrl;

  late DateTime _ownerDate;
  bool _repeatDaily = false;
  DateTime? _endDate;

  bool get _isNew => widget.task == null;

  @override
  void initState() {
    super.initState();
    final t = widget.task;
    _nameCtrl = TextEditingController(text: t?.name ?? '');
    _noteCtrl = TextEditingController(text: t?.note ?? '');
    _ownerDate = t?.ownerDate ?? todayOnly(DateTime.now());
    _repeatDaily = t?.repeatDaily ?? false;
    _endDate = t?.endDate;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  /// kind: 'owner' 归属日 / 'end' 截止日
  Future<void> _pickDate(String kind) async {
    final now = DateTime.now();
    final initial = kind == 'owner' ? _ownerDate : (_endDate ?? _ownerDate);
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(now.year - 5),
      lastDate: DateTime(now.year + 10),
    );
    if (picked == null) return;
    setState(() {
      if (kind == 'owner') {
        _ownerDate = picked;
        // 归属日往后挪时，截止日跟着走，避免出现"截止早于开始"的无效组合
        if (_endDate != null && _endDate!.isBefore(_ownerDate)) {
          _endDate = _ownerDate;
        }
      } else {
        _endDate = picked;
      }
    });
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    if (_endDate != null && _endDate!.isBefore(_ownerDate)) {
      _showHint('截止日期不能早于归属日期。');
      return;
    }

    final old = widget.task;
    // 这里刻意不用 copyWith：copyWith 的 `?? this.x` 语义无法表达「把字段清空」，
    // 会导致编辑时清掉截止日期却存不进去。改为完整构造。
    final task = Task(
      id: old?.id,
      uuid: old?.uuid ?? newTaskUuid(),
      name: _nameCtrl.text.trim(),
      note: _noteCtrl.text.trim(),
      colorIndex: old?.colorIndex ?? 0,
      ownerDate: _ownerDate,
      repeatDaily: _repeatDaily,
      endDate: _endDate,
      archived: old?.archived ?? false,
      createdAt: old?.createdAt ?? DateTime.now(),
    );

    final db = Db.instance;
    try {
      if (_isNew) {
        await db.addTask(task);
      } else {
        await db.updateTask(task);
      }

      if (mounted) Navigator.pop(context, true);
    } catch (e, s) {
      // 保存失败要明确告知用户，不能静默丢数据。
      debugPrint('[edit] 保存失败: $e\n$s');
      if (mounted) _showHint('保存失败，请重试');
    }
  }

  void _showHint(String msg) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  /// 实时告诉用户"这条任务以后会怎么出现"，省得自己猜
  String get _preview {
    final kind = _repeatDaily
        ? TaskKind.repeating
        : (_endDate != null ? TaskKind.periodic : TaskKind.single);
    final label = '${kind.label}任务';
    if (_endDate != null) {
      final days = _endDate!.difference(_ownerDate).inDays + 1;
      return '$label：$_ownerDateText ~ ${dateKey(_endDate!)}（共 $days 天）'
          '${_repeatDaily ? '，每天都要重新打卡' : '，完成一次即达成'}';
    }
    if (_repeatDaily) return '$label：从 $_ownerDateText 起每天都出现';
    return '$label：只在 $_ownerDateText 出现一次';
  }

  String get _ownerDateText => dateKey(_ownerDate);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? '新建任务' : '编辑任务'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.pop(context, false),
        ),
        actions: [
          TextButton(
            onPressed: _save,
            child: const Text('保存', style: TextStyle(color: kRed, fontSize: 16)),
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
          children: [
            TextFormField(
              controller: _nameCtrl,
              decoration: const InputDecoration(
                labelText: '任务名称',
                hintText: '例如：早起 / 背单词 / 跑步 3 公里',
              ),
              textInputAction: TextInputAction.next,
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? '请填写任务名称' : null,
            ),
            const SizedBox(height: 20),
            const _Label('归属日期'),
            const SizedBox(height: 8),
            _DateField(
              label: '这条任务属于哪一天',
              value: _ownerDate,
              onPick: () => _pickDate('owner'),
            ),
            const SizedBox(height: 8),
            const Text('任务只在归属日出现一次；要每天都出现，请打开下面的开关。',
                style: TextStyle(fontSize: 12, height: 1.5, color: kMuted)),
            const SizedBox(height: 16),
            Card(
              margin: EdgeInsets.zero,
              child: SwitchListTile(
                value: _repeatDaily,
                onChanged: (v) => setState(() => _repeatDaily = v),
                activeThumbColor: kRed,
                title: const Text('每天重复', style: TextStyle(fontSize: 15)),
                subtitle: const Text('从归属日起每天都出现，每天都要重新打卡；随时可以关掉。',
                    style: TextStyle(fontSize: 12, height: 1.5)),
              ),
            ),
            const SizedBox(height: 16),
            const _Label('截止日期（可留空）'),
            const SizedBox(height: 8),
            _DateField(
              label: '留空 = 一直有效',
              value: _endDate,
              onPick: () => _pickDate('end'),
              onClear: () => setState(() => _endDate = null),
            ),
            const SizedBox(height: 8),
            const Text('填了截止日期就是「周期任务」：归属日到截止日之间每天都出现，'
                '完成一次即达成，之后一直显示为已完成，到截止日结束。',
                style: TextStyle(fontSize: 12, height: 1.5, color: kMuted)),
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: kRed.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: kRed.withValues(alpha: 0.18)),
              ),
              child: Text(_preview,
                  style: const TextStyle(fontSize: 12.5, height: 1.6, color: kRed)),
            ),
            const SizedBox(height: 20),
            TextFormField(
              controller: _noteCtrl,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: '备注（可留空）',
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 32),
            SizedBox(
              height: 50,
              child: FilledButton(
                style: FilledButton.styleFrom(backgroundColor: kRed),
                onPressed: _save,
                child: Text(_isNew ? '创建任务' : '保存修改'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Label extends StatelessWidget {
  final String text;
  const _Label(this.text);
  @override
  Widget build(BuildContext context) => Text(
        text,
        style: const TextStyle(
            fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF8A837A), letterSpacing: 1),
      );
}

class _DateField extends StatelessWidget {
  final String label;
  final DateTime? value;
  final VoidCallback onPick;
  final VoidCallback? onClear;
  const _DateField({
    required this.label,
    required this.value,
    required this.onPick,
    this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onPick,
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          suffixIcon: onClear != null && value != null
              ? IconButton(icon: const Icon(Icons.close, size: 18), onPressed: onClear)
              : const Icon(Icons.event),
        ),
        child: Text(value == null ? '未设置' : dateKey(value!),
            style: TextStyle(color: value == null ? const Color(0xFFB3A99C) : kInk)),
      ),
    );
  }
}
