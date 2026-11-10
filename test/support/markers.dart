import 'dart:io';

/// The 1-based line that `// PIN:<marker>` names in [file] (relative to the
/// package root, where `flutter test` runs): its own line, or the next line
/// when the marker stands alone (the formatter moves a comment written after
/// an opening parenthesis, so put it above the call instead).
///
/// Tests compare resolved locations with this, so editing a fixture does not
/// break them.
int markerLine(String file, String marker) {
  // `\b`, so `save_bar` does not match `save_bar_padding`.
  final pattern = RegExp('// PIN:${RegExp.escape(marker)}\\b');
  final lines = File(file).readAsLinesSync();
  final index = lines.indexWhere(pattern.hasMatch);
  if (index < 0) throw StateError('marker PIN:$marker not found in $file');
  if (lines.indexWhere(pattern.hasMatch, index + 1) >= 0) {
    throw StateError('marker PIN:$marker is not unique in $file');
  }
  final alone = lines[index].trimLeft().startsWith('//');
  return alone ? index + 2 : index + 1;
}

const String saveBarFixture = 'test/fixtures/save_bar_fixture.dart';
const String generatedFixture = 'test/fixtures/generated_fixture.g.dart';

/// The 1-based column of [code] on the line that `// PIN:<marker>` names
/// in [file].
int markerColumn(String file, String marker, String code) {
  final line = File(file).readAsLinesSync()[markerLine(file, marker) - 1];
  final index = line.indexOf(code);
  if (index < 0) throw StateError('$code not on the line of PIN:$marker');
  return index + 1;
}

const String annotationFixture = 'test/fixtures/annotation_fixture.dart';
