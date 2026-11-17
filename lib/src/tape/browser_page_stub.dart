import 'browser_page.dart';

/// No page outside a browser.
BrowserPage createBrowserPage() => const _NoPage();

class _NoPage implements BrowserPage {
  const _NoPage();

  @override
  bool get available => false;

  @override
  String get url => '';

  @override
  Map<String, Map<String, String>> readStorage() =>
      const <String, Map<String, String>>{};

  @override
  void writeStorage(Map<String, Map<String, String>> storage) {}

  @override
  String? sessionGet(String key) => null;

  @override
  void sessionSet(String key, String value) {}

  @override
  void sessionRemove(String key) {}

  @override
  void reload() {}

  @override
  void postMessage(String data, String origin) {}
}
