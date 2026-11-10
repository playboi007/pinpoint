import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Session 0 spike: read one real creation location through the inspector
/// serializer, the way `source_resolver.dart` will (PLAN.md, Milestone 3).
///
/// The expected line is found through a marker comment, so editing this file
/// does not break the test.
const String _thisFile = 'test/source/spike_location_test.dart';
const String _marker = 'PIN:spike_text';

void main() {
  testWidgets('Text creation location names this file and the marker line', (
    tester,
  ) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Text('spike'), // PIN:spike_text
      ),
    );

    final service = WidgetInspectorService.instance;
    expect(service.isWidgetCreationTracked(), isTrue);

    final element = tester.element(find.text('spike'));
    final json = element.toDiagnosticsNode().toJsonMap(
      InspectorSerializationDelegate(
        service: service,
        subtreeDepth: 0,
        includeProperties: false,
      ),
    );
    final location = json['creationLocation']! as Map<Object?, Object?>;

    final file = location['file']! as String;
    final line = location['line']! as int;
    final column = location['column']! as int;
    // Recorded for docs/api-notes.md: the raw shape of `file` on this platform.
    debugPrint('creationLocation: $location');

    final expectedLine = File(_thisFile)
        .readAsLinesSync()
        .indexWhere((l) => l.contains('// $_marker')) +
        1;
    expect(expectedLine, greaterThan(0), reason: 'marker not found');

    expect(Uri.parse(file).path, endsWith(_thisFile));
    expect(line, expectedLine);
    expect(column, greaterThan(0));
    expect(json['createdByLocalProject'], isTrue);
  });
}
