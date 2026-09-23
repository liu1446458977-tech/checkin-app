import 'dart:async';

import 'package:flutter/material.dart';

import 'app.dart';
import 'bootstrap.dart';

/// 启动流程：同步阶段只做两件事 —— 绑定引擎、立即上屏。
/// 绝不 await 任何可能卡住或抛错的初始化（数据库 / 通知 / WorkManager），
/// 否则任何一个 await 卡住都会让 UI 永远不出现，停在系统黑背景上。
void main() {
  // 兜底：任何界面异常都必须"看得见"。
  // 之前出现过启动即黑屏、屏幕上没有任何线索的情况，排查成本极高；
  // 这里把异常直接画成醒目文字，而不是留给用户一片黑。
  ErrorWidget.builder = (FlutterErrorDetails details) =>
      StartupErrorView(message: details.exceptionAsString());

  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    debugPrint('[fatal] ${details.exceptionAsString()}\n${details.stack}');
  };

  runZonedGuarded(
    () {
      WidgetsFlutterBinding.ensureInitialized();
      runApp(const CheckinApp());

      // 初始化全部丢到后台；失败只记日志，绝不影响界面渲染。
      unawaited(appBootstrap);
    },
    (Object error, StackTrace stack) {
      // 落在 zone 外的异常（含未捕获的异步错误）也只记日志，不阻断已上屏的界面。
      debugPrint('[fatal-zone] $error\n$stack');
    },
  );
}

/// 极简错误视图：只依赖 Container / Text / Directionality，
/// 避免在错误处理路径上再次抛异常（那样才是真正的黑屏）。
class StartupErrorView extends StatelessWidget {
  final String message;
  const StartupErrorView({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Container(
        color: const Color(0xFFC62828),
        alignment: Alignment.center,
        padding: const EdgeInsets.all(24),
        child: SingleChildScrollView(
          child: Text(
            '界面出错了，请把这段文字发给开发者：\n\n$message',
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              height: 1.6,
            ),
          ),
        ),
      ),
    );
  }
}
