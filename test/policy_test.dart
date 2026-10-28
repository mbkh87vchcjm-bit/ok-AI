import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:personal_agent/src/browser.dart';
import 'package:personal_agent/src/policy.dart';

void main() {
  group('HTTPS and file policy', () {
    test('accepts a domain and computes an exact origin', () {
      final uri = InputPolicy.httpsUrl('https://Example.com:8443/a?q=1');
      expect(InputPolicy.origin(uri), 'https://example.com:8443');
      expect(InputPolicy.origin(InputPolicy.httpsUrl('https://example.com:443/x')), 'https://example.com');
    });

    test('rejects insecure, local, credentialed, and malformed links', () {
      for (final url in [
        'http://example.com', 'javascript:alert(1)', 'file:///etc/passwd',
        'https://u:p@example.com/', 'https://127.0.0.1/', 'https://[::1]/',
        'https://localhost/', 'https://device.local/', 'https://example.com\n.evil.com',
        'https://999.0.0.1/', 'https://a..example.com/',
      ]) {
        expect(() => InputPolicy.httpsUrl(url), throwsA(isA<PolicyException>()), reason: url);
      }
    });

    test('provider endpoints cannot hide credentials in query parameters', () {
      expect(() => InputPolicy.httpsUrl('https://api.example.com/v1/chat?key=abc', modelEndpoint: true),
          throwsA(isA<PolicyException>()));
    });

    test('limits file paths and content', () {
      expect(InputPolicy.relativeOutputPath('src/main.dart'), 'src/main.dart');
      expect(InputPolicy.relativeOutputPath('.gitignore'), '.gitignore');
      for (final path in ['../x.dart', '/x.dart', 'a/../../x.dart', r'a\x.dart', 'a/.git/config.txt', 'x.exe', 'a//x.txt']) {
        expect(() => InputPolicy.relativeOutputPath(path), throwsA(isA<PolicyException>()), reason: path);
      }
      expect(() => InputPolicy.outputContent('a' * 65537), throwsA(isA<PolicyException>()));
      expect(() => InputPolicy.outputContent('a\u0000b'), throwsA(isA<PolicyException>()));
    });

    test('model-controlled strings are JSON literals, not executable JS', () {
      const selector = '"; window.pwned=1; //';
      const text = '"; window.leak(document.cookie); //\n';
      final script = BrowserScripts.typeText(selector, text, 'https://example.com/');
      expect(script, contains('const selector = ${jsonEncode(selector)};'));
      expect(script, contains('const text = ${jsonEncode(text)};'));
      expect(script, contains('one-time'));
      expect(script, contains("['password','file','hidden'"));
    });
  });

  group('approval scopes', () {
    test('denial is sticky for the task and never prompts twice', () async {
      var prompts = 0;
      final p = TaskPermissions(prompt: (_) async { prompts++; return ApprovalScope.deny; },
          persistent: {}, persist: (_) async {});
      const request = PermissionRequest(action: 'navigate', origin: 'https://example.com', description: 'test', ruleEligible: true);
      expect(await p.authorize(request), PermissionDecision.denied);
      expect(await p.authorize(request), PermissionDecision.previouslyDenied);
      expect(prompts, 1);
      p.beginTask();
      expect(await p.authorize(request), PermissionDecision.denied);
      expect(prompts, 2);
    });

    test('permanent grants are exact action and origin and can be revoked', () async {
      var prompts = 0;
      var saved = <String>{};
      final p = TaskPermissions(prompt: (_) async { prompts++; return ApprovalScope.permanent; },
          persistent: {}, persist: (value) async { saved = value; });
      const nav = PermissionRequest(action: 'redirect', origin: 'https://example.com', description: 'test', ruleEligible: true);
      const other = PermissionRequest(action: 'redirect', origin: 'https://other.com', description: 'test', ruleEligible: true);
      expect(await p.authorize(nav), PermissionDecision.approved);
      expect(await p.authorize(nav), PermissionDecision.approved);
      expect(prompts, 1);
      expect(saved, contains('redirect|https://example.com'));
      await p.authorize(other);
      expect(prompts, 2);
      await p.revoke(nav.key);
      await p.authorize(nav);
      expect(prompts, 3);
    });

    test('sensitive tools cannot get blanket grants even if a UI returns permanent', () async {
      var prompts = 0;
      final p = TaskPermissions(prompt: (_) async { prompts++; return ApprovalScope.permanent; },
          persistent: {'save_file|local'}, persist: (_) async {});
      const save = PermissionRequest(action: 'save_file', origin: 'local', description: 'test', ruleEligible: true);
      const navigate = PermissionRequest(action: 'navigate', origin: 'https://example.com', description: 'test', ruleEligible: true);
      await p.authorize(save);
      await p.authorize(save);
      await p.authorize(navigate);
      await p.authorize(navigate);
      expect(prompts, 4);
    });
  });
}
