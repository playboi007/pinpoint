import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/core/hook_registry.dart';
import 'package:pinpoint/src/state/console_filter.dart';

/// PLAN-v3 Milestone 21, web item A: keep the `scheduleBuildFor` lines out
/// of the browser console while the lens is armed. The decision is plain
/// text work and runs here; the real `console.error` is checked in Chrome
/// (`test/state/web`).
void main() {
  group('ConsoleLineFilter', () {
    late ConsoleLineFilter filter;
    setUp(() => filter = ConsoleLineFilter());

    const label = 'scheduleBuildFor() called for Foo(dirty)';
    const resort =
        'BuildOwner.scheduleBuildFor() called; _dirtyElementsNeedsResorting was false';
    const vmStack =
        '#0      debugPrintStack (package:flutter/src/a.dart:1:2)\n#1  Foo.go';
    const webStack =
        'packages/flutter/src/widgets/framework.dart 5307:7  markNeedsBuild';
    const dirtyList = "...the build scope's dirty list is now: [Foo]";

    test('drops the label, the stack after it and the dirty list line', () {
      expect(filter.shouldDrop(label), isTrue);
      expect(filter.shouldDrop(webStack), isTrue);
      expect(filter.shouldDrop(dirtyList), isTrue);
      expect(filter.dropped, 3);
    });

    test('drops the already-listed label and its stack too', () {
      expect(filter.shouldDrop(resort), isTrue);
      expect(filter.shouldDrop(vmStack), isTrue);
      expect(filter.dropped, 2);
    });

    test('forwards everything else', () {
      expect(filter.shouldDrop('Unhandled Exception: boom'), isFalse);
      expect(filter.shouldDrop(''), isFalse);
      expect(filter.shouldDrop(webStack), isFalse, reason: 'no label before');
      expect(filter.shouldDrop('scheduleBuildFor() was mentioned'), isFalse);
      expect(filter.dropped, 0);
    });

    test('only the single message after a label is the stack', () {
      expect(filter.shouldDrop(label), isTrue);
      expect(filter.shouldDrop(webStack), isTrue);
      // A second stack-looking line is not part of it.
      expect(filter.shouldDrop(webStack), isFalse);
    });

    test('a label with no stack after it does not eat the next message', () {
      expect(filter.shouldDrop(label), isTrue);
      expect(filter.shouldDrop('Unhandled Exception: boom'), isFalse);
      expect(filter.shouldDrop(webStack), isFalse);
    });

    test('two labels in a row: the second is a label, not a stack', () {
      expect(filter.shouldDrop(label), isTrue);
      expect(filter.shouldDrop(label), isTrue);
      expect(filter.shouldDrop(webStack), isTrue);
    });

    test('reset forgets an expected stack and the count', () {
      filter.shouldDrop(label);
      filter.reset();
      expect(filter.shouldDrop(webStack), isFalse);
      expect(filter.dropped, 0);
    });
  });

  test('outside a browser there is no console to filter', () {
    final hooks = HookRegistry();
    final filter = createConsoleFilter(hooks);
    expect(filter.available, isFalse);
    filter
      ..install()
      ..restore();
    expect(filter.active, isFalse);
    expect(filter.dropped, 0);
    hooks.dispose();
  });
}
