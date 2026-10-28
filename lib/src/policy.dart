import 'dart:convert';

/// Input validation is a safety boundary independent of model instructions.
class PolicyException implements Exception {
  const PolicyException(this.message);
  final String message;
  @override
  String toString() => message;
}

class InputPolicy {
  static const maxFileBytes = 65536;
  static const maxReferenceBytes = 65536;
  static const maxToolTextCharacters = 12000;

  /// Allows HTTPS domain names only. This is not DNS or network isolation:
  /// public-looking names may still resolve to private addresses.
  static Uri httpsUrl(String input, {bool modelEndpoint = false}) {
    final value = input.trim();
    if (value.isEmpty || value.length > 2048 || RegExp(r'[\x00-\x20\x7f]').hasMatch(value)) {
      throw const PolicyException('الرابط غير صالح.');
    }
    final uri = Uri.tryParse(value);
    if (uri == null || uri.scheme.toLowerCase() != 'https' || !uri.hasAuthority ||
        uri.userInfo.isNotEmpty || uri.host.isEmpty) {
      throw const PolicyException('يُسمح بروابط HTTPS ذات نطاق فقط، دون بيانات دخول في الرابط.');
    }
    final host = uri.host.toLowerCase();
    final labels = host.split('.');
    if (host.length > 253 || labels.length < 2 || host.endsWith('.') ||
        labels.any((part) => part.isEmpty || part.length > 63 ||
            !RegExp(r'^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$').hasMatch(part)) ||
        !RegExp(r'[a-z]').hasMatch(labels.last) ||
        const {'local', 'localhost', 'internal', 'test', 'invalid', 'example'}.contains(labels.last)) {
      throw const PolicyException('النطاق غير مدعوم؛ عناوين IP والنطاقات المحلية محظورة.');
    }
    try {
      if (uri.hasPort && (uri.port < 1 || uri.port > 65535)) {
        throw const PolicyException('منفذ الرابط غير صالح.');
      }
    } on FormatException {
      throw const PolicyException('منفذ الرابط غير صالح.');
    }
    if (modelEndpoint && (uri.hasQuery || uri.hasFragment)) {
      throw const PolicyException('يجب ألا يحتوي رابط مزود النموذج على معاملات أو جزء مجزأ.');
    }
    return uri;
  }

  static String origin(Uri uri) {
    final port = uri.hasPort && uri.port != 443 ? ':${uri.port}' : '';
    return 'https://${uri.host.toLowerCase()}$port';
  }

  static String relativeOutputPath(String value) {
    if (value.isEmpty || value.length > 180 || value.startsWith('/') ||
        value.contains('\\') || value.contains('\u0000')) {
      throw const PolicyException('مسار الملف غير صالح.');
    }
    final parts = value.split('/');
    if (parts.length > 8 || parts.any((part) => part.isEmpty || part.length > 64 ||
        part == '.' || part == '..' || part.contains('..') ||
        !RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(part) ||
        const {'.git', '.svn', '.hg'}.contains(part.toLowerCase()))) {
      throw const PolicyException('استخدم مسارًا نسبيًا بسيطًا دون خروج من مجلد النتائج.');
    }
    final name = parts.last.toLowerCase();
    const extensions = {
      'txt', 'md', 'json', 'dart', 'py', 'js', 'ts', 'html', 'css', 'yaml',
      'yml', 'xml', 'csv', 'java', 'kt', 'sql', 'sh', 'gitignore',
    };
    final extension = name == '.gitignore' ? 'gitignore' : name.split('.').last;
    if (!name.contains('.') || !extensions.contains(extension)) {
      throw const PolicyException('امتداد الملف غير مدعوم في هذه النسخة.');
    }
    return parts.join('/');
  }

  static void outputContent(String content) {
    if (utf8.encode(content).length > maxFileBytes || content.contains('\u0000')) {
      throw const PolicyException('محتوى الملف كبير جدًا أو يحتوي على بيانات غير نصية.');
    }
  }

  static String selector(String value) {
    if (value.trim().isEmpty || value.length > 256 || RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) {
      throw const PolicyException('محدد العنصر غير صالح.');
    }
    return value;
  }
}

enum ApprovalScope { deny, once, task, permanent }

enum PermissionDecision { approved, denied, previouslyDenied }

class PermissionRequest {
  const PermissionRequest({
    required this.action,
    required this.origin,
    required this.description,
    this.content,
    this.ruleEligible = false,
  });
  final String action;
  final String origin;
  final String description;
  final String? content;
  /// Only low-risk navigation can be granted beyond the individual action.
  final bool ruleEligible;
  String get key => '$action|$origin';
}

typedef PermissionPrompt = Future<ApprovalScope> Function(PermissionRequest request);
typedef PersistPermissions = Future<void> Function(Set<String> permissions);

/// A denial is sticky for the whole task. High-risk actions always re-prompt.
class TaskPermissions {
  TaskPermissions({required this.prompt, required Set<String> persistent, required this.persist})
      : _persistent = Set.of(persistent);

  final PermissionPrompt prompt;
  final PersistPermissions persist;
  final Set<String> _persistent;
  final Set<String> _task = {};
  final Set<String> _denied = {};

  Set<String> get persistent => Set.unmodifiable(_persistent);

  void beginTask() {
    _task.clear();
    _denied.clear();
  }

  Future<void> revoke(String key) async {
    _persistent.remove(key);
    _task.remove(key);
    await persist(Set.of(_persistent));
  }

  Future<PermissionDecision> authorize(PermissionRequest request) async {
    if (_denied.contains(request.key)) return PermissionDecision.previouslyDenied;
    if (request.ruleEligible && (_task.contains(request.key) || _persistent.contains(request.key))) {
      return PermissionDecision.approved;
    }
    final scope = await prompt(request);
    if (scope == ApprovalScope.deny) {
      _denied.add(request.key);
      return PermissionDecision.denied;
    }
    // A malicious or buggy UI cannot create broad grants for sensitive tools.
    if (request.ruleEligible && scope == ApprovalScope.task) {
      _task.add(request.key);
    } else if (request.ruleEligible && scope == ApprovalScope.permanent) {
      _persistent.add(request.key);
      try {
        await persist(Set.of(_persistent));
      } catch (_) {
        _persistent.remove(request.key);
        rethrow;
      }
    }
    return PermissionDecision.approved;
  }
}
