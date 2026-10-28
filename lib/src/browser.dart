import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'policy.dart';

class BrowserSnapshot {
  const BrowserSnapshot({required this.url, required this.title, required this.text, required this.elements, required this.revision});
  final String url;
  final String title;
  final String text;
  final List<Object?> elements;
  final int revision;
  String toSharedText() => jsonEncode({'url': url, 'title': title, 'visible_text': text, 'elements': elements});
}

abstract class BrowserPort {
  int get revision;
  Future<String?> currentUrl();
  Future<bool> needsIntervention();
  Future<BrowserSnapshot> readPage();
  Future<void> navigate(Uri url);
  Future<void> click(String selector, String expectedUrl, int expectedRevision);
  Future<void> typeText(String selector, String text, String expectedUrl, int expectedRevision);
}

/// The scripts are fixed by the application, not supplied by the model.
/// Dynamic values are JSON-encoded so they cannot become JavaScript source.
class BrowserScripts {
  static String _jsValue(String value) => jsonEncode(value)
      .replaceAll('\u2028', r'\u2028')
      .replaceAll('\u2029', r'\u2029');

  static const _challengeFunction = r'''
    function humanCheck() {
      const selectors = [
        'input[type="password"]', 'input[autocomplete="one-time-code"]',
        'input[name*="otp" i]', 'input[name*="verification" i]',
        'iframe[src*="recaptcha" i]', 'iframe[src*="hcaptcha" i]',
        '[id*="captcha" i]', '[class*="captcha" i]'
      ];
      return Array.from(document.querySelectorAll(selectors.join(','))).some(function(e) {
        const s = getComputedStyle(e);
        return e.getClientRects().length > 0 && s.visibility !== 'hidden' && s.display !== 'none';
      });
    }
  ''';

  static const challenge = '''
    (() => { $_challengeFunction return JSON.stringify({human: humanCheck()}); })()
  ''';

  static const read = r'''
    (() => {
      function visible(e) {
        const s = getComputedStyle(e);
        return e.getClientRects().length > 0 && s.visibility !== 'hidden' && s.display !== 'none';
      }
      function path(e) {
        if (e.id && window.CSS && CSS.escape) {
          const id = '#' + CSS.escape(e.id);
          try { if (document.querySelectorAll(id).length === 1) return id; } catch (_) {}
        }
        const parts = [];
        while (e && e.nodeType === 1 && parts.length < 8) {
          let n = 1, p = e;
          while ((p = p.previousElementSibling)) if (p.tagName === e.tagName) n++;
          parts.unshift(e.tagName.toLowerCase() + ':nth-of-type(' + n + ')');
          e = e.parentElement;
        }
        return parts.join(' > ');
      }
      const found = Array.from(document.querySelectorAll(
        'a,button,input,textarea,[contenteditable="true"],[role="button"]'
      )).filter(visible).slice(0, 40).map(e => ({
        selector: path(e).slice(0, 256),
        tag: e.tagName.toLowerCase(),
        type: (e.getAttribute('type') || '').slice(0, 40),
        label: (e.innerText || e.getAttribute('aria-label') || e.getAttribute('placeholder') || '').slice(0, 120)
      }));
      return JSON.stringify({url: location.href, title: document.title.slice(0, 300),
        text: (document.body ? document.body.innerText : '').slice(0, 6000), elements: found});
    })()
  ''';

  static String click(String selector, String expectedUrl) => '''
    (() => {
      $_challengeFunction
      const selector = ${_jsValue(selector)};
      const expected = ${_jsValue(expectedUrl)};
      if (location.href !== expected) return JSON.stringify({ok:false, error:'تغير رابط الصفحة.'});
      if (humanCheck()) return JSON.stringify({ok:false, error:'يلزم تدخل يدوي للتحقق.'});
      let e;
      try { e = document.querySelector(selector); } catch (_) { return JSON.stringify({ok:false, error:'محدد غير صالح.'}); }
      if (!e) return JSON.stringify({ok:false, error:'العنصر غير موجود.'});
      const s = getComputedStyle(e);
      if (!e.getClientRects().length || s.visibility === 'hidden' || s.display === 'none' || e.disabled)
        return JSON.stringify({ok:false, error:'العنصر غير ظاهر أو معطل.'});
      if (e.tagName === 'INPUT' && ['password','file','hidden'].includes((e.type || '').toLowerCase()))
        return JSON.stringify({ok:false, error:'عنصر حساس محظور.'});
      e.click();
      return JSON.stringify({ok:true});
    })()
  ''';

  static String typeText(String selector, String text, String expectedUrl) => '''
    (() => {
      $_challengeFunction
      const selector = ${_jsValue(selector)};
      const text = ${_jsValue(text)};
      const expected = ${_jsValue(expectedUrl)};
      if (location.href !== expected) return JSON.stringify({ok:false, error:'تغير رابط الصفحة.'});
      if (humanCheck()) return JSON.stringify({ok:false, error:'يلزم تدخل يدوي للتحقق.'});
      let e;
      try { e = document.querySelector(selector); } catch (_) { return JSON.stringify({ok:false, error:'محدد غير صالح.'}); }
      if (!e) return JSON.stringify({ok:false, error:'العنصر غير موجود.'});
      const s = getComputedStyle(e);
      if (!e.getClientRects().length || s.visibility === 'hidden' || s.display === 'none' || e.disabled || e.readOnly)
        return JSON.stringify({ok:false, error:'العنصر غير ظاهر أو معطل.'});
      const kind = (e.type || '').toLowerCase();
      const hints = ['name','id','autocomplete','placeholder','aria-label'].map(k => e.getAttribute(k) || '').join(' ').toLowerCase();
      if (['password','file','hidden','submit','button','reset','checkbox','radio','image'].includes(kind) ||
          /password|passwd|secret|token|one-time|otp|verification|2fa|cvv|cvc|credit.?card/.test(hints))
        return JSON.stringify({ok:false, error:'لا تُملأ حقول الدخول أو التحقق أو الدفع آليًا.'});
      if (e.tagName === 'INPUT' || e.tagName === 'TEXTAREA') {
        const proto = e.tagName === 'INPUT' ? HTMLInputElement.prototype : HTMLTextAreaElement.prototype;
        const setter = Object.getOwnPropertyDescriptor(proto, 'value').set;
        setter.call(e, text);
      } else if (e.isContentEditable) { e.textContent = text; }
      else { return JSON.stringify({ok:false, error:'العنصر ليس حقل كتابة مدعومًا.'}); }
      e.dispatchEvent(new Event('input', {bubbles:true}));
      e.dispatchEvent(new Event('change', {bubbles:true}));
      return JSON.stringify({ok:true});
    })()
  ''';
}

class WebViewBrowser implements BrowserPort {
  WebViewBrowser() : controller = WebViewController();
  final WebViewController controller;
  Future<bool> Function(Uri target)? onCrossOrigin;
  void Function()? onIntervention;
  String? _currentOrigin;
  final Set<String> _explicitNext = {};
  int _revision = 0;
  @override
  int get revision => _revision;

  Future<void> initialize() async {
    await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
    await controller.setBackgroundColor(Colors.white);
    await controller.setNavigationDelegate(NavigationDelegate(
      onNavigationRequest: (request) async {
        try {
          final uri = InputPolicy.httpsUrl(request.url);
          if (!request.isMainFrame) return NavigationDecision.navigate;
          final origin = InputPolicy.origin(uri);
          if (origin == _currentOrigin || _explicitNext.remove(origin)) {
            return NavigationDecision.navigate;
          }
          final allow = await onCrossOrigin?.call(uri) ?? false;
          return allow ? NavigationDecision.navigate : NavigationDecision.prevent;
        } catch (_) {
          return NavigationDecision.prevent;
        }
      },
      onPageStarted: (url) {
        _revision++;
        try {
          _currentOrigin = InputPolicy.origin(InputPolicy.httpsUrl(url));
        } catch (_) {
          _currentOrigin = null;
        }
      },
      onPageFinished: (_) async {
        _revision++;
        try {
          if (await needsIntervention()) onIntervention?.call();
        } catch (_) {
          // A page may disappear while the check is in progress.
        }
      },
    ));
  }

  @override
  Future<String?> currentUrl() => controller.currentUrl();

  @override
  Future<void> navigate(Uri url) async {
    final safe = InputPolicy.httpsUrl(url.toString());
    _explicitNext.add(InputPolicy.origin(safe));
    try {
      await controller.loadRequest(safe);
    } catch (_) {
      _explicitNext.remove(InputPolicy.origin(safe));
      rethrow;
    }
  }

  Future<Map<String, dynamic>> _evaluate(String script) async {
    final result = await controller.runJavaScriptReturningResult(script);
    dynamic decoded = result;
    for (var i = 0; i < 2 && decoded is String; i++) {
      decoded = jsonDecode(decoded);
    }
    if (decoded is! Map<String, dynamic>) throw const PolicyException('تعذرت قراءة نتيجة الصفحة.');
    return decoded;
  }

  @override
  Future<bool> needsIntervention() async {
    final value = await _evaluate(BrowserScripts.challenge);
    return value['human'] == true;
  }

  @override
  Future<BrowserSnapshot> readPage() async {
    final before = revision;
    final raw = await _evaluate(BrowserScripts.read);
    if (before != revision || raw['url'] is! String || raw['title'] is! String ||
        raw['text'] is! String || raw['elements'] is! List) {
      throw const PolicyException('تغيرت الصفحة أثناء قراءتها؛ أعد القراءة.');
    }
    final url = raw['url'] as String;
    InputPolicy.httpsUrl(url);
    return BrowserSnapshot(
      url: url,
      title: raw['title'] as String,
      text: raw['text'] as String,
      elements: List<Object?>.from(raw['elements'] as List),
      revision: before,
    );
  }

  Future<void> _execute(String script, int expectedRevision) async {
    if (revision != expectedRevision) throw const PolicyException('تغيرت الصفحة؛ يلزم قراءة جديدة.');
    final raw = await _evaluate(script);
    if (raw['ok'] != true) throw PolicyException(raw['error'] is String ? raw['error'] as String : 'تعذر تنفيذ إجراء الصفحة.');
  }

  @override
  Future<void> click(String selector, String expectedUrl, int expectedRevision) =>
      _execute(BrowserScripts.click(InputPolicy.selector(selector), expectedUrl), expectedRevision);

  @override
  Future<void> typeText(String selector, String text, String expectedUrl, int expectedRevision) =>
      _execute(BrowserScripts.typeText(InputPolicy.selector(selector), text, expectedUrl), expectedRevision);
}
