import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:personal_agent/main.dart' as app;
import 'package:personal_agent/src/browser.dart';
import 'package:personal_agent/src/policy.dart';
import 'package:webview_flutter/webview_flutter.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('app opens and the browser and settings tabs are visible', (tester) async {
    app.main();
    await tester.pumpAndSettle(const Duration(seconds: 1), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 45));
    expect(find.text('OK AI — وكيل تحت إشرافك'), findsOneWidget);
    await tester.tap(find.text('الإعدادات').last);
    await tester.pumpAndSettle();
    expect(find.text('الإعدادات والصلاحيات'), findsOneWidget);
    await tester.tap(find.text('المتصفح').last);
    await tester.pumpAndSettle();
    expect(find.byType(WebViewWidget), findsOneWidget);
    expect(find.text('فتح'), findsOneWidget);
  });

  testWidgets('Android WebView loads and reads one public HTTPS page', (tester) async {
    final browser = WebViewBrowser();
    await browser.initialize();
    final loaded = Completer<String>();
    browser.onPageLoaded = (url) {
      if (url.startsWith('https://example.org/') && !loaded.isCompleted) loaded.complete(url);
    };
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: WebViewWidget(controller: browser.controller))));
    await tester.runAsync(() async {
      await browser.navigate(InputPolicy.httpsUrl('https://example.org/'));
      await loaded.future.timeout(const Duration(seconds: 60));
      final snapshot = await browser.readPage();
      expect(snapshot.url, startsWith('https://example.org/'));
      // The public page's heading changes; verify real page text, not a fixed title.
      expect(snapshot.text.toLowerCase(), contains('domain'));
      expect(snapshot.text, isNot(contains('ERR_')));
      expect(snapshot.text.toLowerCase(), isNot(contains('web page not available')));
    });
  });
}
