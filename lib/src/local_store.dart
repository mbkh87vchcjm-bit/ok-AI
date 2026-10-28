import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'policy.dart';

class ProjectRule {
  const ProjectRule(this.id, this.text);
  final String id;
  final String text;
  Map<String, Object?> toJson() => {'id': id, 'text': text};
}

class ReferenceDocument {
  const ReferenceDocument(this.id, this.name, this.text);
  final String id;
  final String name;
  final String text;
  Map<String, Object?> toJson() => {'id': id, 'name': name, 'text': text};
}

class Procedure {
  const Procedure(this.createdAt, this.actions);
  final DateTime createdAt;
  /// Fixed tool names only: no arguments, selectors, pages or user content.
  final List<String> actions;
  Map<String, Object?> toJson() => {'createdAt': createdAt.toIso8601String(), 'actions': actions};
}

/// App-private local storage. It is deliberately not advertised as encrypted.
class LocalStore {
  LocalStore(this.root);
  final Directory root;
  final List<ProjectRule> rules = [];
  final List<ReferenceDocument> references = [];
  final List<Procedure> procedures = [];
  final Set<String> permissions = {};
  Future<void> _writeTail = Future.value();

  static const allowedProcedureActions = {
    'read_page', 'navigate', 'click', 'type_text', 'save_file', 'ask_user',
  };

  File get _stateFile => File(p.join(root.path, 'state.json'));
  Directory get outputDirectory => Directory(p.join(root.path, 'outputs'));

  Future<void> load() async {
    await root.create(recursive: true);
    if (!await _stateFile.exists()) return;
    // Do not replace corrupt data with an empty database.
    final decoded = jsonDecode(await _stateFile.readAsString());
    if (decoded is! Map<String, dynamic> || decoded['version'] != 1) {
      throw const FormatException('تعذر قراءة البيانات المحلية؛ لم يتم استبدالها.');
    }
    final loadedRules = <ProjectRule>[];
    final loadedReferences = <ReferenceDocument>[];
    final loadedProcedures = <Procedure>[];
    for (final item in (decoded['rules'] as List<dynamic>? ?? [])) {
      final m = item as Map<String, dynamic>;
      loadedRules.add(ProjectRule(m['id'] as String, m['text'] as String));
    }
    for (final item in (decoded['references'] as List<dynamic>? ?? [])) {
      final m = item as Map<String, dynamic>;
      loadedReferences.add(ReferenceDocument(m['id'] as String, m['name'] as String, m['text'] as String));
    }
    for (final item in (decoded['procedures'] as List<dynamic>? ?? [])) {
      final m = item as Map<String, dynamic>;
      final actions = (m['actions'] as List<dynamic>).cast<String>();
      if (actions.any((a) => !allowedProcedureActions.contains(a))) {
        throw const FormatException('الإجراء المحلي غير صالح.');
      }
      loadedProcedures.add(Procedure(DateTime.parse(m['createdAt'] as String), actions));
    }
    final loadedPermissions = (decoded['permissions'] as List<dynamic>? ?? []).cast<String>();
    rules..clear()..addAll(loadedRules);
    references..clear()..addAll(loadedReferences);
    procedures..clear()..addAll(loadedProcedures);
    permissions..clear()..addAll(loadedPermissions);
  }

  Future<void> _persist() {
    final snapshot = jsonEncode({
      'version': 1,
      'rules': rules.map((r) => r.toJson()).toList(),
      'references': references.map((r) => r.toJson()).toList(),
      'procedures': procedures.map((r) => r.toJson()).toList(),
      'permissions': permissions.toList()..sort(),
    });
    final current = _writeTail.then((_) async {
      await root.create(recursive: true);
      final temp = File('${_stateFile.path}.tmp');
      await temp.writeAsString(snapshot, flush: true);
      await temp.rename(_stateFile.path);
    });
    _writeTail = current.catchError((Object _) {});
    return current;
  }

  String _id() => '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}';

  Future<void> saveRule({String? id, required String text}) async {
    final clean = text.trim();
    if (clean.isEmpty || clean.length > 2000) {
      throw const PolicyException('القاعدة فارغة أو أطول من 2000 حرف.');
    }
    final i = id == null ? -1 : rules.indexWhere((r) => r.id == id);
    if (id != null && i < 0) throw const PolicyException('القاعدة غير موجودة.');
    if (i < 0) {
      if (rules.length >= 50) throw const PolicyException('تم بلوغ حد القواعد.');
      rules.add(ProjectRule(_id(), clean));
    } else {
      rules[i] = ProjectRule(id!, clean);
    }
    await _persist();
  }

  Future<void> deleteRule(String id) async {
    rules.removeWhere((r) => r.id == id);
    await _persist();
  }

  Future<void> importReference(String filename, Uint8List bytes) async {
    if (references.length >= 20 || bytes.length > InputPolicy.maxReferenceBytes) {
      throw const PolicyException('بلغت المكتبة الحد المسموح أو الملف يتجاوز 64 كيلوبايت.');
    }
    final name = p.basename(filename).replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '');
    final ext = p.extension(name).toLowerCase();
    const allowed = {'.txt', '.md', '.dart', '.py', '.js', '.ts', '.json', '.yaml', '.yml', '.html', '.css', '.java', '.kt', '.sql'};
    if (name.isEmpty || name.length > 150 || !allowed.contains(ext)) {
      throw const PolicyException('صيغة المرجع غير مدعومة. PDF مؤجل.');
    }
    final text = utf8.decode(bytes, allowMalformed: false);
    if (text.contains('\u0000')) throw const PolicyException('المرجع ليس نصًا صالحًا.');
    final currentBytes = references.fold<int>(0, (sum, ref) => sum + utf8.encode(ref.text).length);
    if (currentBytes + bytes.length > 1024 * 1024) {
      throw const PolicyException('بلغت المكتبة حد ميغابايت واحد.');
    }
    references.add(ReferenceDocument(_id(), name, text));
    await _persist();
  }

  Future<void> deleteReference(String id) async {
    references.removeWhere((r) => r.id == id);
    await _persist();
  }

  /// Simple on-device retrieval; citations are filename and line number.
  /// It is keyword-based, not semantic search or model training.
  String referenceExcerpts(String task) {
    final terms = task.toLowerCase().split(RegExp(r'[^a-z0-9\u0600-\u06ff_]+'))
        .where((s) => s.length >= 3).toSet().take(24).toList();
    final snippets = <String>[];
    var remaining = 5000;
    for (final ref in references.take(5)) {
      final lines = const LineSplitter().convert(ref.text);
      if (lines.isEmpty) continue;
      final matches = <({int index, int score})>[];
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i].toLowerCase();
        final score = terms.where(line.contains).length;
        if (score > 0) matches.add((index: i, score: score));
      }
      matches.sort((a, b) => b.score.compareTo(a.score));
      // A visible, cited fallback allows a reference written in a different
      // language to contribute, but is never sent without the consent preview.
      final chosen = matches.isEmpty ? [0] : matches.take(3).map((m) => m.index).toList();
      for (final i in chosen) {
        if (remaining <= 0) break;
        final line = lines[i];
        final size = [line.length, 500, remaining].reduce(min);
        final snippet = '[${ref.name}:${i + 1}] ${line.substring(0, size)}';
        snippets.add(snippet);
        remaining -= snippet.length;
      }
    }
    return snippets.join('\n');
  }

  Future<void> saveProcedure(List<String> actions) async {
    final safe = actions.where(allowedProcedureActions.contains).take(40).toList();
    if (safe.isEmpty) throw const PolicyException('لا توجد خطوات لحفظها.');
    if (procedures.length >= 30) throw const PolicyException('بلغت حد الإجراءات المحفوظة.');
    procedures.add(Procedure(DateTime.now().toUtc(), List.unmodifiable(safe)));
    await _persist();
  }

  Future<void> deleteProcedure(int index) async {
    procedures.removeAt(index);
    await _persist();
  }

  Future<void> savePermissions(Set<String> newPermissions) async {
    permissions..clear()..addAll(newPermissions);
    await _persist();
  }

  Future<File> _outputFile(String relative) async {
    final path = InputPolicy.relativeOutputPath(relative);
    await outputDirectory.create(recursive: true);
    var parent = outputDirectory.path;
    final parts = path.split('/');
    for (final part in parts.take(parts.length - 1)) {
      parent = p.join(parent, part);
      final type = await FileSystemEntity.type(parent, followLinks: false);
      if (type == FileSystemEntityType.link || (type != FileSystemEntityType.notFound && type != FileSystemEntityType.directory)) {
        throw const PolicyException('مسار الإخراج غير آمن.');
      }
      await Directory(parent).create();
    }
    final file = File(p.join(parent, parts.last));
    if (await FileSystemEntity.type(file.path, followLinks: false) == FileSystemEntityType.link) {
      throw const PolicyException('لا يُسمح بكتابة روابط الملفات.');
    }
    return file;
  }

  Future<bool> outputExists(String relative) async => (await _outputFile(relative)).exists();

  Future<void> saveOutput(String relative, String content) async {
    InputPolicy.outputContent(content);
    final file = await _outputFile(relative);
    final temp = File('${file.path}.tmp-${_id()}');
    try {
      await temp.writeAsString(content, flush: true);
      await temp.rename(file.path);
    } finally {
      if (await temp.exists()) await temp.delete();
    }
  }

  Future<List<File>> listOutputs() async {
    if (!await outputDirectory.exists()) return [];
    final files = <File>[];
    await for (final entity in outputDirectory.list(recursive: true, followLinks: false)) {
      if (entity is File && await FileSystemEntity.type(entity.path, followLinks: false) == FileSystemEntityType.file) {
        files.add(entity);
      }
    }
    files.sort((a, b) => a.path.compareTo(b.path));
    return files;
  }
}
