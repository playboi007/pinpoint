import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/capture/context_collector.dart';
import 'package:pinpoint/src/model/annotation.dart' show jsonNumber;
import 'package:pinpoint/src/model/source_location.dart';
import 'package:pinpoint/src/overlay/inspector_overlay.dart';
import 'package:pinpoint/src/search/pick_result.dart';
import 'package:pinpoint/src/search/source_resolver.dart';

import '../fixtures/annotation_fixture.dart';
import '../support/markers.dart';

/// Milestone 4, build step 3: `target` is built from `WidgetInfo`, so the
/// info panel and the note can never disagree. Includes the golden note.
void main() {
  const golden = 'test/goldens/save_changes_annotation.json';
  final root = Directory.current.path;
  late PinPointController controller;

  setUp(() => controller = PinPointController());
  tearDown(() => controller.dispose());

  Widget host(Widget home) => MaterialApp(
    builder: (context, child) => PinPointWrapper(
      controller: controller,
      config: PinPointConfig(projectRoot: root),
      child: child,
    ),
    home: home,
  );

  final collector = ContextCollector(
    clock: () => DateTime.utc(2026, 11, 10, 14, 32, 5),
    random: math.Random(7),
    pageUrl: () => null,
  );

  Annotation collect(WidgetTester tester, PickResult pick) => collector.collect(
    pick,
    'Label truncates at narrow widths',
    AnnotationIntent.improve,
    context: tester.element(find.byType(InspectorOverlay)),
  );

  Finder appText(String text) => find
      .descendant(of: find.byType(Scaffold), matching: find.text(text))
      .first;

  Future<PickResult> select(WidgetTester tester, String text) async {
    controller.startPicking();
    await tester.pump();
    await tester.tapAt(tester.getCenter(appText(text)));
    await tester.pump();
    return controller.selection.value!;
  }

  /// [element] selected as is, with the wrapper's boundary.
  PickResult forElement(WidgetTester tester, Element element) =>
      PickResult.forElement(
        element,
        rootElement: tester.binding.rootElement!,
        resolver: SourceResolver(paths: SourcePaths(projectRoot: root)),
      )!;

  group('acceptance', () {
    testWidgets('the note for a fixed widget matches the golden file', (
      tester,
    ) async {
      await tester.pumpWidget(host(orderHome()));
      final note = collect(tester, await select(tester, 'Save changes'));

      final actual = _comparable(note.toJson(), root);
      if (autoUpdateGoldenFiles) {
        File(golden).writeAsStringSync(
          '${const JsonEncoder.withIndent('  ').convert(actual)}\n',
        );
      }
      final expected = jsonDecode(File(golden).readAsStringSync());
      expect(
        actual,
        expected,
        reason:
            'Run `flutter test --update-goldens $golden` after a deliberate '
            'change, and review the diff.',
      );
      // The column is the constructor name's own column.
      expect(
        note.target.source!.column,
        markerColumn(annotationFixture, 'bar_text', 'Text('),
      );
    });

    testWidgets('no exception when the target is a sliver', (tester) async {
      await tester.pumpWidget(
        host(
          Scaffold(
            body: CustomScrollView(
              slivers: [
                const SliverAppBar(title: Text('Orders'), pinned: true),
                const SliverPadding(
                  padding: EdgeInsets.all(8),
                  sliver: SliverToBoxAdapter(child: Text('header')),
                ),
                SliverList.builder(
                  itemCount: 50,
                  itemBuilder: (_, i) => Text('order $i'),
                ),
              ],
            ),
          ),
        ),
      );
      final slivers = find.byWidgetPredicate(
        (w) =>
            w is SliverAppBar ||
            w is SliverPadding ||
            w is SliverToBoxAdapter ||
            w is SliverList,
      );
      expect(slivers, findsNWidgets(4));
      for (final element in slivers.evaluate()) {
        final note = collect(tester, forElement(tester, element));
        final name = element.widget.runtimeType.toString();
        expect(note.errors, isEmpty, reason: name);
        expect(() => jsonEncode(note.toJson()), returnsNormally);
        expect(note.target.renderObject, contains('RenderSliver'));
        expect(note.target.constraints, startsWith('SliverConstraints'));
        expect(note.target.rect, isNotNull, reason: name);
      }
    });
  });

  group('target', () {
    testWidgets('geometry and sections are the info panel\'s', (tester) async {
      await tester.pumpWidget(host(orderHome()));
      final pick = await select(tester, 'Save changes');
      final note = collect(tester, pick);
      final info = WidgetInfo.fromRenderObject(pick.renderObject);

      final rect = note.target.rect!.toJson();
      expect(rect, {
        'x': jsonNumber(info.globalPosition.dx),
        'y': jsonNumber(info.globalPosition.dy),
        'w': jsonNumber(info.size.width),
        'h': jsonNumber(info.size.height),
      });
      expect(note.target.renderObject, info.renderType);
      expect(note.target.constraints, info.constraints.toString());
      expect(note.target.sections.keys, [
        for (final s in info.sections) s.title,
      ]);
      expect(note.target.sections['Text'], {
        for (final p in info.sections.single.properties) p.name: p.label,
      });
    });

    testWidgets('description, properties, text and parentData', (tester) async {
      await tester.pumpWidget(host(orderHome()));
      final note = collect(tester, await select(tester, 'Save changes'));

      expect(note.target.description, 'Text("Save changes")');
      expect(note.target.properties, {'maxLines': '1', 'overflow': 'ellipsis'});
      expect(note.target.text, 'Save changes');
      expect(note.target.parentData, startsWith('offset=Offset('));
    });

    testWidgets('text joins every RichText and field below the target, '
        'capped at 300', (tester) async {
      final long = 'x' * 400;
      await tester.pumpWidget(
        host(
          Scaffold(
            body: Column(
              children: [
                const Text('first'),
                TextField(controller: TextEditingController(text: 'typed')),
                Text(long),
              ],
            ),
          ),
        ),
      );
      final note = collect(
        tester,
        forElement(tester, tester.element(find.byType(Column).first)),
      );
      final text = note.target.text!;
      expect(text, startsWith('first typed x'));
      expect(text.length, 300);
      expect(text, endsWith('…'));
    });
  });

  group('watch out for', () {
    testWidgets('author code in toStringShort and toDescription can throw or '
        'return kilobytes', (tester) async {
      await tester.pumpWidget(host(const Scaffold(body: _Noisy())));
      final note = collect(
        tester,
        forElement(tester, tester.element(find.byType(_Noisy))),
      );

      expect(note.errors, isEmpty);
      expect(note.target.widget, '_Noisy');
      // toStringShort threw: the type name stands in.
      expect(note.target.description, '_Noisy');
      expect(note.target.properties['huge']!.length, 200);
      expect(note.target.properties['huge'], endsWith('…'));
      expect(note.target.properties.containsKey('broken'), isFalse);
      expect(note.target.properties['fine'], 'ok');
      // The siblings and subtree call toStringShort too.
      expect(note.subtree, startsWith('_Noisy'));
    });

    testWidgets('properties stop at 20', (tester) async {
      await tester.pumpWidget(host(const Scaffold(body: _Noisy(extra: 40))));
      final note = collect(
        tester,
        forElement(tester, tester.element(find.byType(_Noisy))),
      );
      expect(note.target.properties, hasLength(20));
    });

    testWidgets('colors are hex, not Color.toString()', (tester) async {
      await tester.pumpWidget(host(orderHome()));
      final note = collect(
        tester,
        forElement(
          tester,
          tester.element(
            find.descendant(
              of: find.byType(Scaffold),
              matching: find.byType(Icon),
            ),
          ),
        ),
      );
      expect(note.target.properties['color'], '#F44336');
    });

    testWidgets('unbounded constraints stay strings and the JSON encodes', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          const Scaffold(
            body: SingleChildScrollView(child: Column(children: [Text('a')])),
          ),
        ),
      );
      final note = collect(tester, await select(tester, 'a'));
      expect(note.target.constraints, contains('Infinity'));
      expect(() => jsonEncode(note.toJson()), returnsNormally);
    });

    testWidgets('text is masked when an obscured field is in the subtree', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          Scaffold(
            body: Column(
              children: [
                TextField(
                  obscureText: true,
                  controller: TextEditingController(text: 'hunter2'),
                  decoration: const InputDecoration(labelText: 'Password'),
                ),
              ],
            ),
          ),
        ),
      );
      for (final type in [Column, TextField, EditableText]) {
        final note = collect(
          tester,
          forElement(tester, tester.element(find.byType(type).first)),
        );
        final json = jsonEncode(note.toJson());
        expect(json, isNot(contains('hunter2')), reason: '$type');
        expect(note.target.text, contains('[masked]'), reason: '$type');
      }
      final field = collect(
        tester,
        forElement(tester, tester.element(find.byType(TextField))),
      );
      expect(field.target.text, contains('Password'));
      expect(field.target.properties['controller'], '[masked]');
      expect(field.target.properties['obscureText'], 'true');
    });
  });
}

/// [json] without what changes between runs and machines: `id` and
/// `createdAt` are dropped, the project root becomes `<root>`, and fixture
/// line numbers become their `PIN:` marker names.
Object? _comparable(Map<String, Object?> json, String root) {
  final markers = markersOf(annotationFixture);
  String marked(int line) => 'PIN:${markers[line] ?? line}';

  Object? walk(Object? value) {
    if (value is Map) {
      final map = <String, Object?>{
        for (final MapEntry(:key, :value) in value.entries)
          key as String: walk(value),
      };
      if (map['file'] == annotationFixture && map['line'] is int) {
        map['line'] = marked(map['line']! as int);
        // Checked on its own; columns move with formatting.
        map.remove('column');
      }
      return map;
    }
    if (value is List) return [for (final v in value) walk(v)];
    if (value is String) {
      return value
          .replaceAll(root, '<root>')
          .replaceAllMapped(
            RegExp('${RegExp.escape(annotationFixture)}:(\\d+)'),
            (m) => '$annotationFixture:${marked(int.parse(m[1]!))}',
          );
    }
    return value;
  }

  final copy = walk(json)! as Map<String, Object?>
    ..remove('id')
    ..remove('createdAt');
  return copy;
}

/// A widget whose diagnostics misbehave, as author code can.
class _Noisy extends StatelessWidget {
  const _Noisy({this.extra = 0});

  final int extra;

  @override
  String toStringShort() => throw StateError('toStringShort failed');

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties
      ..add(StringProperty('huge', 'y' * 10000))
      ..add(DiagnosticsProperty<Object>('broken', _Throws()))
      ..add(StringProperty('fine', 'ok', quoted: false));
    for (var i = 0; i < extra; i++) {
      properties.add(IntProperty('p$i', i));
    }
  }

  @override
  Widget build(BuildContext context) => const SizedBox(width: 10, height: 10);
}

class _Throws {
  @override
  String toString() => throw StateError('toString failed');
}
