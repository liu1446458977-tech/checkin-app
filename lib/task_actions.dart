/// 今日任务加载与打卡动作（首页与详情页共用）。
library;

import 'dart:math';

import 'package:flutter/material.dart';

import 'core_logic.dart';
import 'db.dart';
import 'models.dart';
import 'quote_lib.dart';

class TodayEntry {
  final Task task;
  final Set<String> doneDates; // 该任务历史完成日期

  const TodayEntry({
    required this.task,
    required this.doneDates,
  });
}

/// 加载某一天的任务（含状态）。
/// - 今日页：history = false → 只列「当天排期内 + 未归档」的任务
/// - 历史回看：history = true → 当天排期内（**含已归档**）或 当天确实打过卡的，
///   一条都不能少。归档只应该影响今日列表，不能让人看不到历史。
/// 传入过去日期即可用于历史回看；任务在创建之前不会出现。
Future<List<TodayEntry>> loadToday(
  Db db,
  DateTime now, {
  bool history = false,
}) async {
  final day = todayOnly(now);
  final tasks = await db.getTasks(includeArchived: history);
  final result = <TodayEntry>[];
  for (final t in tasks) {
    if (todayOnly(t.createdAt).isAfter(day)) continue;
    final done = await db.doneDates(t.id!);
    final keep = history
        ? appearedOnHistory(t, day, doneThatDay: done.contains(dateKey(day)))
        : appearsToday(t, day);
    if (!keep) continue;
    result.add(TodayEntry(task: t, doneDates: done));
  }
  // 排序：未完成在前，然后按形态（周期 → 重复 → 临时），同组按创建时间
  result.sort((a, b) {
    final ad = entryDone(a, day);
    final bd = entryDone(b, day);
    if (ad != bd) return ad ? 1 : -1;
    final ak = a.task.kind.sortOrder.compareTo(b.task.kind.sortOrder);
    if (ak != 0) return ak;
    return a.task.createdAt.compareTo(b.task.createdAt);
  });
  return result;
}

/// 该条目在某天是否显示为已完成。
/// 沿用 core_logic 的口径：周期任务完成一次即达成，重复任务只看当天。
bool entryDone(TodayEntry e, DateTime d) =>
    taskDoneForDisplay(e.task, d, doneDates: e.doneDates);

/// 完成主任务（记录打卡）。
/// 「今天还剩几项没完成」由今日页在每次重载时推给原生闹钟，这里不用管。
Future<void> completeTask(Db db, int taskId, DateTime now) async {
  await db.setTaskDone(taskId, dateKey(now), done: true);
}

/// 取消打卡。
Future<void> uncompleteTask(Db db, int taskId, DateTime now) async {
  await db.setTaskDone(taskId, dateKey(now), done: false);
}

/// 抽取一条语录并记录用量（不重复轮播）。
Future<Quote> giveQuote(Db db) async {
  final recent = await db.recentQuoteTexts(limit: 8);
  final q = pickQuote(kQuotes, recent.toSet());
  await db.addQuoteUsage(q.text);
  return q;
}

/// 展示语录弹窗（打卡成功后的勉励）。
Future<void> showQuoteSheet(BuildContext context, Quote q) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (context) => Container(
      margin: const EdgeInsets.all(20),
      padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
      decoration: BoxDecoration(
        color: const Color(0xFFB71C1C),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.emoji_events, color: Color(0xFFF7D774), size: 30),
          const SizedBox(height: 16),
          const Text('完成，好样的！',
              style: TextStyle(
                  color: Color(0xFFF7D774), fontSize: 14, letterSpacing: 2)),
          const SizedBox(height: 8),
          Text(
            '“${q.text}”',
            style: const TextStyle(
                color: Colors.white, fontSize: 20, height: 1.5, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: Text('—— ${q.source}',
                style: const TextStyle(color: Color(0xCCF5D0D0), fontSize: 13)),
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: const Color(0xFFB71C1C),
              ),
              onPressed: () => Navigator.pop(context),
              child: const Text('继续前进'),
            ),
          ),
        ],
      ),
    ),
  );
}

/// 每日一句（首页顶部）：每天固定一条诗词名句，用日期做种子。
Quote dailyQuote(DateTime now) {
  final r = Random(now.year * 10000 + now.month * 100 + now.day);
  return kQuotes[r.nextInt(kQuotes.length)];
}
