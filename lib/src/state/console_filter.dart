import '../core/hook_registry.dart';
import 'console_filter_stub.dart'
    if (dart.library.js_interop) 'console_filter_web.dart'
    as platform;

/// Keeps the browser console free of the `scheduleBuildFor` lines while the
/// state lens is armed (PLAN-v3 Milestone 21, web).
///
/// On web, Flutter writes the label and the stack of each `scheduleBuildFor`
/// call to `console.error` before any listener sees them
/// (`foundation/_error_dumper_web.dart`). `BuildStacks` reads them through
/// the dump listener, but the console would still fill with red. Armed, this
/// replaces `console.error` with a filter that drops those lines and
/// forwards every other call, with all its arguments. [restore] puts the
/// original back. Outside a browser there is no console: every call does
/// nothing.
abstract interface class ConsoleFilter {
  /// Whether there is a console to filter (web).
  bool get available;

  /// Whether `console.error` is replaced now.
  bool get active;

  /// Lines dropped since [install].
  int get dropped;

  /// Replaces `console.error`. Does nothing when it is replaced already.
  void install();

  /// Puts the original back. Safe to call when nothing is installed, and
  /// again. When another script replaced `console.error` after us, it is
  /// theirs and is left alone.
  void restore();
}

/// The console filter of this platform. The slot goes through [hooks], so
/// it comes back when the registry is disposed.
ConsoleFilter createConsoleFilter(HookRegistry hooks) =>
    platform.createConsoleFilter(hooks);

/// The decision of the filter, as plain text work, so the VM tests it too.
///
/// Dropped: a message that starts with `scheduleBuildFor() called for` or
/// `BuildOwner.scheduleBuildFor() called;`, the single message right after
/// it when it looks like a stack, and a message that starts with
/// `...the build scope's dirty list`. Everything else is forwarded.
class ConsoleLineFilter {
  static const String labelPrefix = 'scheduleBuildFor() called for';
  static const String resortPrefix = 'BuildOwner.scheduleBuildFor() called;';
  static const String dirtyListPrefix = "...the build scope's dirty list";

  bool _expectStack = false;

  /// Lines dropped so far.
  int dropped = 0;

  /// Whether the call whose first argument is [message] is dropped.
  bool shouldDrop(String message) {
    if (_expectStack) {
      _expectStack = false;
      if (!_isLabel(message) && looksLikeStack(message)) {
        dropped++;
        return true;
      }
    }
    if (_isLabel(message)) {
      _expectStack = true;
      dropped++;
      return true;
    }
    if (message.startsWith(dirtyListPrefix)) {
      dropped++;
      return true;
    }
    return false;
  }

  /// Forgets a stack that was expected.
  void reset() {
    _expectStack = false;
    dropped = 0;
  }

  static bool _isLabel(String message) =>
      message.startsWith(labelPrefix) || message.startsWith(resortPrefix);

  static final RegExp _stackStart = RegExp(
    r'^\s*(#\d+\s|\(elided |at |.*\.dart)',
  );

  /// Whether [message] is the text of a stack, in the VM format (`#0  Foo`)
  /// or the web formats (`packages/foo/bar.dart 12:3  baz`).
  static bool looksLikeStack(String message) => _stackStart.hasMatch(message);
}
