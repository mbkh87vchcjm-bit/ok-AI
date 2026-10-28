import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:personal_agent/src/local_store.dart';
import 'package:personal_agent/src/policy.dart';

void main() {
  late Directory dir;
  late LocalStore store;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('personal-agent-test-');
    store = LocalStore(dir);
    await store.load();
  });
  tearDown(() async { if (await dir.exists()) await dir.delete(recursive: true); });

  test('rules and UTF-8 references persist; retrieval includes a citation', () async {
    await store.saveRule(text: 'اختبر باللغة العربية');
    await store.importReference('guide.md', Uint8List.fromList(utf8.encode('Heading\nExpense totals are grouped by category.\nAnother line')));
    final result = store.referenceExcerpts('create an expense tracker');
    expect(result, contains('[guide.md:2]'));
    final restored = LocalStore(dir);
    await restored.load();
    expect(restored.rules.single.text, 'اختبر باللغة العربية');
    expect(restored.references.single.text, contains('Expense totals'));
    await restored.deleteRule(restored.rules.single.id);
    await restored.deleteReference(restored.references.single.id);
    final empty = LocalStore(dir);
    await empty.load();
    expect(empty.rules, isEmpty);
    expect(empty.references, isEmpty);
  });

  test('import rejects unsupported and binary content', () async {
    await expectLater(store.importReference('x.pdf', Uint8List.fromList([1, 2])), throwsA(isA<PolicyException>()));
    await expectLater(store.importReference('x.txt', Uint8List.fromList([0xff, 0xfe])), throwsA(isA<FormatException>()));
    await expectLater(store.importReference('x.txt', Uint8List(InputPolicy.maxReferenceBytes + 1)), throwsA(isA<PolicyException>()));
  });

  test('output existence check creates nothing; writes stay beneath the root', () async {
    expect(await store.outputExists('src/main.dart'), isFalse);
    expect(await store.outputDirectory.exists(), isFalse);
    await store.saveOutput('src/main.dart', 'void main() {}');
    expect(await File('${store.outputDirectory.path}/src/main.dart').readAsString(), 'void main() {}');
    expect((await store.listOutputs()).length, 1);
    await expectLater(store.saveOutput('../escape.dart', 'x'), throwsA(isA<PolicyException>()));
  });

  test('cancellation prevents an output write', () async {
    await expectLater(store.saveOutput('a/b.txt', 'secret', canContinue: () => false), throwsA(isA<PolicyException>()));
    expect(await File('${store.outputDirectory.path}/a/b.txt').exists(), isFalse);
  });

  test('symlinks in output paths are rejected', () async {
    await store.outputDirectory.create();
    await Link('${store.outputDirectory.path}/escape').create(dir.path);
    await expectLater(store.saveOutput('escape/x.txt', 'bad'), throwsA(isA<PolicyException>()));
    expect(await File('${dir.path}/x.txt').exists(), isFalse);
  });

  test('procedures keep only fixed action names, never arguments or secrets', () async {
    await store.saveProcedure(['read_page', 'password=secret', 'click']);
    final raw = await File('${dir.path}/state.json').readAsString();
    expect(raw, isNot(contains('password=secret')));
    expect(store.procedures.single.actions, ['read_page', 'click']);
  });

  test('corrupt state is not silently overwritten', () async {
    final file = File('${dir.path}/state.json');
    await file.writeAsString('{not json');
    final broken = LocalStore(dir);
    await expectLater(broken.load(), throwsA(isA<FormatException>()));
    expect(await file.readAsString(), '{not json');
  });
}
