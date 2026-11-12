import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/agent/commands.dart';
import 'package:pinpoint/src/overlay/agent_layer.dart';
import 'package:pinpoint/src/search/source_index.dart';
import 'package:pinpoint/src/search/source_resolver.dart';

import '../support/agent_host.dart';
import '../support/markers.dart';

const String _file = 'test/agent/read_tools_test.dart';

/// Milestone 12, build step 2: the read-only tools `find_widgets`,
/// `inspect` and `flash`, which reuse the reverse lookup and the
/// collector of earlier milestones.
void main() {
  late PinPointController controller;
  late AgentBridge bridge;

  setUp(() {
    controller = PinPointController();
    bridge = AgentBridge();
  });
  tearDown(() => controller.dispose());

  // Every test ends with the bridge shut down: no poll or timer outlives
  // it.
  Future<void> pumpScreen(WidgetTester tester, Widget home) async {
    await tester.pumpWidget(agentApp(controller: controller, home: home));
    await tester.pump();
  }

  Future<Map<String, Object?>> run(
    WidgetTester tester,
    String tool, [
    Map<String, Object?> args = const {},
  ]) async {
    final answer = await drive(tester, controller.agent.run(tool, args));
    return answer;
  }

  Future<List<Map<String, Object?>>> found(
    WidgetTester tester,
    Map<String, Object?> query,
  ) async {
    final answer = await run(tester, 'find_widgets', query);
    expect(answer['ok'], isTrue, reason: '$answer');
    final result = answer['result']! as Map<String, Object?>;
    return (result['widgets']! as List<Object?>).cast<Map<String, Object?>>();
  }

  testWidgets('acceptance: find_widgets with a file and line returns the '
      'right widget, and flash outlines it', (tester) async {
    await pumpScreen(tester, const _Screen());
    final line = markerLine(_file, 'save');
    final widgets = await found(tester, {'file': _file, 'line': line});
    // Every constructor call on the line, the outer one first: the
    // button and its label.
    expect(widgets.map((w) => w['widget']), ['ElevatedButton', 'Text']);
    final save = widgets.first;
    expect(save['widget'], 'ElevatedButton');
    expect(save['source'], endsWith('$_file:$line'));
    expect(save['visible'], isTrue);
    final rect = tester.getRect(find.byType(ElevatedButton));
    final measured = (save['rect']! as List<Object?>).cast<num>();
    for (final (i, value) in [
      rect.left,
      rect.top,
      rect.width,
      rect.height,
    ].indexed) {
      expect(measured[i], closeTo(value, 0.05), reason: 'rounded to 0.1');
    }

    final flash = await run(tester, 'flash', {'handle': save['handle']});
    expect(flash['ok'], isTrue, reason: '$flash');
    final target = controller.agent.flash.value;
    expect(target, isNotNull);
    expect(
      tester.renderObject(find.byType(ElevatedButton)),
      same(target),
      reason: 'the outline is on the button',
    );
    await tester.pump();
    expect(
      find.byKey(AgentLayer.marksKey),
      // The double outline: four rings, the outer paper one first.
      paints
        ..rect(rect: rect.inflate(4.5))
        ..rect(rect: rect.inflate(2.5))
        ..rect(rect: rect.inflate(0.5))
        ..rect(rect: rect.deflate(1)),
    );
    // For 1.5 seconds.
    await tester.pump(const Duration(milliseconds: 1600));
    expect(controller.agent.flash.value, isNull);
    await bridge.shutdown(tester);
  });

  testWidgets('a file path works relative, absolute or by its tail', (
    tester,
  ) async {
    await pumpScreen(tester, const _Screen());
    final line = markerLine(_file, 'title');
    for (final file in [
      _file,
      File(_file).absolute.path,
      'agent/read_tools_test.dart',
    ]) {
      final widgets = await found(tester, {'file': file, 'line': line});
      expect(widgets.single['text'], 'Title', reason: file);
    }
    // A different file with the same tail is not a match.
    expect(await found(tester, {'file': 'x/read_tools_test.dart'}), isEmpty);
    await bridge.shutdown(tester);
  });

  testWidgets('after an edit moves the line, the nearest line of the same '
      'type is found', (tester) async {
    await pumpScreen(tester, const _Screen());
    final line = markerLine(_file, 'save');
    final widgets = await found(tester, {
      'file': _file,
      'line': line - 3,
      'type': 'ElevatedButton',
    });
    expect(widgets.single['source'], endsWith('$_file:$line'));
    await bridge.shutdown(tester);
  });

  testWidgets('type, text and key filters; every given one must match', (
    tester,
  ) async {
    await pumpScreen(tester, const _Screen());
    final texts = await found(tester, {'type': 'Text'});
    expect(texts.map((w) => w['text']), containsAll(['Title', 'Save']));

    final byText = await found(tester, {'text': 'save'});
    expect(byText.map((w) => w['widget']), [
      'Text',
    ], reason: 'no RichText twin');
    expect(await found(tester, {'text': 'Save', 'type': 'Icon'}), isEmpty);

    final keyed = await found(tester, {'key': 'note'});
    expect(keyed.single['widget'], 'TextField');
    expect(keyed.single['key'], "[<'note'>]");
    await bridge.shutdown(tester);
  });

  testWidgets('watch out for: a lazy list item that was never built is not '
      'found', (tester) async {
    await pumpScreen(tester, const _List());
    expect(await found(tester, {'text': 'Item 3'}), hasLength(1));
    expect(await found(tester, {'text': 'Item 900'}), isEmpty);
    await bridge.shutdown(tester);
  });

  testWidgets('lists stop at 20 unless asked for more', (tester) async {
    await pumpScreen(tester, const _List());
    final answer = await run(tester, 'find_widgets', {'type': 'Text'});
    final result = answer['result']! as Map<String, Object?>;
    expect(result['widgets'], hasLength(20));
    expect(result['more'], greaterThan(0));
    final more = await found(tester, {'type': 'Text', 'limit': 30});
    expect(more.length, greaterThan(20));
    await bridge.shutdown(tester);
  });

  testWidgets('inspect gives the note payload for a handle', (tester) async {
    await pumpScreen(tester, const _Screen());
    final save = (await found(tester, {
      'file': _file,
      'line': markerLine(_file, 'save'),
      'type': 'ElevatedButton',
    })).single;
    final answer = await run(tester, 'inspect', {'handle': save['handle']});
    expect(answer['ok'], isTrue, reason: '$answer');
    final result = answer['result']! as Map<String, Object?>;
    final note = result['note']! as Map<String, Object?>;
    final target = note['target']! as Map<String, Object?>;
    expect(target['widget'], 'ElevatedButton');
    expect((target['source']! as Map)['line'], markerLine(_file, 'save'));
    expect(note.containsKey('screenshot'), isFalse);
    await bridge.shutdown(tester);
  });

  testWidgets('watch out for: a handle whose widget is gone is refused as '
      'stale, never used for another widget', (tester) async {
    final show = ValueNotifier<bool>(true);
    addTearDown(show.dispose);
    await pumpScreen(tester, _Toggle(show: show));
    final title = (await found(tester, {'text': 'Title'})).single;
    show.value = false;
    await tester.pump();
    final answer = await run(tester, 'flash', {'handle': title['handle']});
    expect(answer['ok'], isFalse);
    expect(answer['error'], startsWith('stale handle'));
    expect(controller.agent.flash.value, isNull);

    final unknown = await run(tester, 'flash', {'handle': 'h999'});
    expect(unknown['error'], startsWith('unknown handle'));
    await bridge.shutdown(tester);
  });

  testWidgets('a handle whose element was replaced is found again from its '
      'anchor', (tester) async {
    final generation = ValueNotifier<int>(0);
    addTearDown(generation.dispose);
    await pumpScreen(tester, _Rekeyed(generation: generation));
    final title = (await found(tester, {'text': 'Title'})).single;
    // A new key: the old element is unmounted and a new one built.
    generation.value = 1;
    await tester.pump();
    final answer = await run(tester, 'flash', {'handle': title['handle']});
    expect(answer['ok'], isTrue, reason: '$answer');
    await bridge.shutdown(tester);
  });

  testWidgets('watch out for: a handle with no anchor expires after its '
      'short lifetime; one with an anchor does not', (tester) async {
    await pumpScreen(tester, const _Screen());
    var now = DateTime(2026, 11, 11);
    final table = HandleTable(clock: () => now);
    final element = tester.element(find.text('Title'));
    final root = tester.element(find.byType(_Screen));
    final index = SourceIndex(resolver: const SourceResolver());
    final id = table.add(element, null);
    final anchored = table.add(element, index.anchorFor(element, root: root));
    expect(table.resolve(id, root: root, index: index), same(element));
    now = now.add(HandleTable.lifetime + const Duration(seconds: 1));
    // Checked against its anchor on each use, so age does not matter.
    expect(table.resolve(anchored, root: root, index: index), same(element));
    expect(
      () => table.resolve(id, root: root, index: index),
      throwsA(
        isA<AgentError>().having(
          (e) => e.message,
          'message',
          startsWith('stale handle'),
        ),
      ),
    );
    await bridge.shutdown(tester);
  });
}

class _Screen extends StatelessWidget {
  const _Screen();

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        const Text('Title'), // PIN:title
        // PIN:save
        ElevatedButton(onPressed: () {}, child: const Text('Save')),
        const TextField(key: ValueKey<String>('note')),
        const Icon(Icons.star),
      ],
    ),
  );
}

class _List extends StatelessWidget {
  const _List();

  @override
  Widget build(BuildContext context) => Scaffold(
    body: ListView.builder(
      itemCount: 1000,
      itemExtent: 40,
      itemBuilder: (context, i) => Text('Item $i'),
    ),
  );
}

class _Toggle extends StatelessWidget {
  const _Toggle({required this.show});

  final ValueNotifier<bool> show;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: ValueListenableBuilder<bool>(
      valueListenable: show,
      builder: (context, on, _) => on
          ? const Text('Title')
          // Another constructor call of the same type, on another line:
          // the handle must not move to it.
          : const Text('Gone'),
    ),
  );
}

class _Rekeyed extends StatelessWidget {
  const _Rekeyed({required this.generation});

  final ValueNotifier<int> generation;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: ValueListenableBuilder<int>(
      valueListenable: generation,
      builder: (context, n, _) =>
          KeyedSubtree(key: ValueKey<int>(n), child: const Text('Title')),
    ),
  );
}
