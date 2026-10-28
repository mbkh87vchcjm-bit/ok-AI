import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:personal_agent/src/agent.dart';
import 'package:personal_agent/src/browser.dart';
import 'package:personal_agent/src/local_store.dart';
import 'package:personal_agent/src/policy.dart';
import 'package:personal_agent/src/provider.dart';

class FakeBrowser implements BrowserPort {
  @override
  int revision = 1;
  String url = 'https://example.com/';
  bool human = false;
  int navigations = 0;
  int clicks = 0;
  int writes = 0;
  @override
  Future<String?> currentUrl() async => url;
  @override
  Future<bool> needsIntervention() async => human;
  @override
  Future<BrowserSnapshot> readPage() async => BrowserSnapshot(url: url, title: 'page', text: 'PRIVATE PAGE SENTINEL', elements: const [{'selector': '#safe', 'tag': 'button', 'label': 'Safe'}], revision: revision);
  @override
  Future<void> navigate(Uri target) async { navigations++; url = target.toString(); revision++; }
  @override
  Future<void> click(String selector, String expectedUrl, int expectedRevision) async { clicks++; }
  @override
  Future<void> typeText(String selector, String text, String expectedUrl, int expectedRevision) async { writes++; }
}

class FakeProvider implements ModelProvider {
  FakeProvider(this.responses);
  final List<Future<ModelReply> Function()> responses;
  final List<List<Map<String, Object?>>> sent = [];
  final Completer<void> firstCalled = Completer<void>();
  int cancelled = 0;
  @override
  Future<ModelReply> complete(ModelSettings settings, List<Map<String, Object?>> messages, Duration timeout) async {
    sent.add(messages.map((m) => Map<String, Object?>.from(jsonDecode(jsonEncode(m)) as Map)).toList());
    if (!firstCalled.isCompleted) firstCalled.complete();
    if (responses.isEmpty) throw StateError('unexpected request');
    return responses.removeAt(0)();
  }
  @override
  void cancel() { cancelled++; }
}

ModelReply turn({String content = '', List<ToolCall> tools = const [], ModelUsage? usage}) =>
    ModelReply(content: content, tools: tools, usage: usage);
ToolCall nav() => const ToolCall(id: 'call_1', name: 'navigate', arguments: '{"url":"https://example.com/next"}');
ToolCall read() => const ToolCall(id: 'call_1', name: 'read_page', arguments: '{}');

void main() {
  late Directory dir;
  late LocalStore store;
  late FakeBrowser browser;
  final settings = ModelSettings(endpoint: 'https://api.example.com/v1/chat/completions', model: 'model', apiKey: 'test-key');
  AgentLimits limits({bool budget = false}) => AgentLimits(maxSteps: 10, maxCalls: 5, maxFailures: 3,
      maxDuration: const Duration(minutes: 1), maxEstimatedUsd: budget ? 1 : null,
      inputUsdPerMillion: budget ? 1 : null, outputUsdPerMillion: budget ? 1 : null);
  TaskPermissions permission(PermissionPrompt prompt) => TaskPermissions(prompt: prompt, persistent: {}, persist: (_) async {});
  AgentController agentFor(FakeProvider provider, TaskPermissions p) => AgentController(
      provider: provider, browser: browser, store: store, permissions: p, askUser: (_) async => null);
  Future<void> start(AgentController agent, {bool budget = false}) => agent.start(
      settings: settings, limits: limits(budget: budget), task: 'build a program', approvedRules: [], references: '');
  Completer<void> whenPhase(AgentController agent, TaskPhase target) {
    final found = Completer<void>();
    agent.addListener(() { if (!found.isCompleted && agent.phase == target) found.complete(); });
    return found;
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('agent-runner-test-');
    store = LocalStore(dir);
    await store.load();
    browser = FakeBrowser();
  });
  tearDown(() async { if (await dir.exists()) await dir.delete(recursive: true); });

  test('a denied tool pauses and cannot be repeated after resume', () async {
    var prompts = 0;
    final provider = FakeProvider([
      () async => turn(tools: [nav()]),
      () async => turn(tools: [nav()]),
    ]);
    final agent = agentFor(provider, permission((_) async { prompts++; return ApprovalScope.deny; }));
    final paused = whenPhase(agent, TaskPhase.paused);
    final run = start(agent);
    await paused.future.timeout(const Duration(seconds: 2));
    expect(browser.navigations, 0);
    expect(provider.sent.length, 1, reason: 'no automatic retry while paused');
    agent.resume();
    await run.timeout(const Duration(seconds: 2));
    expect(browser.navigations, 0);
    expect(prompts, 1);
    expect(agent.phase, TaskPhase.failed);
    expect(agent.lastError, contains('سبق رفضه'));
    agent.dispose();
  });

  test('cancel while approval is pending never starts the action', () async {
    final shown = Completer<void>();
    final approval = Completer<ApprovalScope>();
    final provider = FakeProvider([() async => turn(tools: [nav()])]);
    final agent = agentFor(provider, permission((_) {
      shown.complete();
      return approval.future;
    }));
    final run = start(agent);
    await shown.future.timeout(const Duration(seconds: 2));
    agent.cancel();
    approval.complete(ApprovalScope.once);
    await run.timeout(const Duration(seconds: 2));
    expect(agent.phase, TaskPhase.cancelled);
    expect(browser.navigations, 0);
    expect(provider.sent.length, 1);
    agent.dispose();
  });

  test('manual takeover discards a model reply generated for stale state', () async {
    final pending = Completer<ModelReply>();
    final provider = FakeProvider([
      () => pending.future,
      () async => turn(content: 'انتهى'),
    ]);
    final agent = agentFor(provider, permission((_) async => ApprovalScope.once));
    final run = start(agent);
    await provider.firstCalled.future.timeout(const Duration(seconds: 2));
    agent.takeManual();
    pending.complete(turn(tools: [nav()]));
    await Future<void>.delayed(Duration.zero);
    expect(browser.navigations, 0);
    agent.resume();
    await run.timeout(const Duration(seconds: 2));
    expect(agent.phase, TaskPhase.completed);
    expect(browser.navigations, 0);
    expect(jsonEncode(provider.sent.last), contains('لا تعتمد على أي عنصر'));
    agent.dispose();
  });

  test('rejecting page sharing does not leak page text to the model', () async {
    final provider = FakeProvider([
      () async => turn(tools: [read()]),
      () async => turn(content: 'توقفت عن مشاركة الصفحة'),
    ]);
    final agent = agentFor(provider, permission((request) async =>
        request.action == 'share_page' ? ApprovalScope.deny : ApprovalScope.once));
    final paused = whenPhase(agent, TaskPhase.paused);
    final run = start(agent);
    await paused.future.timeout(const Duration(seconds: 2));
    agent.resume();
    await run.timeout(const Duration(seconds: 2));
    expect(jsonEncode(provider.sent), isNot(contains('PRIVATE PAGE SENTINEL')));
    expect(agent.phase, TaskPhase.completed);
    agent.dispose();
  });

  test('refusing page sharing also prevents automatically reading it again', () async {
    var readPrompts = 0;
    final provider = FakeProvider([
      () async => turn(tools: [read()]),
      () async => turn(tools: [read()]),
    ]);
    final agent = agentFor(provider, permission((request) async {
      if (request.action == 'read_page') readPrompts++;
      return request.action == 'share_page' ? ApprovalScope.deny : ApprovalScope.once;
    }));
    final paused = whenPhase(agent, TaskPhase.paused);
    final run = start(agent);
    await paused.future.timeout(const Duration(seconds: 2));
    agent.resume();
    await run.timeout(const Duration(seconds: 2));
    expect(readPrompts, 1);
    expect(agent.phase, TaskPhase.failed);
    expect(jsonEncode(provider.sent), isNot(contains('PRIVATE PAGE SENTINEL')));
    agent.dispose();
  });

  test('challenge detection switches to manual before reading a page', () async {
    browser.human = true;
    final provider = FakeProvider([() async => turn(tools: [read()])]);
    final agent = agentFor(provider, permission((_) async => ApprovalScope.once));
    final manual = whenPhase(agent, TaskPhase.manual);
    final run = start(agent);
    await manual.future.timeout(const Duration(seconds: 2));
    expect(browser.clicks, 0);
    expect(jsonEncode(provider.sent), isNot(contains('PRIVATE PAGE SENTINEL')));
    agent.cancel();
    await run.timeout(const Duration(seconds: 2));
    agent.dispose();
  });

  test('unobserved selectors cannot be clicked even if the model requests them', () async {
    const call = ToolCall(id: 'call_2', name: 'click', arguments: '{"selector":"#not-observed"}');
    final provider = FakeProvider([
      () async => turn(tools: [read()]),
      () async => turn(tools: [call]),
      () async => turn(content: 'انتهى'),
    ]);
    final agent = agentFor(provider, permission((_) async => ApprovalScope.once));
    await start(agent);
    expect(browser.clicks, 0);
    expect(agent.failures, 1);
    expect(jsonEncode(provider.sent), contains('المحدد غير موجود'));
    agent.dispose();
  });

  test('configured budget fails closed if token usage is missing', () async {
    final provider = FakeProvider([() async => turn(tools: [nav()])]);
    final agent = agentFor(provider, permission((_) async => ApprovalScope.once));
    await start(agent, budget: true);
    expect(agent.phase, TaskPhase.failed);
    expect(browser.navigations, 0);
    expect(agent.lastError, contains('عدد الرموز'));
    agent.dispose();
  });
}
