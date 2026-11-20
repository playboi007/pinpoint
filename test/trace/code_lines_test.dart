import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/trace/code_lines.dart';

void main() {
  const text = '''void fetchDialog() {
  // Both flags for the dialog.
  _dialogLoading = true;

  _loading = true;
  notifyListeners();
}''';

  test('the last lines up to the line, without comments and blanks', () {
    expect(codeLinesAt(text, 10, 15), [
      '_dialogLoading = true;',
      '_loading = true;',
      'notifyListeners();',
    ]);
  });

  test('takes at most max lines, the header included when in range', () {
    expect(codeLinesAt(text, 10, 15, max: 6), [
      'void fetchDialog() {',
      '_dialogLoading = true;',
      '_loading = true;',
      'notifyListeners();',
    ]);
    expect(codeLinesAt(text, 10, 15, max: 1), ['notifyListeners();']);
  });

  test('a line outside the text is clamped, lone brackets are left out', () {
    expect(codeLinesAt(text, 10, 99, max: 2), ['notifyListeners();']);
    expect(isCodeLine('  });'), isFalse);
    expect(isCodeLine('  * doc'), isFalse);
  });
}
