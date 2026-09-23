/// DeepSeek 客户端。
///
/// 刻意使用 dart:io 的 HttpClient 而不是 http/dio 包：
/// 本项目的构建环境（AGP9 + 自建工具链）很脆弱，能不加依赖就不加。
/// 一个 POST + JSON 解析，HttpClient 完全够用。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 错误分类：UI 据此给出可操作的提示，而不是一句「生成失败」
enum AiErrorKind {
  noKey, // 没配 Key
  network, // 无网络 / DNS / 连接失败
  timeout, // 超时
  auth, // 401 Key 无效
  noBalance, // 402 余额不足
  rateLimit, // 429 限流
  server, // 5xx
  badResponse, // 返回体不符合预期
}

class AiException implements Exception {
  final AiErrorKind kind;
  final String message; // 面向用户的中文提示
  final String? detail; // 原始错误，便于排查
  final int? statusCode;

  const AiException(this.kind, this.message, {this.detail, this.statusCode});

  @override
  String toString() => detail == null ? message : '$message（$detail）';

  /// 是否值得用户重试
  bool get retryable =>
      kind == AiErrorKind.network ||
      kind == AiErrorKind.timeout ||
      kind == AiErrorKind.rateLimit ||
      kind == AiErrorKind.server;
}

class DeepSeekResult {
  final String content;
  final int promptTokens;
  final int completionTokens;
  /// reasoning_content：模型的思考过程（V4 系列默认开思考模式）。
  /// 它也是正式输出的一部分——max_tokens 不够时，思考会把它吃光、正文为空。
  final String reasoning;
  /// finish_reason：'stop' 正常收尾；'length' 表示撞上了 max_tokens
  final String finishReason;

  const DeepSeekResult({
    required this.content,
    this.promptTokens = 0,
    this.completionTokens = 0,
    this.reasoning = '',
    this.finishReason = '',
  });
}

class DeepSeekClient {
  final String apiKey;
  final String baseUrl;
  final String model;
  final Duration timeout;

  const DeepSeekClient({
    required this.apiKey,
    this.baseUrl = kDefaultBaseUrl,
    this.model = kDefaultModel,
    // 生成大段中文（尤其推理模型带思维链）可能要一两分钟，超时给宽一点
    this.timeout = const Duration(seconds: 180),
  });

  static const String kDefaultBaseUrl = 'https://api.deepseek.com';
  static const String kDefaultModel = 'deepseek-v4-flash';
  /// 旧名字（deepseek-chat / deepseek-reasoner）已被官方并入 flash 档，
  /// 不再提供选择——留着只会造成"换过模型了"的错觉（实测两者回显同一个模型）。
  static const List<String> kModels = ['deepseek-v4-flash', 'deepseek-v4-pro'];

  Future<DeepSeekResult> chat({
    required String systemPrompt,
    required String userPrompt,
    int maxTokens = 1600,
    double temperature = 0.7,
  }) async {
    if (apiKey.trim().isEmpty) {
      throw const AiException(AiErrorKind.noKey, '还没有配置 API Key');
    }
    final body = jsonEncode({
      'model': model,
      'messages': [
        {'role': 'system', 'content': systemPrompt},
        {'role': 'user', 'content': userPrompt},
      ],
      'max_tokens': maxTokens,
      'temperature': temperature,
      'stream': false,
    });

    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    try {
      final uri = Uri.parse('${_normalizedBase()}/chat/completions');
      final req = await client.postUrl(uri).timeout(const Duration(seconds: 30));
      req.headers.contentType = ContentType.json;
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${apiKey.trim()}');
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      req.write(body);

      final resp = await req.close().timeout(timeout);
      final raw = await resp
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 120));

      if (resp.statusCode == 200) {
        return _parseOk(raw);
      }
      throw _classifyError(resp.statusCode, raw);
    } on AiException {
      rethrow;
    } on TimeoutException catch (e) {
      throw AiException(AiErrorKind.timeout, '请求超时，请检查网络后重试',
          detail: e.toString());
    } on SocketException catch (e) {
      throw AiException(AiErrorKind.network, '网络不可用（无法连接 DeepSeek）',
          detail: e.message);
    } on HandshakeException catch (e) {
      throw AiException(AiErrorKind.network, 'HTTPS 握手失败，请检查网络或代理',
          detail: e.toString());
    } on FormatException catch (e) {
      throw AiException(AiErrorKind.badResponse, '返回内容无法解析',
          detail: e.toString());
    } finally {
      client.close(force: true);
    }
  }

  /// 设置页「测试连接」用：发一条极短的请求
  Future<String> testConnection() async {
    final r = await chat(
      systemPrompt: '你只回复「ok」。',
      userPrompt: 'ping',
      maxTokens: 8,
      temperature: 0,
    );
    final c = r.content.trim();
    // 推理模型可能把这 8 个 token 全花在思考上、正文为空；
    // 本方法只验证「通不通、Key 对不对」，HTTP 200 就算连上了
    return c.isEmpty ? 'ok' : c;
  }

  String _normalizedBase() {
    var b = baseUrl.trim();
    if (b.isEmpty) b = kDefaultBaseUrl;
    while (b.endsWith('/')) {
      b = b.substring(0, b.length - 1);
    }
    // 允许用户填到 /v1 或直接填域名
    return b;
  }

  DeepSeekResult _parseOk(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw const AiException(AiErrorKind.badResponse, '返回格式不是 JSON 对象');
    }
    final choices = decoded['choices'];
    if (choices is! List || choices.isEmpty) {
      throw const AiException(AiErrorKind.badResponse, '返回里没有 choices');
    }
    final first = choices.first;
    final msg = first is Map ? first['message'] : null;
    var content = msg is Map ? (msg['content'] as String?) : null;
    // V4 模型的正式回答在 content，思考过程在 reasoning_content（这里不用）
    content ??= (first is Map ? first['text'] as String? : null);
    final reasoning =
        msg is Map ? (msg['reasoning_content'] as String? ?? '') : '';
    final finish = first is Map ? (first['finish_reason'] as String? ?? '') : '';
    final usage = decoded['usage'];
    if (content == null || content.trim().isEmpty) {
      if (reasoning.trim().isEmpty) {
        throw const AiException(AiErrorKind.badResponse, '模型返回了空内容');
      }
      // 正文为空但思考有内容：说明服务端正常响应，只是输出额度被思考吃光了。
      // 这里不抛异常——连接测试按「通」处理，生成流程由调用方兜底报错。
      return DeepSeekResult(
        content: '',
        reasoning: reasoning,
        finishReason: finish,
        promptTokens: usage is Map ? (usage['prompt_tokens'] as int? ?? 0) : 0,
        completionTokens:
            usage is Map ? (usage['completion_tokens'] as int? ?? 0) : 0,
      );
    }
    return DeepSeekResult(
      content: content,
      reasoning: reasoning,
      finishReason: finish,
      promptTokens: usage is Map ? (usage['prompt_tokens'] as int? ?? 0) : 0,
      completionTokens:
          usage is Map ? (usage['completion_tokens'] as int? ?? 0) : 0,
    );
  }

  AiException _classifyError(int status, String raw) {
    String? apiMsg;
    try {
      final d = jsonDecode(raw);
      if (d is Map && d['error'] is Map) {
        apiMsg = (d['error'] as Map)['message']?.toString();
      }
    } catch (_) {
      // 忽略：错误体不一定是 JSON
    }
    final snippet = apiMsg ?? (raw.length > 200 ? '${raw.substring(0, 200)}…' : raw);
    switch (status) {
      case 401:
        return AiException(AiErrorKind.auth, 'API Key 无效或已失效，请到设置里重新填写',
            detail: snippet, statusCode: status);
      case 402:
        return AiException(AiErrorKind.noBalance, 'DeepSeek 账户余额不足，请先充值',
            detail: snippet, statusCode: status);
      case 429:
        return AiException(AiErrorKind.rateLimit, '请求太频繁或已达到限额，稍后再试',
            detail: snippet, statusCode: status);
      case 400:
        return AiException(AiErrorKind.badResponse, '请求被拒绝（可能是模型名不对）',
            detail: snippet, statusCode: status);
      default:
        if (status >= 500) {
          return AiException(AiErrorKind.server, 'DeepSeek 服务端错误（$status），稍后重试',
              detail: snippet, statusCode: status);
        }
        return AiException(AiErrorKind.badResponse, '请求失败（HTTP $status）',
            detail: snippet, statusCode: status);
    }
  }
}
