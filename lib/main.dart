import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'src/agent.dart';
import 'src/browser.dart';
import 'src/local_store.dart';
import 'src/policy.dart';
import 'src/provider.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const PersonalAgentApp());
}

class PersonalAgentApp extends StatelessWidget {
  const PersonalAgentApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'OK AI',
        theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff295c91)), useMaterial3: true),
        builder: (context, child) => Directionality(textDirection: TextDirection.rtl, child: child!),
        home: const HomePage(),
      );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _task = TextEditingController();
  final _address = TextEditingController();
  final _endpoint = TextEditingController();
  final _model = TextEditingController();
  final _apiKey = TextEditingController();
  final _maxSteps = TextEditingController(text: '20');
  final _maxCalls = TextEditingController(text: '8');
  final _maxFailures = TextEditingController(text: '3');
  final _minutes = TextEditingController(text: '15');
  final _budget = TextEditingController(text: '1.00');
  final _inputRate = TextEditingController();
  final _outputRate = TextEditingController();

  LocalStore? _store;
  WebViewBrowser? _browser;
  TaskPermissions? _permissions;
  AgentController? _agent;
  Future<List<File>>? _outputFiles;
  String? _initializationError;
  bool _ready = false;
  bool _starting = false;
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final store = LocalStore(Directory(p.join(docs.path, 'personal_agent')));
      await store.load();
      final browser = WebViewBrowser();
      await browser.initialize();
      final permissions = TaskPermissions(prompt: _showPermission, persistent: store.permissions, persist: (value) async {
        await store.savePermissions(value);
        if (mounted) setState(() {});
      });
      final agent = AgentController(
        provider: ChatCompletionsProvider(), browser: browser, store: store,
        permissions: permissions, askUser: _askUser,
      );
      browser.onCrossOrigin = (target) => _crossOrigin(permissions, agent, target);
      browser.onIntervention = () {
        if (agent.phase == TaskPhase.running) {
          agent.takeManual(reason: 'قد تتطلب الصفحة تسجيل دخول أو CAPTCHA أو تحققًا. أكمل ذلك يدويًا ثم اضغط متابعة. الاكتشاف تقريبي.');
          if (mounted) {
            setState(() => _tab = 1);
            _message('تدخل يدوي مطلوب. لا تحاول أدوات الوكيل تجاوز التحقق.');
          }
        }
      };
      agent.addListener(_onAgentChange);
      if (!mounted) {
        agent.dispose();
        return;
      }
      setState(() {
        _store = store;
        _browser = browser;
        _permissions = permissions;
        _agent = agent;
        _outputFiles = store.listOutputs();
        _ready = true;
      });
    } catch (_) {
      if (mounted) setState(() => _initializationError = 'تعذر فتح التخزين المحلي أو المتصفح. لم تُحذف البيانات الموجودة.');
    }
  }

  void _onAgentChange() {
    if (!mounted) return;
    setState(() {
      if (_store != null) _outputFiles = _store!.listOutputs();
    });
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  String _error(Object e) => e is PolicyException ? e.message : 'تعذر إكمال العملية. تحقق من المدخلات وحاول مجددًا.';

  Future<ApprovalScope> _showPermission(PermissionRequest request) async {
    if (!mounted) return ApprovalScope.deny;
    return await showDialog<ApprovalScope>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) => Directionality(
            textDirection: TextDirection.rtl,
            child: AlertDialog(
              title: const Text('موافقة مطلوبة'),
              content: SizedBox(
                width: 560,
                child: SingleChildScrollView(child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('الإجراء: ${request.action}\nالنطاق: ${request.origin}', style: const TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Text(request.description),
                    if (request.content != null) ...[
                      const SizedBox(height: 12),
                      const Text('تفاصيل الإجراء:', style: TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 4),
                      SelectableText(request.content!),
                    ],
                    const SizedBox(height: 10),
                    Text(request.ruleEligible
                        ? 'القاعدة تشمل نوع الإجراء والنطاق المحدد فقط. الإجراءات الحساسة تطلب موافقة مستقلة دائمًا.'
                        : 'هذه الموافقة لمرة واحدة فقط. الرفض يوقف الخطوة ولا يعيد طلبها في المهمة.'),
                  ],
                )),
              ),
              actions: [
                Wrap(spacing: 8, runSpacing: 4, children: [
                  TextButton(onPressed: () => Navigator.pop(dialogContext, ApprovalScope.deny), child: const Text('رفض')),
                  FilledButton.tonal(onPressed: () => Navigator.pop(dialogContext, ApprovalScope.once), child: const Text('هذه المرة')),
                  if (request.ruleEligible)
                    OutlinedButton(onPressed: () => Navigator.pop(dialogContext, ApprovalScope.task), child: const Text('لهذه المهمة')),
                  if (request.ruleEligible)
                    OutlinedButton(onPressed: () => Navigator.pop(dialogContext, ApprovalScope.permanent), child: const Text('قاعدة دائمة')),
                ]),
              ],
            ),
          ),
        ) ?? ApprovalScope.deny;
  }

  Future<String?> _askUser(String question) async {
    if (!mounted) return null;
    final text = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('توضيح من المستخدم'),
        content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(question),
          const SizedBox(height: 10),
          const Text('لا تكتب كلمات مرور أو رموز تحقق أو مفاتيح. ستُطلب موافقة أخرى قبل إرسال الإجابة.'),
          TextField(controller: text, maxLines: 4, maxLength: 4000, decoration: const InputDecoration(labelText: 'الإجابة')),
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('رفض')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, text.text), child: const Text('متابعة')),
        ],
      ),
    );
    text.dispose();
    return result;
  }

  Future<bool> _crossOrigin(TaskPermissions permissions, AgentController agent, Uri target) async {
    final wasRunning = agent.phase == TaskPhase.running;
    if (!agent.isActive) permissions.beginTask();
    try {
      final decision = await permissions.authorize(PermissionRequest(
        action: 'redirect', origin: InputPolicy.origin(target),
        description: 'تحاول الصفحة الانتقال إلى نطاق مختلف. لا تشمل هذه الموافقة موارد الصفحة الفرعية أو طلبات JavaScript.',
        content: target.toString(), ruleEligible: true,
      ));
      if (wasRunning && agent.phase != TaskPhase.running) return false;
      if (decision != PermissionDecision.approved && agent.phase == TaskPhase.running) {
        agent.pause(reason: 'رُفض الانتقال إلى نطاق مختلف؛ لن يُعاد السماح به في هذه المهمة.');
      }
      return decision == PermissionDecision.approved;
    } catch (_) {
      return false;
    }
  }

  AgentLimits _readLimits() {
    int number(TextEditingController c, String name) => int.tryParse(c.text.trim()) ?? (throw PolicyException('أدخل $name صحيحًا.'));
    final budgetText = _budget.text.trim();
    final budget = budgetText.isEmpty ? null : double.tryParse(budgetText);
    if (budgetText.isNotEmpty && budget == null) throw const PolicyException('ميزانية التكلفة غير صالحة.');
    final input = _inputRate.text.trim().isEmpty ? null : double.tryParse(_inputRate.text.trim());
    final output = _outputRate.text.trim().isEmpty ? null : double.tryParse(_outputRate.text.trim());
    return AgentLimits(maxSteps: number(_maxSteps, 'عدد الخطوات'), maxCalls: number(_maxCalls, 'عدد المكالمات'),
        maxFailures: number(_maxFailures, 'عدد الأخطاء'), maxDuration: Duration(minutes: number(_minutes, 'الوقت')),
        maxEstimatedUsd: budget, inputUsdPerMillion: input, outputUsdPerMillion: output);
  }

  Future<void> _startTask() async {
    final agent = _agent!;
    if (_starting || !agent.canStart) return;
    setState(() => _starting = true);
    try {
      final settings = ModelSettings(endpoint: _endpoint.text, model: _model.text, apiKey: _apiKey.text);
      final limits = _readLimits();
      final task = _task.text.trim();
      if (task.isEmpty || task.length > 12000) throw const PolicyException('أدخل مهمة لا تتجاوز 12000 حرف.');
      final rules = _store!.rules.map((r) => r.text).toList();
      final refs = _store!.referenceExcerpts(task);
      _permissions!.beginTask();
      final decision = await _permissions!.authorize(PermissionRequest(
        action: 'model_send', origin: InputPolicy.origin(settings.endpoint),
        description: 'ستُرسل المهمة والقواعد والمقتطفات التالية إلى API الخارجي، لا إلى موقع المتصفح تلقائيًا. قد تترتب تكلفة. مفتاح API في ترويسة الطلب فقط ولا يُحفظ.',
        content: 'النموذج: ${settings.model}\nمسار المزود: ${settings.endpoint}\n\nالمهمة:\n$task\n\nالقواعد المعتمدة:\n${rules.isEmpty ? '(لا توجد)' : rules.join('\n')}\n\nمقتطفات المراجع ومصادرها:\n${refs.isEmpty ? '(لا توجد مقتطفات)' : refs}\n\n${limits.maxEstimatedUsd == null ? 'تنبيه: لا يوجد حد تكلفة حتى التقديري؛ حد المكالمات فقط.' : 'حد التكلفة تقديري وغير مضمون؛ قد يفوتر المزود أكثر.'}',
      ));
      if (!mounted || decision != PermissionDecision.approved) return;
      unawaited(agent.start(settings: settings, limits: limits, task: task, approvedRules: rules, references: refs));
    } catch (e) {
      _message(_error(e));
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Future<void> _openAddress() async {
    final agent = _agent!;
    if (agent.phase == TaskPhase.running || agent.phase == TaskPhase.paused) {
      _message('تولّ التحكم يدويًا أولًا قبل تغيير الصفحة.');
      return;
    }
    try {
      final uri = InputPolicy.httpsUrl(_address.text);
      await _browser!.navigate(uri);
    } catch (e) {
      _message(_error(e));
    }
  }

  Future<bool> _confirm(String title, String description) async {
    if (!mounted) return false;
    return await showDialog<bool>(context: context, builder: (dialogContext) => AlertDialog(
      title: Text(title), content: Text(description), actions: [
        TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('إلغاء')),
        FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('تأكيد')),
      ],
    )) ?? false;
  }

  Future<void> _editRule([ProjectRule? rule]) async {
    final controller = TextEditingController(text: rule?.text ?? '');
    final value = await showDialog<String>(context: context, builder: (dialogContext) => AlertDialog(
      title: Text(rule == null ? 'إضافة قاعدة معتمدة' : 'تعديل القاعدة'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('تفضيل أو قاعدة مشروع فقط، دون أسرار. لا يمكن للقاعدة تجاوز سياسة الأمان.'),
        TextField(controller: controller, maxLines: 4, maxLength: 2000),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('إلغاء')),
        FilledButton(onPressed: () => Navigator.pop(dialogContext, controller.text), child: const Text('اعتماد وحفظ')),
      ],
    ));
    controller.dispose();
    if (value == null) return;
    try {
      await _store!.saveRule(id: rule?.id, text: value);
      if (mounted) setState(() {});
    } catch (e) { _message(_error(e)); }
  }

  Future<void> _deleteRule(ProjectRule rule) async {
    if (!await _confirm('حذف القاعدة؟', 'سيُحذف التفضيل من التخزين المحلي.')) return;
    try {
      await _store!.deleteRule(rule.id);
      if (mounted) setState(() {});
    } catch (e) { _message(_error(e)); }
  }

  Future<void> _importReference() async {
    try {
      final picked = await FilePicker.platform.pickFiles(type: FileType.custom, allowMultiple: false, withData: false,
          allowedExtensions: ['txt', 'md', 'dart', 'py', 'js', 'ts', 'json', 'yaml', 'yml', 'html', 'css', 'java', 'kt', 'sql']);
      if (picked == null) return;
      final file = picked.files.single;
      if (file.path == null || file.size > InputPolicy.maxReferenceBytes) {
        throw const PolicyException('تعذر فتح الملف أو أنه أكبر من 64 كيلوبايت.');
      }
      final bytes = BytesBuilder(copy: false);
      var length = 0;
      await for (final chunk in File(file.path!).openRead()) {
        length += chunk.length;
        if (length > InputPolicy.maxReferenceBytes) throw const PolicyException('الملف أكبر من 64 كيلوبايت.');
        bytes.add(chunk);
      }
      await _store!.importReference(file.name, bytes.takeBytes());
      if (mounted) setState(() {});
      _message('أُضيف المرجع محليًا؛ لن يُرسل إلا بعد معاينة المقتطفات والموافقة.');
    } catch (e) { _message(_error(e)); }
  }

  Future<void> _adoptReference(ReferenceDocument ref) async {
    final initial = ref.text.length > 2000 ? ref.text.substring(0, 2000) : ref.text;
    final controller = TextEditingController(text: initial);
    final value = await showDialog<String>(context: context, builder: (dialogContext) => AlertDialog(
      title: Text('اعتماد مقتطف من ${ref.name}'),
      content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(ref.text.length > 2000
            ? 'عُرض أول 2000 حرف فقط. راجع المقتطف وعدّله قبل اعتماده. لا تضع أسرارًا؛ لا يغير صلاحيات الأمان.'
            : 'راجع النص وعدّله قبل اعتماده قاعدة مشروع. لا تضع أسرارًا؛ لا يغير صلاحيات الأمان.'),
        TextField(controller: controller, minLines: 4, maxLines: 8, maxLength: 2000),
      ])),
      actions: [
        TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('إلغاء')),
        FilledButton(onPressed: () => Navigator.pop(dialogContext, controller.text), child: const Text('اعتماد كقاعدة')),
      ],
    ));
    controller.dispose();
    if (value == null) return;
    try {
      await _store!.saveRule(text: value);
      if (mounted) setState(() {});
    } catch (e) { _message(_error(e)); }
  }

  Future<void> _deleteReference(ReferenceDocument ref) async {
    if (!await _confirm('حذف المرجع؟', 'سيُحذف ${ref.name} من مكتبة التطبيق المحلية.')) return;
    try {
      await _store!.deleteReference(ref.id);
      if (mounted) setState(() {});
    } catch (e) { _message(_error(e)); }
  }

  Future<void> _saveProcedure() async {
    if (!await _confirm('اعتماد إجراء استرشادي؟', 'سيُحفظ تسلسل أسماء الأدوات فقط، دون نصوص أو محددات أو عناوين أو إجابات. تأكد أنت من نجاح المهمة أولًا؛ لن يُنفذ الإجراء تلقائيًا.')) return;
    try {
      await _store!.saveProcedure(_agent!.successfulActions);
      if (mounted) setState(() {});
      _message('حُفظ إجراء استرشادي دون معاملات.');
    } catch (e) { _message(_error(e)); }
  }

  Future<void> _deleteProcedure(int index) async {
    if (!await _confirm('حذف الإجراء؟', 'سيُحذف التسلسل الاسترشادي المحلي.')) return;
    try {
      await _store!.deleteProcedure(index);
      if (mounted) setState(() {});
    } catch (e) { _message(_error(e)); }
  }

  Future<void> _shareFile(File file) async {
    if (!await _confirm('تصدير الملف؟', 'سيعرض Android التطبيقات المتاحة للمشاركة. قد يرسل التطبيق الذي تختاره الملف خارج الجهاز.')) return;
    try {
      await Share.shareXFiles([XFile(file.path)]);
    } catch (e) { _message(_error(e)); }
  }

  String _phaseLabel(TaskPhase phase) => switch (phase) {
    TaskPhase.idle => 'جاهز', TaskPhase.running => 'يعمل', TaskPhase.paused => 'متوقف مؤقتًا',
    TaskPhase.manual => 'تحكم يدوي', TaskPhase.completed => 'انتهت المحادثة',
    TaskPhase.cancelled => 'ملغاة', TaskPhase.failed => 'متوقفة بسبب خطأ أو حد',
  };

  Widget _controls() {
    final agent = _agent!;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('الحالة: ${_phaseLabel(agent.phase)}   |   خطوات ${agent.steps}   |   مكالمات ${agent.calls}',
            style: const TextStyle(fontWeight: FontWeight.bold)),
        Wrap(spacing: 6, children: [
          TextButton.icon(onPressed: agent.canStart && !_starting ? _startTask : null, icon: const Icon(Icons.play_arrow), label: const Text('بدء')),
          TextButton(onPressed: agent.phase == TaskPhase.running ? () => agent.pause() : null, child: const Text('إيقاف مؤقت')),
          TextButton(onPressed: agent.phase == TaskPhase.running || agent.phase == TaskPhase.paused ? () { agent.takeManual(); setState(() => _tab = 1); } : null, child: const Text('تحكم يدوي')),
          TextButton(onPressed: agent.phase == TaskPhase.paused || agent.phase == TaskPhase.manual ? agent.resume : null, child: const Text('متابعة')),
          TextButton(onPressed: agent.isActive ? agent.cancel : null, child: const Text('إلغاء المهمة')),
        ]),
      ]),
    );
  }

  Widget _taskScreen() {
    final agent = _agent!;
    return ListView(padding: const EdgeInsets.all(16), children: [
      const Text('المهمة والمحادثة', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      TextField(controller: _task, enabled: !agent.isActive, minLines: 3, maxLines: 7, maxLength: 12000,
          decoration: const InputDecoration(border: OutlineInputBorder(), hintText: 'صف المهمة والنتيجة المطلوبة. لا تضع أسرارًا هنا.')),
      const SizedBox(height: 8),
      const Text('أضف المراجع من المكتبة، وافتح الموقع من المتصفح، وأدخل إعدادات API أولًا. ستراجع البيانات قبل إرسالها.'),
      const SizedBox(height: 12),
      Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('الخطة أو رد النموذج (غير متحقق)', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 6),
        SelectableText(agent.modelSummary.isEmpty ? 'لم يرد النموذج بعد.' : agent.modelSummary),
      ]))),
      if (agent.lastError.isNotEmpty) Text(agent.lastError, style: TextStyle(color: Theme.of(context).colorScheme.error)),
      const SizedBox(height: 6),
      Text('التكلفة المحتسبة تقريبًا: \$${agent.estimatedUsd.toStringAsFixed(5)}. قد تكون التكلفة الفعلية مختلفة.'),
      const SizedBox(height: 12),
      const Text('سجل الأفعال والنتائج', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
      if (agent.events.isEmpty) const Text('لا توجد خطوات بعد.'),
      ...agent.events.reversed.map((e) => ListTile(dense: true, title: Text(e.action), subtitle: Text(e.result),
          leading: Text('${e.time.hour.toString().padLeft(2, '0')}:${e.time.minute.toString().padLeft(2, '0')}'))),
      if (agent.phase == TaskPhase.completed && agent.successfulActions.isNotEmpty)
        OutlinedButton.icon(onPressed: _saveProcedure, icon: const Icon(Icons.bookmark_add_outlined), label: const Text('اعتماد تسلسل أدوات استرشادي بعد مراجعتي')),
      const Card(child: Padding(padding: EdgeInsets.all(12), child: Text(
        'غير متاح في هذا الإصدار: تشغيل الكود أو الاختبارات، الطرفية، تثبيت الحزم، GitHub داخل التطبيق وPDF. حفظ ملف لا يثبت أنه يعمل. توافق أي موقع أو هاتف لا يُفترض.',
      ))),
    ]);
  }

  Widget _browserScreen() {
    final locked = _agent!.phase == TaskPhase.running || _agent!.phase == TaskPhase.paused;
    return Column(children: [
      Padding(padding: const EdgeInsets.all(8), child: Row(children: [
        Expanded(child: TextField(controller: _address, enabled: !locked, keyboardType: TextInputType.url,
            textDirection: TextDirection.ltr, onSubmitted: (_) => _openAddress(),
            decoration: const InputDecoration(hintText: 'https://example.org', labelText: 'رابط HTTPS', border: OutlineInputBorder(), isDense: true))),
        const SizedBox(width: 6),
        FilledButton(onPressed: locked ? null : _openAddress, child: const Text('فتح')),
      ])),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: Text(locked
          ? 'المتصفح للعرض الآن؛ اختر «تحكم يدوي» للتفاعل.'
          : 'سجل الدخول وتحقق بنفسك. قد لا تسمح بعض المواقع بتسجيل الدخول في WebView.')),
      const SizedBox(height: 6),
      Expanded(child: AbsorbPointer(absorbing: locked, child: WebViewWidget(controller: _browser!.controller))),
    ]);
  }

  Widget _libraryScreen() {
    final store = _store!;
    return ListView(padding: const EdgeInsets.all(16), children: [
      const Text('الذاكرة والمراجع والنتائج', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
      const Text('تُحفظ محليًا في مساحة التطبيق دون تشفير تطبيقي إضافي. ليست تدريبًا للنموذج.'),
      const SizedBox(height: 12),
      Row(children: [const Expanded(child: Text('قواعد معتمدة', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
        TextButton.icon(onPressed: () => _editRule(), icon: const Icon(Icons.add), label: const Text('إضافة'))]),
      if (store.rules.isEmpty) const Text('لا توجد قواعد محفوظة.'),
      ...store.rules.map((rule) => ListTile(title: Text(rule.text), trailing: Wrap(children: [
        IconButton(tooltip: 'تعديل', onPressed: () => _editRule(rule), icon: const Icon(Icons.edit_outlined)),
        IconButton(tooltip: 'حذف', onPressed: () => _deleteRule(rule), icon: const Icon(Icons.delete_outline)),
      ]))),
      const Divider(),
      Row(children: [const Expanded(child: Text('المراجع النصية', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
        TextButton.icon(onPressed: _importReference, icon: const Icon(Icons.upload_file), label: const Text('استيراد'))]),
      const Text('حتى 64 كيلوبايت لكل ملف؛ البحث بالكلمات مع اسم الملف ورقم السطر، وPDF غير مدعوم.'),
      if (store.references.isEmpty) const Text('لا توجد مراجع محفوظة.'),
      ...store.references.map((ref) => ListTile(title: Text(ref.name), subtitle: Text('${ref.text.length} حرف'),
        onTap: () => showDialog<void>(context: context, builder: (dialogContext) => AlertDialog(
          title: Text(ref.name), content: SingleChildScrollView(child: SelectableText(ref.text)),
          actions: [TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('إغلاق'))],
        )),
        trailing: Wrap(children: [
          IconButton(tooltip: 'اعتماد مقتطف كقاعدة', onPressed: () => _adoptReference(ref), icon: const Icon(Icons.rule)),
          IconButton(tooltip: 'حذف', onPressed: () => _deleteReference(ref), icon: const Icon(Icons.delete_outline)),
        ]))),
      const Divider(),
      const Text('إجراءات استرشادية معتمدة', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
      const Text('تحتوي أسماء الأدوات فقط ولا تنفذ نفسها. استخدامها يضيف التسلسل إلى نص المهمة.'),
      if (store.procedures.isEmpty) const Text('لا توجد إجراءات محفوظة.'),
      ...store.procedures.asMap().entries.map((entry) => ListTile(
        title: Text('إجراء ${entry.key + 1} — ${entry.value.createdAt.toLocal().toString().split('.').first}'),
        subtitle: Text(entry.value.actions.join(' ← ')),
        trailing: Wrap(children: [
          TextButton(onPressed: _agent!.isActive ? null : () {
            _task.text = '${_task.text}\nتسلسل استرشادي سابق (لا تنفذه دون موافقات): ${entry.value.actions.join('، ')}';
            setState(() => _tab = 0);
          }, child: const Text('استخدام')),
          IconButton(tooltip: 'حذف', onPressed: () => _deleteProcedure(entry.key), icon: const Icon(Icons.delete_outline)),
        ]),
      )),
      const Divider(),
      Row(children: [const Expanded(child: Text('الملفات الناتجة', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
        IconButton(tooltip: 'تحديث', onPressed: () => setState(() => _outputFiles = store.listOutputs()), icon: const Icon(Icons.refresh))]),
      const Text('في تخزين التطبيق الخاص؛ استخدم مشاركة لتصديرها. لا تُشغّل الملفات تلقائيًا.'),
      FutureBuilder<List<File>>(future: _outputFiles, builder: (context, snapshot) {
        if (!snapshot.hasData) return const Text('جارٍ قراءة الملفات...');
        final files = snapshot.data!;
        if (files.isEmpty) return const Text('لا توجد ملفات ناتجة.');
        return Column(children: files.map((file) => ListTile(
          title: Text(p.relative(file.path, from: store.outputDirectory.path)),
          trailing: IconButton(tooltip: 'تصدير', onPressed: () => _shareFile(file), icon: const Icon(Icons.share_outlined)),
        )).toList());
      }),
    ]);
  }

  Widget _settingsScreen() {
    final locked = _agent!.isActive;
    InputDecoration decoration(String label, [String? hint]) => InputDecoration(labelText: label, hintText: hint, border: const OutlineInputBorder());
    Widget numberField(TextEditingController c, String label) => Padding(padding: const EdgeInsets.only(bottom: 8), child: TextField(
      controller: c, enabled: !locked, keyboardType: const TextInputType.numberWithOptions(decimal: true),
      textDirection: TextDirection.ltr, decoration: decoration(label)));
    return ListView(padding: const EdgeInsets.all(16), children: [
      const Text('الإعدادات والصلاحيات', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
      const Text('يتطلب مزودًا متوافقًا مع Chat Completions وtools؛ اشتراك موقع المحادثة لا يعني توفر API.'),
      const SizedBox(height: 10),
      TextField(controller: _endpoint, enabled: !locked, keyboardType: TextInputType.url, textDirection: TextDirection.ltr,
          decoration: decoration('رابط API الكامل', 'https://api.example.com/v1/chat/completions')),
      const SizedBox(height: 8),
      TextField(controller: _model, enabled: !locked, textDirection: TextDirection.ltr, decoration: decoration('اسم النموذج لدى المزود')),
      const SizedBox(height: 8),
      TextField(controller: _apiKey, enabled: !locked, obscureText: true, autocorrect: false, enableSuggestions: false,
          keyboardType: TextInputType.visiblePassword, textDirection: TextDirection.ltr, decoration: decoration('مفتاح API — في الذاكرة فقط')),
      Align(alignment: Alignment.centerRight, child: TextButton(onPressed: locked ? null : _apiKey.clear, child: const Text('مسح المفتاح من الحقل'))),
      const Text('لا يُحفظ المفتاح في المستودع أو التخزين المحلي. لا تضعه في عنوان URL أو في المهمة أو المراجع.'),
      const Divider(height: 28),
      const Text('حدود المهمة', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
      const Text('يشمل الوقت فترات التوقف والتحكم اليدوي. لا توجد إعادة تلقائية لطلبات API الفاشلة.'),
      const SizedBox(height: 8),
      numberField(_maxSteps, 'الحد الأقصى للخطوات (1–100)'),
      numberField(_maxCalls, 'الحد الأقصى لمكالمات API (1–30)'),
      numberField(_maxFailures, 'الحد الأقصى لأخطاء الأدوات (1–10)'),
      numberField(_minutes, 'المدة بالدقائق (1–120)'),
      numberField(_budget, 'حد التكلفة التقديري بالدولار (فارغ لتعطيله)'),
      numberField(_inputRate, 'سعر مليون رمز إدخال بالدولار'),
      numberField(_outputRate, 'سعر مليون رمز إخراج بالدولار'),
      const Text('أدخل أسعار مزودك الفعلية لتفعيل الحد. التقدير غير مضمون وقد تتجاوز الفاتورة الحد؛ اضبط حدًا مستقلًا لدى المزود. إذا غاب تقرير الرموز تتوقف المهمة.'),
      const Divider(height: 28),
      const Text('قواعد الموافقة الدائمة', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
      const Text('الافتراضي طلب الموافقة. القواعد الدائمة متاحة لإعادة التوجيه بين النطاقات فقط؛ جميع أدوات الوكيل، بما فيها الانتقال، تحتاج موافقة لكل مرة.'),
      if (_permissions!.persistent.isEmpty) const Text('لا توجد قواعد سماح دائمة.'),
      ..._permissions!.persistent.map((key) => ListTile(title: Text(key.replaceFirst('|', ' — ')),
        trailing: IconButton(tooltip: 'إلغاء القاعدة', icon: const Icon(Icons.delete_outline), onPressed: () async {
          try {
            await _permissions!.revoke(key);
            if (mounted) setState(() {});
          } catch (e) { _message(_error(e)); }
        }))),
      const SizedBox(height: 12),
      const Text('حظر HTTP والعناوين المحلية ليس عزل شبكة كاملًا. قد ترسل المواقع موارد أو طلبات إلى جهات أخرى. لا توجد وسيلة لتجاوز CAPTCHA.'),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return Scaffold(appBar: AppBar(title: const Text('OK AI')), body: Center(child: _initializationError == null
          ? const CircularProgressIndicator() : Padding(padding: const EdgeInsets.all(24), child: Text(_initializationError!))));
    }
    return Scaffold(
      appBar: AppBar(title: const Text('OK AI — وكيل تحت إشرافك')),
      body: Column(children: [
        _controls(),
        Expanded(child: IndexedStack(index: _tab, children: [_taskScreen(), _browserScreen(), _libraryScreen(), _settingsScreen()])),
      ]),
      bottomNavigationBar: NavigationBar(selectedIndex: _tab, onDestinationSelected: (value) => setState(() => _tab = value), destinations: const [
        NavigationDestination(icon: Icon(Icons.assignment_outlined), label: 'المهمة'),
        NavigationDestination(icon: Icon(Icons.language), label: 'المتصفح'),
        NavigationDestination(icon: Icon(Icons.folder_outlined), label: 'المكتبة'),
        NavigationDestination(icon: Icon(Icons.settings_outlined), label: 'الإعدادات'),
      ]),
    );
  }

  @override
  void dispose() {
    _agent?.removeListener(_onAgentChange);
    _agent?.dispose();
    for (final controller in [_task, _address, _endpoint, _model, _apiKey, _maxSteps, _maxCalls, _maxFailures, _minutes, _budget, _inputRate, _outputRate]) {
      controller.dispose();
    }
    super.dispose();
  }
}
