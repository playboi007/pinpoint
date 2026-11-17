import 'browser_page_stub.dart'
    if (dart.library.js_interop) 'browser_page_web.dart'
    as platform;

/// What a tape needs from the page it runs in (PLAN-v2 Milestone 15): its
/// URL, its storage, a reload, and a way to send a `message` event. Outside
/// a browser there is no page: every read is empty and every write does
/// nothing.
///
/// Storage can be missing or throw (private mode, blocked site data), so
/// every call is guarded.
abstract interface class BrowserPage {
  /// Whether there is a page (web).
  bool get available;

  /// `location.href`, or empty.
  String get url;

  /// `local` and `session`: every key and value of `localStorage` and
  /// `sessionStorage`. Keys that start with `pinpoint.` are Pinpoint's own
  /// and left out.
  Map<String, Map<String, String>> readStorage();

  /// Replaces both storages with [storage], keeping Pinpoint's own keys.
  void writeStorage(Map<String, Map<String, String>> storage);

  /// `sessionStorage.getItem`, `setItem` and `removeItem`.
  String? sessionGet(String key);
  void sessionSet(String key, String value);
  void sessionRemove(String key);

  /// `location.reload()`.
  void reload();

  /// Sends a `message` event to `window` with [data] (JSON text, or text)
  /// and [origin]. An event made in script has no `source` window: an app
  /// that answers to `event.source` fails there (watch out for).
  void postMessage(String data, String origin);
}

/// The page of this platform.
BrowserPage browserPage() => platform.createBrowserPage();
