import 'package:pinpoint/src/tape/browser_page.dart';

/// A browser page in memory, for the restart of a replay in widget tests.
class FakePage implements BrowserPage {
  FakePage({Map<String, Map<String, String>>? storage})
    : storage =
          storage ??
          {'local': <String, String>{}, 'session': <String, String>{}};

  final Map<String, Map<String, String>> storage;
  int reloads = 0;
  final List<(String, String)> messages = <(String, String)>[];

  Map<String, String> get _session => storage['session']!;

  @override
  bool get available => true;

  @override
  String get url => 'http://localhost:8080/#/';

  @override
  Map<String, Map<String, String>> readStorage() => {
    for (final MapEntry(:key, :value) in storage.entries)
      key: {
        for (final e in value.entries)
          if (!e.key.startsWith('pinpoint.')) e.key: e.value,
      },
  };

  @override
  void writeStorage(Map<String, Map<String, String>> values) {
    for (final MapEntry(:key, :value) in values.entries) {
      final target = storage[key] ??= <String, String>{};
      target.removeWhere((k, _) => !k.startsWith('pinpoint.'));
      target.addAll(value);
    }
  }

  @override
  String? sessionGet(String key) => _session[key];

  @override
  void sessionSet(String key, String value) => _session[key] = value;

  @override
  void sessionRemove(String key) => _session.remove(key);

  @override
  void reload() => reloads++;

  @override
  void postMessage(String data, String origin) => messages.add((data, origin));
}
