import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/model/source_location.dart';

/// Milestone 3, build step 2: path normalizer and `isLocal` as pure
/// functions, table-driven.
void main() {
  group('normalizeSourcePath', () {
    const cases = <(String, String, String)>[
      // (why, input, expected)
      (
        'file URI, the normal case on VM and web',
        'file:///Users/me/app/lib/main.dart',
        '/Users/me/app/lib/main.dart',
      ),
      (
        'percent escapes are decoded',
        'file:///Users/me/my%20app/lib/main.dart',
        '/Users/me/my app/lib/main.dart',
      ),
      (
        'Windows drive in a file URI',
        'file:///C:/Users/me/app/lib/main.dart',
        'C:/Users/me/app/lib/main.dart',
      ),
      (
        'Windows drive with an escaped colon',
        'file:///c%3A/Users/me/app/lib/main.dart',
        'c:/Users/me/app/lib/main.dart',
      ),
      (
        'Windows path with backslashes',
        r'C:\Users\me\app\lib\main.dart',
        'C:/Users/me/app/lib/main.dart',
      ),
      (
        'package URI is kept as is',
        'package:my_app/widgets/save_bar.dart',
        'package:my_app/widgets/save_bar.dart',
      ),
      (
        'plain absolute path is kept',
        '/Users/me/app/lib/main.dart',
        '/Users/me/app/lib/main.dart',
      ),
      (
        'flutter test --platform chrome drops the directory',
        'org-dartlang-app:///main_test.dart',
        'main_test.dart',
      ),
      (
        'trailing slash on a directory is dropped',
        '/Users/me/app/',
        '/Users/me/app',
      ),
    ];
    for (final (why, input, expected) in cases) {
      test(why, () => expect(normalizeSourcePath(input), expected));
    }
  });

  group('isGeneratedSource', () {
    const cases = <(String, bool)>[
      ('/app/lib/model.g.dart', true),
      ('/app/lib/model.freezed.dart', true),
      ('/app/lib/model.dart', false),
      ('/app/lib/g.dart', false),
    ];
    for (final (path, expected) in cases) {
      test(path, () => expect(isGeneratedSource(path), expected));
    }
  });

  group('isLocal with a project root', () {
    const paths = SourcePaths(projectRoot: '/Users/me/app');
    const cases = <(String, String, bool)>[
      ('project file', 'file:///Users/me/app/lib/main.dart', true),
      ('project test file', 'file:///Users/me/app/test/a_test.dart', true),
      (
        'Flutter SDK',
        'file:///Users/me/fvm/versions/3.47.5/packages/flutter/lib/src/widgets/text.dart',
        false,
      ),
      (
        'pub cache',
        'file:///Users/me/.pub-cache/hosted/pub.dev/foo-1.0.0/lib/foo.dart',
        false,
      ),
      (
        'sibling directory sharing a prefix is not under the root',
        'file:///Users/me/app2/lib/main.dart',
        false,
      ),
      (
        'monorepo path dependency outside the root',
        'file:///Users/me/packages/ui/lib/button.dart',
        false,
      ),
      (
        'SDK linked inside the project (fvm) is still the SDK',
        'file:///Users/me/app/.fvm/flutter_sdk/packages/flutter/lib/src/widgets/text.dart',
        false,
      ),
      (
        'pub cache inside the project is still the pub cache',
        'file:///Users/me/app/.pub-cache/hosted/foo/lib/foo.dart',
        false,
      ),
      (
        'package URI: the package cannot be told apart',
        'package:app/main.dart',
        false,
      ),
      (
        'web test entrypoint has no directory; it is the app\'s own',
        'org-dartlang-app:///main_test.dart',
        true,
      ),
    ];
    for (final (why, file, expected) in cases) {
      test(why, () => expect(paths.isLocal(file), expected));
    }

    test('a trailing slash on the root changes nothing', () {
      const slash = SourcePaths(projectRoot: '/Users/me/app/');
      expect(slash.isLocal('file:///Users/me/app/lib/main.dart'), isTrue);
      expect(slash.isLocal('file:///Users/me/app2/lib/main.dart'), isFalse);
    });
  });

  // Acceptance: without PINPOINT_ROOT, classification still works through
  // the exclusion rule.
  group('isLocal without a project root (exclusion rule)', () {
    const paths = SourcePaths();
    const cases = <(String, String, bool)>[
      ('project file', 'file:///Users/me/app/lib/main.dart', true),
      (
        'Flutter SDK',
        'file:///Users/me/flutter/packages/flutter/lib/src/material/app.dart',
        false,
      ),
      (
        'pub cache',
        'file:///Users/me/.pub-cache/hosted/pub.dev/foo-1.0.0/lib/foo.dart',
        false,
      ),
      (
        'Windows pub cache (no .pub-cache in the path)',
        'file:///C:/Users/me/AppData/Local/Pub/Cache/hosted/foo/lib/foo.dart',
        false,
      ),
      (
        'Dart SDK under bin/cache',
        'file:///Users/me/flutter/bin/cache/dart-sdk/lib/core/list.dart',
        false,
      ),
      (
        'monorepo path dependency counts as local',
        'file:///Users/me/packages/ui/lib/button.dart',
        true,
      ),
      ('package URI', 'package:app/main.dart', false),
    ];
    for (final (why, file, expected) in cases) {
      test(why, () => expect(paths.isLocal(file), expected));
    }

    test('an empty root is the same as no root', () {
      const empty = SourcePaths(projectRoot: '');
      expect(empty.isLocal('file:///Users/me/app/lib/main.dart'), isTrue);
      expect(empty.projectRoot, isNull);
    });
  });

  // PLAN.md, Milestone 3, watch out: widgets from a path dependency in a
  // monorepo look external unless listed in localPathHints.
  group('localPathHints', () {
    const paths = SourcePaths(
      projectRoot: '/Users/me/mono/apps/shop',
      localPathHints: ['/Users/me/mono/packages/ui', 'package:design/'],
    );
    const cases = <(String, String, bool)>[
      (
        'hinted path dependency',
        'file:///Users/me/mono/packages/ui/lib/button.dart',
        true,
      ),
      ('hinted package URI', 'package:design/card.dart', true),
      (
        'unhinted sibling package',
        'file:///Users/me/mono/packages/net/lib/api.dart',
        false,
      ),
      ('the app itself', 'file:///Users/me/mono/apps/shop/lib/main.dart', true),
    ];
    for (final (why, file, expected) in cases) {
      test(why, () => expect(paths.isLocal(file), expected));
    }
  });

  // PLAN.md, Milestone 3, watch out: file-system case differs by platform.
  // Compare case-insensitively on Windows and macOS.
  group('case', () {
    test('case-insensitive by default (macOS and Windows)', () {
      const paths = SourcePaths(projectRoot: '/users/ME/App');
      expect(paths.isLocal('file:///Users/me/app/lib/main.dart'), isTrue);
      expect(
        paths.relativePath('file:///Users/me/app/lib/main.dart'),
        'lib/main.dart',
      );
      const windows = SourcePaths(projectRoot: r'c:\Users\me\app');
      expect(windows.isLocal('file:///C:/Users/me/app/lib/main.dart'), isTrue);
    });

    test('case-sensitive when asked (Linux)', () {
      const paths = SourcePaths(
        projectRoot: '/users/ME/App',
        caseSensitive: true,
      );
      expect(paths.isLocal('file:///Users/me/app/lib/main.dart'), isFalse);
    });

    test('the SDK exclusion ignores case on Windows', () {
      const paths = SourcePaths();
      expect(
        paths.isLocal('file:///C:/users/me/appdata/local/pub/cache/foo.dart'),
        isFalse,
      );
    });
  });

  group('relativePath and displayPath', () {
    const paths = SourcePaths(projectRoot: '/Users/me/app');

    test('under the root: relative to it', () {
      const file = 'file:///Users/me/app/lib/widgets/save_bar.dart';
      expect(paths.relativePath(file), 'lib/widgets/save_bar.dart');
      expect(paths.displayPath(file), 'lib/widgets/save_bar.dart');
    });

    test('outside the root: absolute, shortened for display', () {
      const file = 'file:///Users/me/packages/ui/lib/button.dart';
      expect(paths.relativePath(file), '/Users/me/packages/ui/lib/button.dart');
      expect(paths.displayPath(file), 'ui/lib/button.dart');
    });

    test('no root: shortened from the package directory', () {
      const none = SourcePaths();
      expect(
        none.displayPath('file:///Users/me/app/example/lib/screens/form.dart'),
        'example/lib/screens/form.dart',
      );
      expect(
        none.displayPath('file:///Users/me/app/test/fixtures/a.dart'),
        'app/test/fixtures/a.dart',
      );
      expect(none.displayPath('file:///tmp/a.dart'), '/tmp/a.dart');
    });

    test('a location label is the display path and the line', () {
      const location = SourceLocation(
        uri: 'file:///Users/me/app/lib/widgets/save_bar.dart',
        line: 42,
        column: 18,
      );
      expect(paths.label(location), 'lib/widgets/save_bar.dart:42');
    });
  });

  test('PinPointConfig reads the root and hints', () {
    const config = PinPointConfig(
      projectRoot: '/Users/me/app',
      localPathHints: ['/Users/me/packages/ui'],
    );
    expect(config.projectRoot, '/Users/me/app');
    expect(config.localPathHints, ['/Users/me/packages/ui']);
    // Default: the PINPOINT_ROOT define, empty when not set.
    expect(const PinPointConfig().projectRoot, '');
  });
}
