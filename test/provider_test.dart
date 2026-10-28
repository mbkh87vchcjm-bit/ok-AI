import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:personal_agent/src/policy.dart';
import 'package:personal_agent/src/provider.dart';

void main() {
  final settings = ModelSettings(endpoint: 'https://api.example.com/v1/chat/completions', model: 'model-1', apiKey: 'test-key');

  test('parses structured calls and usage', () {
    final reply = ModelReply.fromJson({
      'choices': [{'message': {'content': 'خطة', 'tool_calls': [
        {'id': 'call_1', 'type': 'function', 'function': {'name': 'navigate', 'arguments': '{"url":"https://example.com"}'}}
      ]}}],
      'usage': {'prompt_tokens': 20, 'completion_tokens': 5},
    });
    expect(reply.tools.single.name, 'navigate');
    expect(reply.usage!.inputTokens, 20);
    expect(reply.assistantMessage()['role'], 'assistant');
  });

  test('malformed or duplicate calls are rejected', () {
    expect(() => ModelReply.fromJson({'choices': []}), throwsFormatException);
    expect(() => ModelReply.fromJson({'choices': [{'message': {'content': null, 'tool_calls': [
      {'id': 'same', 'type': 'function', 'function': {'name': 'click', 'arguments': '{}'}},
      {'id': 'same', 'type': 'function', 'function': {'name': 'click', 'arguments': '{}'}},
    ]}}]}), throwsFormatException);
  });

  test('key is sent only in the header, not the conversation payload', () async {
    late http.Request request;
    final provider = ChatCompletionsProvider(clientFactory: () => MockClient((incoming) async {
      request = incoming;
      return http.Response(jsonEncode({'choices': [{'message': {'content': 'Done'}}]}), 200);
    }));
    final reply = await provider.complete(settings, [{'role': 'user', 'content': 'hello'}], const Duration(seconds: 2));
    expect(reply.content, 'Done');
    expect(request.headers['Authorization'], 'Bearer test-key');
    expect(request.body, isNot(contains('test-key')));
    expect(request.followRedirects, isFalse);
  });

  test('HTTP errors do not expose the response body', () async {
    final provider = ChatCompletionsProvider(clientFactory: () => MockClient((_) async => http.Response('secret response', 401)));
    await expectLater(provider.complete(settings, [], const Duration(seconds: 2)), throwsA(
      isA<PolicyException>().having((e) => e.message, 'message', isNot(contains('secret response'))),
    ));
  });
}
