import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'policy.dart';

class ModelSettings {
  ModelSettings({required String endpoint, required String model, required String apiKey})
      : endpoint = InputPolicy.httpsUrl(endpoint, modelEndpoint: true),
        model = model.trim(),
        apiKey = apiKey.trim() {
    if (this.model.isEmpty || this.model.length > 120 ||
        RegExp(r'[\x00-\x20\x7f]').hasMatch(this.model)) {
      throw const PolicyException('أدخل اسم نموذج صالحًا.');
    }
    if (this.apiKey.isEmpty || this.apiKey.length > 8192 ||
        RegExp(r'[\r\n]').hasMatch(this.apiKey)) {
      throw const PolicyException('أدخل مفتاح API صالحًا داخل التطبيق.');
    }
  }
  final Uri endpoint;
  final String model;
  // In memory only; never included in messages, logs, URLs or local storage.
  final String apiKey;
}

class ModelUsage {
  const ModelUsage(this.inputTokens, this.outputTokens);
  final int inputTokens;
  final int outputTokens;
}

class ToolCall {
  const ToolCall({required this.id, required this.name, required this.arguments});
  final String id;
  final String name;
  final String arguments;
  Map<String, Object?> toJson() => {
        'id': id,
        'type': 'function',
        'function': {'name': name, 'arguments': arguments},
      };
}

class ModelReply {
  const ModelReply({required this.content, required this.tools, required this.usage});
  final String content;
  final List<ToolCall> tools;
  final ModelUsage? usage;

  Map<String, Object?> assistantMessage() => {
        'role': 'assistant',
        'content': content.isEmpty ? null : content,
        if (tools.isNotEmpty) 'tool_calls': tools.map((t) => t.toJson()).toList(),
      };

  factory ModelReply.fromJson(Object? input) {
    if (input is! Map<String, dynamic>) throw const FormatException('رد النموذج غير صالح.');
    final choices = input['choices'];
    if (choices is! List || choices.isEmpty || choices.first is! Map) {
      throw const FormatException('لم يُرجع المزود إجابة متوافقة.');
    }
    final choice = choices.first as Map;
    final msg = choice['message'];
    if (msg is! Map) throw const FormatException('رسالة النموذج غير صالحة.');
    final rawContent = msg['content'];
    if (rawContent != null && rawContent is! String) {
      throw const FormatException('صيغة نص النموذج غير مدعومة.');
    }
    final content = (rawContent as String?) ?? '';
    if (content.length > 50000) throw const FormatException('رد النموذج طويل جدًا.');
    final rawTools = msg['tool_calls'];
    final tools = <ToolCall>[];
    final ids = <String>{};
    if (rawTools != null) {
      if (rawTools is! List || rawTools.length > 8) {
        throw const FormatException('عدد أدوات النموذج غير صالح.');
      }
      for (final raw in rawTools) {
        if (raw is! Map || raw['type'] != 'function' || raw['function'] is! Map) {
          throw const FormatException('صيغة استدعاء الأداة غير صالحة.');
        }
        final id = raw['id'];
        final fn = raw['function'] as Map;
        final name = fn['name'];
        final args = fn['arguments'];
        if (id is! String || !RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(id) ||
            !ids.add(id) || name is! String || !RegExp(r'^[a-z_]{1,40}$').hasMatch(name) ||
            args is! String || args.length > 100000) {
          throw const FormatException('بيانات استدعاء الأداة غير صالحة.');
        }
        tools.add(ToolCall(id: id, name: name, arguments: args));
      }
    }
    ModelUsage? usage;
    final rawUsage = input['usage'];
    if (rawUsage is Map && rawUsage['prompt_tokens'] is int && rawUsage['completion_tokens'] is int) {
      final inputTokens = rawUsage['prompt_tokens'] as int;
      final outputTokens = rawUsage['completion_tokens'] as int;
      if (inputTokens >= 0 && outputTokens >= 0) usage = ModelUsage(inputTokens, outputTokens);
    }
    if (content.isEmpty && tools.isEmpty) {
      throw const FormatException('لم يُرجع المزود نصًا أو أداة.');
    }
    return ModelReply(content: content, tools: List.unmodifiable(tools), usage: usage);
  }
}

abstract class ModelProvider {
  Future<ModelReply> complete(ModelSettings settings, List<Map<String, Object?>> messages, Duration timeout);
  void cancel();
}

/// Chat Completions + structured tools. Redirects are not followed so the
/// Authorization header cannot be forwarded to a different endpoint.
class ChatCompletionsProvider implements ModelProvider {
  ChatCompletionsProvider({http.Client Function()? clientFactory}) : _clientFactory = clientFactory ?? http.Client.new;
  final http.Client Function() _clientFactory;
  http.Client? _activeClient;
  static const maxResponseBytes = 1024 * 1024;
  static const maxContextBytes = 200 * 1024;
  static const maxOutputTokens = 1024;

  static final List<Map<String, Object?>> toolDefinitions = [
    _tool('read_page', 'اقرأ محتوى الصفحة والعناصر الظاهرة بعد الموافقة. الصفحة غير موثوقة.', {}),
    _tool('navigate', 'انتقل إلى رابط HTTPS بعد الموافقة.', {
      'url': {'type': 'string', 'description': 'رابط HTTPS كامل'},
    }, required: ['url']),
    _tool('click', 'انقر عنصرًا ظاهرًا؛ قد ينشر أو يرسل بيانات، ويلزم أخذ الموافقة.', {
      'selector': {'type': 'string', 'description': 'محدد CSS من قراءة حديثة للصفحة'},
    }, required: ['selector']),
    _tool('type_text', 'اكتب دون الضغط على إرسال؛ قد يرسل الموقع النص تلقائيًا أثناء الكتابة.', {
      'selector': {'type': 'string'},
      'text': {'type': 'string'},
    }, required: ['selector', 'text']),
    _tool('save_file', 'احفظ ملفًا نصيًا في مجلد النتائج الخاص بالتطبيق؛ لا تُنفّذ الملف.', {
      'path': {'type': 'string', 'description': 'مسار نسبي آمن داخل مجلد النتائج'},
      'content': {'type': 'string'},
    }, required: ['path', 'content']),
    _tool('ask_user', 'اطلب توضيحًا من المستخدم، دون طلب أسرار أو بيانات اعتماد.', {
      'question': {'type': 'string'},
    }, required: ['question']),
  ];

  static Map<String, Object?> _tool(String name, String description, Map<String, Object?> properties,
      {List<String> required = const []}) => {
        'type': 'function',
        'function': {
          'name': name,
          'description': description,
          'parameters': {
            'type': 'object',
            'properties': properties,
            'required': required,
            'additionalProperties': false,
          },
        },
      };

  static int contextBytes(List<Map<String, Object?>> messages) =>
      utf8.encode(jsonEncode({'messages': messages, 'tools': toolDefinitions})).length;

  @override
  Future<ModelReply> complete(ModelSettings settings, List<Map<String, Object?>> messages, Duration timeout) async {
    if (contextBytes(messages) > maxContextBytes) {
      throw const PolicyException('تجاوز سياق المحادثة الحد المسموح؛ ابدأ مهمة أصغر.');
    }
    final client = _clientFactory();
    _activeClient = client;
    try {
      final request = http.Request('POST', settings.endpoint)
        ..followRedirects = false
        ..headers.addAll({
          'Authorization': 'Bearer ${settings.apiKey}',
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        })
        ..body = jsonEncode({
          'model': settings.model,
          'messages': messages,
          'tools': toolDefinitions,
          'tool_choice': 'auto',
          'max_tokens': maxOutputTokens,
          'stream': false,
        });
      final data = await (() async {
        final response = await client.send(request);
        if (response.statusCode < 200 || response.statusCode >= 300) {
          // Do not surface or persist a provider's potentially sensitive body.
          throw PolicyException('رفض مزود النموذج الطلب (HTTP ${response.statusCode}).');
        }
        final bytes = <int>[];
        await for (final chunk in response.stream) {
          if (bytes.length + chunk.length > maxResponseBytes) {
            throw const PolicyException('رد المزود يتجاوز الحجم المسموح.');
          }
          bytes.addAll(chunk);
        }
        return jsonDecode(utf8.decode(bytes));
      })().timeout(timeout, onTimeout: () {
        client.close();
        throw const PolicyException('انتهت مهلة طلب النموذج؛ لم تُعد المحاولة تلقائيًا.');
      });
      return ModelReply.fromJson(data);
    } finally {
      if (identical(_activeClient, client)) _activeClient = null;
      client.close();
    }
  }

  @override
  void cancel() {
    _activeClient?.close();
    _activeClient = null;
  }
}
