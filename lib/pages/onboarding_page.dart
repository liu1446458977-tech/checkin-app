/// 首次启动引导页：
///   1) 昵称（**必填、之后不可修改**）——它是身份标识，以后联云做看板靠它硬性隔离；
///   2) DeepSeek API Key（选填）——不配也能用，只有 AI 总结用不上。
library;

import 'package:flutter/material.dart';

import '../app.dart';
import '../db.dart';
import '../services/board_client.dart';
import '../services/profile.dart';
import '../services/secret_store.dart';
import '../services/summary_service.dart';

class OnboardingPage extends StatefulWidget {
  /// 用户完成（保存或跳过）后的回调
  final VoidCallback onDone;

  const OnboardingPage({super.key, required this.onDone});

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage> {
  final _keyCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();
  bool _obscure = true;
  bool _saving = false;
  bool _showAdvanced = false;
  String _backend = '正在检测…';

  @override
  void initState() {
    super.initState();
    _detectBackend();
  }

  @override
  void dispose() {
    _keyCtrl.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _detectBackend() async {
    try {
      final label = await SecretStore.backendLabel();
      if (mounted) setState(() => _backend = label);
    } catch (_) {
      if (mounted) setState(() => _backend = '未知');
    }
  }

  Future<void> _finish({required bool skip}) async {
    // 昵称必填、且设了就改不了：先卡住这一关
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请先起一个昵称（设置后不能修改）')));
      return;
    }
    if (!skip) {
      final key = _keyCtrl.text.trim();
      if (key.isEmpty) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('请填入 API Key，或点「先跳过」')));
        return;
      }
      setState(() => _saving = true);
      try {
        await SecretStore.put(kSecretApiKey, key);
      } catch (e) {
        if (!mounted) return;
        setState(() => _saving = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('保存失败：$e')));
        return;
      }
    }
    try {
      await setUserName(name);
      await Db.instance.setSetting(kSettingAiOnboarded, '1');
    } catch (_) {
      // 记不住这个标记不影响使用，忽略
    }
    // 改过昵称的话，让服务器把老昵称的全部数据迁到新昵称名下
    // （失败静默、不阻塞引导；冷启动时会自动重试）
    flushPendingRename().ignore();
    if (!mounted) return;
    widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
          children: [
            const SizedBox(height: 8),
            const Icon(Icons.insights, size: 48, color: kRed),
            const SizedBox(height: 14),
            const Text('欢迎使用「每日打卡」',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 22, fontWeight: FontWeight.w700, color: kInk)),
            const SizedBox(height: 8),
            const Text('坚持一件小事，日拱一卒',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13.5, color: kMuted)),
            const SizedBox(height: 28),

            const Text('你的昵称',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: kMuted,
                    letterSpacing: 1)),
            const SizedBox(height: 8),
            TextField(
              controller: _nameCtrl,
              maxLength: 12,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                hintText: '例如：博文',
                border: OutlineInputBorder(),
                helperText: '必填，设置后不可修改',
                helperMaxLines: 2,
              ),
            ),
            const SizedBox(height: 14),

            Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: const [
                    Text('接下来你会得到什么',
                        style: TextStyle(
                            fontSize: 14.5,
                            fontWeight: FontWeight.w700,
                            color: kInk)),
                    SizedBox(height: 10),
                    _Bullet('按你的打卡记录和睡前总结，自动生成周总结'),
                    _Bullet('两周总结合成半月总结，两个半月合成整月总结'),
                    _Bullet('指出不足、给出下一步学什么、怎么调整'),
                    _Bullet('休息日不会算作不足，也不会被批评'),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 18),

            const Text('DeepSeek API Key',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: kMuted,
                    letterSpacing: 1)),
            const SizedBox(height: 8),
            TextField(
              controller: _keyCtrl,
              obscureText: _obscure,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                hintText: 'sk-...',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.lock_outline, size: 14, color: kMuted),
                const SizedBox(width: 6),
                Expanded(
                  child: Text('存储方式：$_backend',
                      style: const TextStyle(fontSize: 12, color: kMuted)),
                ),
              ],
            ),
            const SizedBox(height: 6),
            const Text(
              '申请地址：platform.deepseek.com → API keys。'
              '建议单独申请一个 Key，并在控制台设置消费上限。',
              style: TextStyle(fontSize: 12, height: 1.6, color: Color(0xFFB3A99C)),
            ),
            const SizedBox(height: 14),

            // 高级：自定义接口地址（默认官方）
            InkWell(
              onTap: () => setState(() => _showAdvanced = !_showAdvanced),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    Icon(_showAdvanced ? Icons.expand_less : Icons.expand_more,
                        size: 18, color: kMuted),
                    const SizedBox(width: 6),
                    const Text('高级设置（一般不用改）',
                        style: TextStyle(fontSize: 12.5, color: kMuted)),
                  ],
                ),
              ),
            ),
            if (_showAdvanced) ...[
              const SizedBox(height: 6),
              const Text(
                '接口地址默认 https://api.deepseek.com，'
                '使用官方服务时不需要修改。',
                style: TextStyle(fontSize: 12, height: 1.6, color: Color(0xFFB3A99C)),
              ),
            ],
            const SizedBox(height: 18),

            const Text(
              '隐私说明：生成总结时，你的打卡记录与睡前总结原文会发送给 DeepSeek。'
              '如果你不希望如此，可以点「先跳过」，其余功能不受影响。',
              style: TextStyle(fontSize: 12, height: 1.7, color: kMuted),
            ),
            const SizedBox(height: 22),

            SizedBox(
              height: 50,
              child: FilledButton(
                style: FilledButton.styleFrom(backgroundColor: kRed),
                onPressed: _saving ? null : () => _finish(skip: false),
                child: Text(_saving ? '保存中…' : '保存并开始'),
              ),
            ),
            const SizedBox(height: 10),
            TextButton(
              onPressed: _saving ? null : () => _finish(skip: true),
              child: const Text('暂不配 API Key，直接开始'),
            ),
          ],
        ),
      ),
    );
  }
}

class _Bullet extends StatelessWidget {
  final String text;
  const _Bullet(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 7),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Icon(Icons.circle, size: 6, color: kRed),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Text(text,
                  style: const TextStyle(
                      fontSize: 13.5, height: 1.5, color: kInk)),
            ),
          ],
        ),
      );
}
