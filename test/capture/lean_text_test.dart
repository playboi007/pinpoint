import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/capture/lean_text.dart';

/// PLAN-v3 Milestone 19, step 8: property text with no hash codes and no
/// empty parts.
void main() {
  test('removes the hash code after a type name', () {
    expect(leanText('Text#8f3a2("Save")'), 'Text("Save")');
    expect(
      leanText('EdgeInsets.all(8.0) and Key#12ab3'),
      'EdgeInsets.all(8.0) and Key',
    );
  });

  test('keeps a colour, which is # and six hex digits', () {
    expect(leanText('Color(#ff0000)'), 'Color(#ff0000)');
    expect(leanText('#ff0000'), '#ff0000');
  });

  test('removes parts with no value, at any depth', () {
    expect(
      leanText(
        'ButtonStyle#d3507(textStyle: WidgetStatePropertyAll(null), '
        'padding: WidgetStatePropertyAll(EdgeInsets.all(8.0)), '
        'shape: null)',
      ),
      'ButtonStyle(padding: WidgetStatePropertyAll(EdgeInsets.all(8.0)))',
    );
    expect(
      leanText('Foo(a: null, b: 1, c: MaterialStatePropertyAll(null))'),
      'Foo(b: 1)',
    );
    expect(leanText('Foo(a: 1, b: null)'), 'Foo(a: 1)');
  });

  test('gives null when nothing is left of the value', () {
    expect(
      leanText(
        'ButtonStyle#d3507(textStyle: WidgetStatePropertyAll(null), '
        'shape: null)',
      ),
      isNull,
    );
  });

  test('leaves a text it did not change as it is, even with ()', () {
    expect(leanText('Container()'), 'Container()');
    expect(leanText('plain text'), 'plain text');
    expect(leanText('name: nullable'), 'name: nullable');
  });
}
