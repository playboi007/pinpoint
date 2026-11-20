import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/bridge/source_lookup.dart';

/// Milestone 21, build step 6: the bridge reads the app's own source for
/// the state lens. A temporary project folder is made in each test.
void main() {
  late Directory project;
  late Directory outside;
  late SourceLookup lookup;
  late List<String> reads;

  const provider = '''
import 'package:flutter/foundation.dart';

class ProductDetailProvider extends ChangeNotifier {
  bool _loading = false;
  bool _dialogLoading = false;

  bool get loading => _loading;

  Future<void> fetchDialog() async {
    _dialogLoading = true;
    _loading = true;
    notifyListeners();
    await Future<void>.delayed(Duration.zero);
    _dialogLoading = false;
    notifyListeners();
  }

  void reset(
    int a,
    int b,
  ) {
    setState(() {
      _loading = false;
      _dialogLoading =
          a > b;
    });
  }
}

String topLevel(int x) {
  final y = x + 1;
  return 'a { b' + '\$y';
}

int tight(int x) => x * 2;
''';

  setUp(() async {
    project = await Directory.systemTemp.createTemp('pinpoint_source_');
    outside = await Directory.systemTemp.createTemp('pinpoint_outside_');
    File('${project.path}/pubspec.yaml').writeAsStringSync('name: my_app\n');
    Directory('${project.path}/lib/models').createSync(recursive: true);
    File(
      '${project.path}/lib/models/provider.dart',
    ).writeAsStringSync(provider);
    File('${outside.path}/secret.dart').writeAsStringSync('// secret\n');
    reads = <String>[];
    lookup = SourceLookup(
      project,
      reader: (file) {
        reads.add(file.path);
        return file.readAsString();
      },
    );
  });

  tearDown(() async {
    await project.delete(recursive: true);
    await outside.delete(recursive: true);
  });

  int lineOf(String needle, {int nth = 1}) {
    final lines = provider.split('\n');
    var seen = 0;
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].contains(needle) && ++seen == nth) return i + 1;
    }
    throw StateError('no $needle');
  }

  group('methodLines', () {
    test(
      'a line inside a method gives the method up to the statement',
      () async {
        final line = lineOf('_loading = true;');
        final snippet = await lookup.methodLines(
          'lib/models/provider.dart',
          line,
        );
        expect(snippet.file, 'lib/models/provider.dart');
        expect(snippet.start, lineOf('Future<void> fetchDialog'));
        expect(snippet.end, line);
        expect(snippet.text, '''
  Future<void> fetchDialog() async {
    _dialogLoading = true;
    _loading = true;''');
      },
    );

    test('the notify line shows what the method set before it', () async {
      final snippet = await lookup.methodLines(
        'lib/models/provider.dart',
        lineOf('notifyListeners();'),
      );
      expect(snippet.text, contains('_dialogLoading = true;'));
      expect(snippet.text, contains('_loading = true;'));
      expect(snippet.text.trimRight(), endsWith('notifyListeners();'));
    });

    test('a getter', () async {
      final line = lineOf('bool get loading');
      final snippet = await lookup.methodLines(
        'lib/models/provider.dart',
        line,
      );
      expect(snippet.start, line);
      expect(snippet.end, line);
      expect(snippet.text.trim(), 'bool get loading => _loading;');
    });

    test('a top-level function, with a brace in a string', () async {
      final line = lineOf("final y = x + 1;");
      final snippet = await lookup.methodLines(
        'lib/models/provider.dart',
        line,
      );
      expect(snippet.start, lineOf('String topLevel'));
      expect(snippet.text, startsWith('String topLevel(int x) {'));
      expect(snippet.end, line);
    });

    test('the header line asked for gives the whole method', () async {
      final snippet = await lookup.methodLines(
        'lib/models/provider.dart',
        lineOf('String topLevel'),
      );
      expect(snippet.end, lineOf('int tight') - 2);
      expect(snippet.text.trimRight(), endsWith('}'));
    });

    test('a setState closure is not taken for the method header', () async {
      final snippet = await lookup.methodLines(
        'lib/models/provider.dart',
        lineOf('_loading = false;', nth: 2),
      );
      expect(snippet.start, lineOf('void reset('));
    });

    test('a statement over several lines runs to its end', () async {
      final snippet = await lookup.methodLines(
        'lib/models/provider.dart',
        lineOf('a > b;') - 1,
      );
      expect(snippet.text.trimRight(), endsWith('a > b;'));
    });

    test('before limits how far up the start is looked for', () async {
      final line = lineOf('_loading = true;');
      final snippet = await lookup.methodLines(
        'lib/models/provider.dart',
        line,
        before: 0,
      );
      expect(snippet.start, line);
    });

    test('the text is cut at 4 KB', () async {
      final big = List.generate(400, (i) => '    final v$i = $i;').join('\n');
      File(
        '${project.path}/lib/big.dart',
      ).writeAsStringSync('void big() {\n$big\n}\n');
      final snippet = await lookup.methodLines(
        'lib/big.dart',
        300,
        before: 100,
      );
      expect(snippet.text.length, lessThanOrEqualTo(SourceLookup.maxBytes));
      expect(snippet.end, lessThanOrEqualTo(300));
    });

    test('an absolute path, a package: URI and a file: URI all work', () async {
      final line = lineOf('_loading = true;');
      final real = project.resolveSymbolicLinksSync();
      for (final file in [
        '$real/lib/models/provider.dart',
        '${project.path}/lib/models/provider.dart',
        'package:my_app/models/provider.dart',
        Uri.file('$real/lib/models/provider.dart').toString(),
        'lib/models/../models/provider.dart',
      ]) {
        final snippet = await lookup.methodLines(file, line);
        expect(snippet.file, 'lib/models/provider.dart', reason: file);
        expect(snippet.start, lineOf('Future<void> fetchDialog'));
      }
    });

    test('refuses a path outside the project', () async {
      final link = Link('${project.path}/lib/link');
      link.createSync(outside.path);
      final outsideFile = '${outside.path}/secret.dart';
      final cases = {
        '../${outside.path.split('/').last}/secret.dart': 403,
        'lib/../../etc/hosts.dart': 403,
        outsideFile: 403,
        'lib/link/secret.dart': 403,
        'package:other_app/x.dart': 403,
      };
      for (final MapEntry(key: file, value: status) in cases.entries) {
        await expectLater(
          lookup.methodLines(file, 1),
          throwsA(
            isA<SourceLookupException>().having(
              (e) => e.status,
              'status',
              status,
            ),
          ),
          reason: file,
        );
      }
      expect(reads, isEmpty, reason: 'nothing outside was read');
    });

    test('400 for bad input, 404 for a missing file', () async {
      for (final (file, line, status) in [
        ('', 1, 400),
        ('lib/models/provider.dart', 0, 400),
        ('lib/models/provider.dart', 9999, 400),
        ('pubspec.yaml', 1, 400),
        ('lib/nothing.dart', 1, 404),
        ('lib/models', 1, 400),
        ('lib/models/dir.dart', 1, 404),
      ]) {
        await expectLater(
          lookup.methodLines(file, line),
          throwsA(
            isA<SourceLookupException>().having(
              (e) => e.status,
              'status',
              status,
            ),
          ),
          reason: '$file:$line',
        );
      }
    });
  });

  group('declaration', () {
    void write(String name, String source) {
      final file = File('${project.path}/lib/$name');
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(source);
    }

    test('finds each form of declaration', () async {
      write('a.dart', '''
// class Foo in a comment
class Foo {}
''');
      write('b.dart', 'abstract class Bar {}\n');
      write('c.dart', '''
import 'x.dart';

class _FooState extends State<Foo> {}
''');
      write('d.dart', 'mixin Baz on Object {}\n');
      write('e.dart', 'enum Mode { a }\n');
      write('f.dart', 'extension type const Meters(int v) {}\n');
      write('g.dart', 'sealed class Shape {}\nbase mixin class Both {}\n');
      write('h.dart', 'abstract interface class Port {}\n');

      Future<List<Object?>> at(String name) async {
        final found = await lookup.declaration(name);
        return [found?.file, found?.line];
      }

      expect(await at('Foo'), ['lib/a.dart', 2]);
      expect(await at('Bar'), ['lib/b.dart', 1]);
      expect(await at('_FooState'), ['lib/c.dart', 3]);
      expect(await at('Baz'), ['lib/d.dart', 1]);
      expect(await at('Mode'), ['lib/e.dart', 1]);
      expect(await at('Meters'), ['lib/f.dart', 1]);
      expect(await at('Shape'), ['lib/g.dart', 1]);
      expect(await at('Both'), ['lib/g.dart', 2]);
      expect(await at('Port'), ['lib/h.dart', 1]);
      expect(await at('Foo<T>'), ['lib/a.dart', 2], reason: 'generic name');
    });

    test('Foo does not match FooBar', () async {
      write('a.dart', 'class FooBar {}\nclass Foo2 {}\n');
      expect(await lookup.declaration('Foo'), isNull);
      expect((await lookup.declaration('FooBar'))!.line, 1);
    });

    test('generated files are skipped', () async {
      write('model.g.dart', 'class Gen {}\n');
      write('model.freezed.dart', 'class Frozen {}\n');
      write('real.dart', 'class Real {}\n');
      expect(await lookup.declaration('Gen'), isNull);
      expect(await lookup.declaration('Frozen'), isNull);
      expect(await lookup.declaration('Real'), isNotNull);
    });

    test('a bad name is a 400, a missing lib/ is null', () async {
      await expectLater(
        lookup.declaration('not a type'),
        throwsA(isA<SourceLookupException>()),
      );
      expect(await lookup.declaration('Foo'), isNull);
    });

    test('an unchanged file is not read again; a changed one is', () async {
      write('a.dart', 'class Foo {}\n');
      write('b.dart', 'class Bar {}\n');
      await lookup.declaration('Bar');
      expect(reads, hasLength(2));
      await lookup.declaration('Foo');
      await lookup.declaration('Bar');
      expect(reads, hasLength(2), reason: 'both came from the cache');

      final file = File('${project.path}/lib/a.dart');
      file.writeAsStringSync('class Other {}\nclass Foo {}\n');
      file.setLastModifiedSync(DateTime.now().add(const Duration(minutes: 1)));
      expect((await lookup.declaration('Foo'))!.line, 2);
      expect(reads, hasLength(3), reason: 'only the changed file');
    });
  });
}
