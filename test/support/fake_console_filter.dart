import 'package:pinpoint/src/state/console_filter.dart';

/// A console that is not there: counts what the lens asks of it.
class FakeConsoleFilter implements ConsoleFilter {
  int installs = 0;
  int restores = 0;
  bool _active = false;

  @override
  bool get available => true;

  @override
  bool get active => _active;

  @override
  int get dropped => 0;

  @override
  void install() {
    installs++;
    _active = true;
  }

  @override
  void restore() {
    restores++;
    _active = false;
  }
}
