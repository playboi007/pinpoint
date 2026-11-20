import '../core/hook_registry.dart';
import 'console_filter.dart';

/// No console outside a browser: nothing is replaced.
ConsoleFilter createConsoleFilter(HookRegistry hooks) => const _NoConsole();

class _NoConsole implements ConsoleFilter {
  const _NoConsole();

  @override
  bool get available => false;

  @override
  bool get active => false;

  @override
  int get dropped => 0;

  @override
  void install() {}

  @override
  void restore() {}
}
