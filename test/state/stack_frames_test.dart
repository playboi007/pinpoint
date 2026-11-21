import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/model/source_location.dart';
import 'package:pinpoint/src/state/stack_frames.dart';

/// The first project frame of a stack (PLAN-v3 Milestone 21, steps 2 and 3).
void main() {
  const rooted = SourcePaths(projectRoot: '/work/app');
  const unrooted = SourcePaths();

  ProjectFrame? first(String stack, [SourcePaths paths = rooted]) =>
      firstProjectFrameIn(stack, paths);

  test('Dart, framework, test and state packages are skipped; the first '
      'app package frame is the answer', () {
    final frame = first('''
#0      ChangeNotifier.notifyListeners (package:flutter/src/foundation/change_notifier.dart:437:24)
#1      ChangeNotifier.notifyListeners (package:listen/src/listen.dart:447:24)
#2      ProductDetailProvider.fetchDialog (package:shop/product_detail_provider.dart:88:5)
#3      _InkResponseState.handleTap (package:flutter/src/material/ink_well.dart:1:1)
''');
    expect(frame!.file, 'package:shop/product_detail_provider.dart');
    expect(frame.line, 88);
    expect(frame.column, 5);
    expect(frame.method, 'ProductDetailProvider.fetchDialog');
    expect(frame.where, 'package:shop/product_detail_provider.dart:88:5');
  });

  test('a file frame under the root is relative; one outside is skipped', () {
    final frame = first('''
#0      Foo.bar (file:///elsewhere/lib/foo.dart:3:3)
#1      Baz.qux.<anonymous closure> (file:///work/app/lib/ui/baz.dart:12:9)
''');
    expect(frame!.file, 'lib/ui/baz.dart');
    expect(frame.line, 12);
    // `.<anonymous closure>` goes, as in Flutter's StackFrame.
    expect(frame.method, 'Baz.qux');
  });

  test('SDK paths are not the project, root or not', () {
    expect(
      first(
        '#0      Foo.bar (file:///sdk/packages/flutter/lib/src/a.dart:3:3)',
        unrooted,
      ),
      isNull,
    );
    expect(
      first('#0      main (file:///any/test/a_test.dart:3:3)', unrooted)!.file,
      '/any/test/a_test.dart',
    );
  });

  test('provider, pinpoint and flutter_test frames are skipped', () {
    expect(
      first('''
#0      ListenableProvider._startListening (package:provider/src/listenable_provider.dart:1:1)
#1      PinPointWrapper.build (package:pinpoint/src/core/wrapper.dart:1:1)
#2      testWidgets.<anonymous closure> (package:flutter_test/src/widget_tester.dart:192:15)
<asynchronous suspension>
(elided one frame from package:stack_trace)
'''),
      isNull,
    );
  });

  test('the web (DDC) format: package frames, a bare test file name, the '
      'dart-sdk and the compiled URLs skipped', () {
    // As Chrome printed them (api-notes item 34).
    final frame = first('''
http://localhost:54803/dart-sdk/lib/_internal/js_dev_runtime/private/ddc_runtime/errors.dart 274:3   throw_
package:flutter/src/widgets/framework.dart 5307:7   markNeedsBuild
package:pinpoint/src/state/listen.dart 12:3   _notified
package:shop/providers/product_detail_provider.dart 88:5   fetchDialog
package:shop/screens/detail.dart 40:9   build
''');
    expect(frame!.file, 'package:shop/providers/product_detail_provider.dart');
    expect(frame.line, 88);
    expect(frame.column, 5);
    expect(frame.method, 'fetchDialog');

    // A test file: `flutter test --platform chrome` prints its name only.
    expect(
      first('''
package:flutter/src/widgets/framework.dart 5307:7   markNeedsBuild
state_web_test.dart 197:5                           toggle
''', unrooted)!.file,
      'state_web_test.dart',
    );
    // The module URL of a package is the package's frame.
    expect(
      first('http://localhost:1/packages/shop/a.dart 7:2   go', unrooted)!.file,
      'package:shop/a.dart',
    );
    final files = ProjectFiles([
      'org-dartlang-app:///test/state/web/state_web_test.dart',
    ], unrooted);
    expect(
      firstProjectFrameIn(
        'state_web_test.dart.js 216:12   toggle',
        unrooted,
        files: files,
      )!.file,
      endsWith('/state_web_test.dart'),
    );
    // No debug info (wasm, profile): no file, so no project frame.
    expect(
      first('''
    at ProductDetailProvider.fetchDialog (wasm://wasm/abc:1:2)
    at foo.bar (http://localhost:1/main.dart.js:149790:13)
''', unrooted),
      isNull,
    );
  });

  test('the wasm format: a closure has its place, a method has none', () {
    // As Chrome printed them with `--wasm` (api-notes item 34).
    final frame = first('''
    at M.BuildOwner.scheduleBuildFor closure at file:///sdk/packages/flutter/lib/src/widgets/framework.dart:2952:12 (http://localhost:1/main.dart.wasm:wasm-function[1]:0x2)
    at M._SpinnerState.toggle (http://localhost:1/main.dart.wasm:wasm-function[2]:0x3)
    at M.main closure at org-dartlang-app:///state/web/state_web_test.dart:120:62 inner (http://localhost:1/main.dart.wasm:wasm-function[3]:0x4)
    at M._awaitHelper closure at org-dartlang-sdk:///dart-sdk/lib/_internal/wasm/common/async_patch.dart:95:5 (http://localhost:1/main.dart.wasm:wasm-function[4]:0x5)
''');
    expect(frame!.file, 'state/web/state_web_test.dart');
    expect(frame.line, 120);
    expect(frame.column, 62);
    expect(frame.method, 'main');

    expect(
      first(
        '    at M.Foo.go closure at package:shop/a.dart:7:2 (http://x:wasm-function[1]:0x2)',
      )!.file,
      'package:shop/a.dart',
    );
  });

  test('lines that are not frames never throw', () {
    expect(first(''), isNull);
    expect(first('not a stack at all\n\n<asynchronous suspension>'), isNull);
    expect(first('(elided 3 frames from dart:async)'), isNull);
  });

  test('the length is capped', () {
    final stack = [
      for (var i = 0; i < 300; i++)
        '#$i      f$i (package:flutter/src/a.dart:1:1)',
      '#300      app (package:shop/a.dart:1:1)',
    ].join('\n');
    expect(first(stack), isNull);
    expect(firstProjectFrameIn(stack, rooted, maxLines: 400), isNotNull);
  });

  test('a hint makes a package local even in the skip list', () {
    const hinted = SourcePaths(localPathHints: ['package:provider']);
    expect(
      firstProjectFrameIn(
        '#0      Foo.bar (package:provider/src/a.dart:1:1)',
        hinted,
      ),
      isNotNull,
    );
  });

  group('a real app in Chrome (api-notes item 34)', () {
    // `flutter run -d chrome`: the engine and the framework print `lib/...`
    // and `packages/...` paths; they must never be the project's.
    const engine =
        'lib/_engine/engine/platform_dispatcher.dart 1733:5   invoke';
    const scrollbar =
        'packages/flutter/src/material/scrollbar.dart 429:5   handleHoverExit';
    const framework =
        'packages/flutter/src/widgets/framework.dart 5307:7   markNeedsBuild';
    const app =
        'package:genai_product/src/features/x/y.dart 88:5   fetchDialog';
    final files = ProjectFiles([
      'file:///work/app/lib/src/features/x/y.dart',
      'file:///work/app/lib/src/features/x/z.dart',
    ], rooted);

    test('engine and framework frames alone are not the project, with files '
        'known or not', () {
      final stack = [engine, scrollbar, framework].join('\n');
      expect(firstProjectFrameIn(stack, rooted, files: files), isNull);
      expect(firstProjectFrameIn(stack, rooted), isNull);
      expect(
        firstProjectFrameIn(
          'lib/_engine/engine/platform_dispatcher.dart 1748:5   invoke1',
          unrooted,
        ),
        isNull,
      );
    });

    test('the app frame is the answer; with files it is shown as the project '
        'path the bridge can open', () {
      final stack = [engine, scrollbar, framework, app].join('\n');
      final known = firstProjectFrameIn(stack, rooted, files: files)!;
      expect(known.file, 'lib/src/features/x/y.dart');
      expect(known.line, 88);
      expect(known.column, 5);
      expect(known.method, 'fetchDialog');
      // The same frame with no file set: the package URI, as before.
      final fallback = firstProjectFrameIn(stack, rooted)!;
      expect(fallback.file, 'package:genai_product/src/features/x/y.dart');
      expect(fallback.method, 'fetchDialog');
    });

    test('every name DDC and the VM give a file finds the same file', () {
      for (final line in [
        'packages/genai_product/src/features/x/y.dart 88:5   fetchDialog',
        'http://localhost:5000/packages/genai_product/src/features/x/y.dart 88:5   fetchDialog',
        'lib/src/features/x/y.dart 88:5   fetchDialog',
        'org-dartlang-app:///lib/src/features/x/y.dart 88:5   fetchDialog',
        'file:///work/app/lib/src/features/x/y.dart 88:5   fetchDialog',
        '#0      Foo.fetchDialog (package:genai_product/src/features/x/y.dart:88:5)',
        '#0      Foo.fetchDialog (file:///work/app/lib/src/features/x/y.dart:88:5)',
      ]) {
        expect(
          firstProjectFrameIn(line, rooted, files: files)?.file,
          'lib/src/features/x/y.dart',
          reason: line,
        );
      }
    });

    test('a file of the app that no widget names: its package was seen in the '
        'stack, so it counts', () {
      final stack = [
        'package:genai_product/src/domain/cart_model.dart 10:3   add',
        app,
      ].join('\n');
      final frame = firstProjectFrameIn(stack, rooted, files: files)!;
      expect(frame.file, 'package:genai_product/src/domain/cart_model.dart');
      expect(frame.method, 'add');
      // Another package in front is not the app's.
      final other = firstProjectFrameIn(
        ['package:go_router/src/route.dart 4:1   go', app].join('\n'),
        rooted,
        files: files,
      )!;
      expect(other.method, 'fetchDialog');
    });

    test(
      'with files known, a frame that is none of them is not the project',
      () {
        expect(
          firstProjectFrameIn(
            'package:go_router/src/route.dart 4:1   go',
            rooted,
            files: files,
          ),
          isNull,
        );
        expect(
          firstProjectFrameIn(
            'lib/src/scrollbar.dart 429:5   handleHoverExit',
            rooted,
            files: files,
          ),
          isNull,
        );
      },
    );

    test(
      'Dart, the SDK and Pinpoint are never the project, even in the set',
      () {
        final odd = ProjectFiles([
          'file:///work/app/lib/src/features/x/y.dart',
          'file:///sdk/lib/_engine/engine/platform_dispatcher.dart',
        ], unrooted);
        for (final line in [
          'dart-sdk/lib/async/zone.dart 710:7   run',
          'dart:async 1:1   foo',
          'org-dartlang-sdk:///lib/ui/x.dart 1:1   foo',
          'lib/_engine/engine/platform_dispatcher.dart 1733:5   invoke',
          'packages/pinpoint/src/overlay/state_tab.dart 9:9   setState',
          'package:pinpoint/src/state/listen.dart 9:9   _notified',
          'package:flutter/src/material/scrollbar.dart 429:5   handleHoverExit',
        ]) {
          expect(
            firstProjectFrameIn(line, unrooted, files: odd),
            isNull,
            reason: line,
          );
        }
      },
    );
  });
}
