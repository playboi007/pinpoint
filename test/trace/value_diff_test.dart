import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/trace/value_diff.dart';

/// PLAN-v3 Milestone 21b, row "Show only changed fields": the diff of two
/// values in a few words, for any kind of value.
void main() {
  String diff(Object? before, Object? after, {bool same = false}) =>
      diffValues(snapshotOf(before), snapshotOf(after), sameObject: same);

  test('a record: only the changed field, with its name', () {
    expect(
      diff((focused: false, open: true), (focused: true, open: true)),
      'focused false → true',
    );
    expect(diff((1, 'a'), (2, 'a')), '0 1 → 2');
  });

  test(
    'Name(a: 1, b: 2): changed fields only, at most five, then "+N more"',
    () {
      expect(diff(_Pair(1, 2), _Pair(1, 3)), 'b 2 → 3');
      final many = diffValues(
        snapshotOf(_Many([for (var i = 0; i < 8; i++) 0])),
        snapshotOf(_Many([for (var i = 0; i < 8; i++) 1])),
      );
      expect('→'.allMatches(many), hasLength(5));
      expect(many, endsWith('+3 more'));
    },
  );

  test('nested brackets and strings do not break the field split', () {
    expect(
      diff(
        _Raw("Cart(items: [1, 2], note: 'a, b')"),
        _Raw("Cart(items: [1, 2], note: 'a, c')"),
      ),
      "note 'a, b' → 'a, c'",
    );
  });

  test('lists: the length and the changed indexes', () {
    expect(diff([1, 2, 3], [1, 2, 3, 4]), 'length 3 → 4');
    expect(diff([1, 2, 3], [1, 9, 3]), 'length 3, changed [1]');
    expect(diff([1, 2, 3], [1, 9, 3, 7]), 'length 3 → 4, changed [1]');
    final long = [for (var i = 0; i < 9; i++) i];
    final changed = [for (var i = 0; i < 9; i++) i + 1];
    expect(
      diff(long, changed),
      'length 9, changed [0], [1], [2], [3], [4] +4 more',
    );
  });

  test('maps: the length and the changed, added and removed keys', () {
    expect(
      diff({'a': 1, 'b': 2}, {'a': 1, 'b': 3, 'c': 4}),
      'length 2 → 3, changed b, added c',
    );
    expect(diff({'a': 1, 'b': 2}, {'a': 1}), 'length 2 → 1, removed b');
  });

  test('the same list changed in place: "changed in place", with the '
      'difference when a snapshot of it was kept', () {
    final list = [1, 2];
    final before = snapshotOf(list);
    list.add(3);
    expect(
      diffValues(before, snapshotOf(list), sameObject: true),
      'changed in place: length 2 → 3',
    );
    // A snapshot that equals the new one says only that.
    expect(
      diffValues(snapshotOf(list), snapshotOf(list), sameObject: true),
      'changed in place',
    );
  });

  test('a new object with the same value says so', () {
    expect(diff([1, 2], [1, 2]), 'new object, same value');
    expect(diff(_Pair(1, 2), _Pair(1, 2)), 'new object, same value');
  });

  test('an object whose toString says nothing: "changed (Foo)"', () {
    expect(diff(_Opaque(), _Opaque()), 'changed (_Opaque)');
    final o = _Opaque();
    expect(diff(o, o, same: true), 'changed in place (_Opaque)');
  });

  test('scalars and text: before and after, clipped', () {
    expect(diff(1, 2), '1 → 2');
    expect(diff(true, false), 'true → false');
    expect(diff('a', 'b'), "'a' → 'b'");
    final long = diff('x' * 100, 'y' * 100);
    expect(long.length, lessThan(100));
    expect(long, contains('…'));
  });

  test('secrets are masked: a masked owner, a masked field, a masked key', () {
    final owner = snapshotOf('abc', owner: 'tokenNotifier');
    expect(owner.text, '***');
    // A secret field that changed still shows as changed, never its value.
    final a = snapshotOf(_Raw('Login(user: bob, apiKey: one)'));
    final b = snapshotOf(_Raw('Login(user: bob, apiKey: two)'));
    expect(diffValues(a, b), 'apiKey *** → ***');
    expect(a.text, isNot(contains('one')));
    expect(
      diffValues(a, snapshotOf(_Raw('Login(user: bob, apiKey: one)'))),
      'new object, same value',
    );
    final map = snapshotOf({'accessToken': 'abc', 'name': 'n'});
    expect(map.fields!['accessToken'], '***');
    expect(map.fields!['name'], "'n'");
    final fields = snapshotOf(_Raw('Login(user: bob, apiKey: abc)'));
    expect(fields.fields!['apiKey'], '***');
    expect(fields.fields!['user'], 'bob');
  });

  test('a toString that throws never throws out of the lens', () {
    final snap = snapshotOf(_Throws());
    expect(snap.text, contains('_Throws'));
  });

  test('parseFields refuses text that is not a constructor call', () {
    expect(parseFields('hello'), isNull);
    expect(parseFields('Foo(a: 1'), isNull);
    expect(parseFields('Foo()'), isNull);
    expect(parseFields('Foo(a: 1, b: (2, 3))'), {'a': '1', 'b': '(2, 3)'});
  });
}

class _Pair {
  _Pair(this.a, this.b);
  final int a;
  final int b;
  @override
  String toString() => '_Pair(a: $a, b: $b)';
}

class _Many {
  _Many(this.values);
  final List<int> values;
  @override
  String toString() =>
      '_Many(${[for (var i = 0; i < values.length; i++) 'f$i: ${values[i]}'].join(', ')})';
}

class _Raw {
  _Raw(this.text);
  final String text;
  @override
  String toString() => text;
}

class _Opaque {}

class _Throws {
  @override
  String toString() => throw StateError('no');
}
