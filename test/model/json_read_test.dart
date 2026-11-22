import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/model/json_read.dart';

void main() {
  group('plain reads', () {
    test('a wrong type gives the fallback', () {
      expect(asJsonMap('x'), isEmpty);
      expect(asJsonList(1), isEmpty);
      expect(asString(1), isNull);
      expect(asInt(1.5), isNull);
      expect(asDouble('1'), isNull);
      expect(asDate(5), isNull);
      expect(asStrings(null), isEmpty);
      expect(asStringMap([]), isEmpty);
    });

    test('a right type is read', () {
      expect(asJsonMap({'a': 1}), {'a': 1});
      expect(asJsonList([1]), [1]);
      expect(asString('a'), 'a');
      expect(asInt(3), 3);
      expect(asDouble(3), 3.0);
      expect(asDate('2026-11-22T10:00:00Z'), DateTime.utc(2026, 11, 22, 10));
      expect(asDate('not a date'), isNull);
    });

    test('an empty string is not a non-empty string', () {
      expect(nonEmptyString(''), isNull);
      expect(nonEmptyString('a'), 'a');
      expect(asString(''), '');
    });

    test('collections keep only the string entries', () {
      expect(asStrings(['a', 1, 'b', null]), ['a', 'b']);
      expect(asStringMap({'a': 'x', 'b': 1}), {'a': 'x'});
    });

    test('numbers print as JSON writes them', () {
      expect(jsonNumberText(96.0), '96');
      expect(jsonNumberText(1.5), '1.5');
      expect(jsonNumberText(7), '7');
      expect(jsonNumberText(double.nan), isNull);
      expect(jsonNumberText('7'), isNull);
    });
  });

  group('JsonRead', () {
    final json = <String, Object?>{
      'id': 'a',
      'at': '2026-11-22T10:00:00Z',
      'env': {'k': 1},
      'empty': <String, Object?>{},
      'rows': [1, 'two', 3],
    };

    test('str and date read one key', () {
      expect(json.str('id'), 'a');
      expect(json.str('at'), '2026-11-22T10:00:00Z');
      expect(json.str('none'), isNull);
      expect(json.date('at'), DateTime.utc(2026, 11, 22, 10));
    });

    test('nonEmptyMap needs entries and passes the guard', () {
      expect(json.nonEmptyMap('env'), {'k': 1});
      expect(json.nonEmptyMap('empty'), isNull);
      expect(json.nonEmptyMap('id'), isNull);
      expect(json.nonEmptyMap('env', where: (m) => m['z'] != null), isNull);
    });

    test('items drops what the parser rejects', () {
      expect(json.items('rows', asString), ['two']);
      expect(json.items('none', asString), isEmpty);
    });
  });
}
