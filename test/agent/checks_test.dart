import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/agent/checks.dart';
import 'package:pinpoint/src/search/source_resolver.dart';

import '../support/agent_host.dart';

/// Milestone 12, build step 3: each check type, measured on a fixture
/// with one planted problem per kind, passing and failing.
void main() {
  late CheckRunner runner;

  Future<void> pumpFixture(WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: RepaintBoundary(child: _Fixture())),
    );
    await tester.pump();
    runner = CheckRunner(
      appRoot: tester.renderObject(find.byType(RepaintBoundary).first),
      content: tester.element(find.byType(_Fixture)),
      resolver: const SourceResolver(),
      devicePixelRatio: tester.view.devicePixelRatio,
    );
  }

  Element byKey(WidgetTester tester, String key) =>
      tester.element(find.byKey(ValueKey<String>(key), skipOffstage: false));

  Future<CheckResult> check(
    WidgetTester tester,
    String key,
    Map<String, Object?> check,
  ) async {
    final results = await drive(
      tester,
      runner.run(byKey(tester, key), [check]),
      realTime: true,
    );
    return results.single;
  }

  testWidgets('no_overflow fails on the overflowing Row and passes on a '
      'fitting one', (tester) async {
    await pumpFixture(tester);
    final bad = await check(tester, 'overflow', {'type': 'no_overflow'});
    expect(bad.passed, isFalse);
    expect(bad.message, contains('overflows by 100 px'));
    final good = await check(tester, 'fits', {'type': 'no_overflow'});
    expect(good.passed, isTrue, reason: good.message);
  });

  testWidgets('not_truncated', (tester) async {
    await pumpFixture(tester);
    final bad = await check(tester, 'cut', {'type': 'not_truncated'});
    expect(bad.passed, isFalse);
    expect(bad.message, contains('Text cut at 1 line'));
    expect(
      (await check(tester, 'label', {'type': 'not_truncated'})).passed,
      isTrue,
    );
  });

  testWidgets('min_size and max_size measure the rect', (tester) async {
    await pumpFixture(tester);
    final small = await check(tester, 'small', {
      'type': 'min_size',
      'width': 48,
      'height': 48,
    });
    expect(small.passed, isFalse);
    expect(small.measured, {'width': 24, 'height': 24});
    expect(
      (await check(tester, 'small', {'type': 'max_size', 'width': 30})).passed,
      isTrue,
    );
    expect(
      (await check(tester, 'small', {'type': 'min_size', 'height': 24})).passed,
      isTrue,
      reason: 'within half a pixel',
    );
  });

  testWidgets('within_parent: the box that sticks out of its parent fails', (
    tester,
  ) async {
    await pumpFixture(tester);
    final out = await check(tester, 'sticks_out', {'type': 'within_parent'});
    expect(out.passed, isFalse);
    expect(out.message, contains('right by 20'));
    expect(
      (await check(tester, 'inside', {'type': 'within_parent'})).passed,
      isTrue,
    );
  });

  testWidgets('gap_to and aligned_with measure against another anchored '
      'widget', (tester) async {
    await pumpFixture(tester);
    final second = {'widget': 'SizedBox', 'key': "[<'second'>]"};
    final gap = await check(tester, 'first', {
      'type': 'gap_to',
      'target': second,
      'min': 8,
      'max': 12,
    });
    expect(gap.passed, isFalse);
    expect(gap.measured, 16);
    expect(
      (await check(tester, 'first', {
        'type': 'gap_to',
        'target': second,
        'min': 16,
        'max': 16,
      })).passed,
      isTrue,
    );
    expect(
      (await check(tester, 'first', {
        'type': 'aligned_with',
        'target': second,
        'edge': 'top',
      })).passed,
      isTrue,
    );
    final left = await check(tester, 'first', {
      'type': 'aligned_with',
      'target': second,
      'edge': 'left',
    });
    expect(left.passed, isFalse);
    final missing = await check(tester, 'first', {
      'type': 'gap_to',
      'target': {'widget': 'SizedBox', 'key': "[<'nope'>]"},
    });
    expect(missing.passed, isFalse);
    expect(missing.message, contains('target not found'));
  });

  testWidgets('text_contains reads the text in the subtree', (tester) async {
    await pumpFixture(tester);
    expect(
      (await check(tester, 'label', {
        'type': 'text_contains',
        'text': 'Save',
      })).passed,
      isTrue,
    );
    final no = await check(tester, 'label', {
      'type': 'text_contains',
      'text': 'Cancel',
    });
    expect(no.passed, isFalse);
    expect(no.measured, 'Save changes');
  });

  testWidgets('contrast_min measures the text against its background', (
    tester,
  ) async {
    await pumpFixture(tester);
    final low = await check(tester, 'faint', {
      'type': 'contrast_min',
      'min': 4.5,
    });
    expect(low.passed, isFalse);
    expect(low.measured, lessThan(2));
    final high = await check(tester, 'label', {
      'type': 'contrast_min',
      'min': 4.5,
    });
    expect(high.passed, isTrue, reason: high.message);
  }, semanticsEnabled: false);

  testWidgets('tap_target_min measures the semantics node', (tester) async {
    await pumpFixture(tester);
    final small = await check(tester, 'tiny_button', {
      'type': 'tap_target_min',
      'min': 48,
    });
    expect(small.passed, isFalse);
    expect(small.measured, 24);
    expect(SemanticsBinding.instance.semanticsEnabled, isFalse);
  }, semanticsEnabled: false);

  testWidgets('visible', (tester) async {
    await pumpFixture(tester);
    expect((await check(tester, 'label', {'type': 'visible'})).passed, isTrue);
    expect(
      (await check(tester, 'offstage', {'type': 'visible'})).passed,
      isFalse,
    );
  });

  testWidgets('watch out for: every check fails with "anchor not found" '
      'when the widget does not resolve: never a pass for a widget that '
      'is gone', (tester) async {
    await pumpFixture(tester);
    final results = await drive(
      tester,
      runner.run(null, [
        {'type': 'no_overflow'},
        {'type': 'not_truncated'},
        {'type': 'visible'},
        {'type': 'max_size', 'width': 1000},
      ]),
    );
    expect(results, hasLength(4));
    for (final result in results) {
      expect(result.passed, isFalse);
      expect(result.message, 'anchor not found');
    }
  });

  testWidgets('an unknown check fails and says so', (tester) async {
    await pumpFixture(tester);
    final result = await check(tester, 'label', {'type': 'sparkles'});
    expect(result.passed, isFalse);
    expect(result.message, contains('unknown check'));
  });
}

class _Fixture extends StatelessWidget {
  const _Fixture();

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Colors.white,
    child: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: 400,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(
              width: 300,
              child: Row(
                key: ValueKey<String>('overflow'),
                children: [SizedBox(width: 200), SizedBox(width: 200)],
              ),
            ),
            const SizedBox(
              width: 300,
              child: Row(
                key: ValueKey<String>('fits'),
                children: [SizedBox(width: 100), SizedBox(width: 100)],
              ),
            ),
            const SizedBox(
              width: 100,
              child: Text(
                'A long title that does not fit',
                key: ValueKey<String>('cut'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const Text(
              'Save changes',
              key: ValueKey<String>('label'),
              style: TextStyle(color: Colors.black),
            ),
            const Text(
              'Faint',
              key: ValueKey<String>('faint'),
              style: TextStyle(color: Color(0xFFEEEEEE)),
            ),
            const SizedBox(
              key: ValueKey<String>('small'),
              width: 24,
              height: 24,
            ),
            SizedBox(
              width: 100,
              height: 20,
              child: OverflowBox(
                alignment: Alignment.topLeft,
                maxWidth: 120,
                child: Container(
                  key: const ValueKey<String>('sticks_out'),
                  width: 120,
                  height: 10,
                  color: Colors.red,
                ),
              ),
            ),
            SizedBox(
              width: 100,
              height: 20,
              child: Center(
                child: Container(
                  key: const ValueKey<String>('inside'),
                  width: 50,
                  height: 10,
                  color: Colors.green,
                ),
              ),
            ),
            const Row(
              children: [
                SizedBox(key: ValueKey<String>('first'), width: 20, height: 20),
                SizedBox(width: 16),
                SizedBox(
                  key: ValueKey<String>('second'),
                  width: 20,
                  height: 20,
                ),
              ],
            ),
            IconButton(
              key: const ValueKey<String>('tiny_button'),
              onPressed: () {},
              icon: const Icon(Icons.add, size: 16),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 24, height: 24),
              style: IconButton.styleFrom(
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
            const Offstage(
              child: Text('Hidden', key: ValueKey<String>('offstage')),
            ),
          ],
        ),
      ),
    ),
  );
}
