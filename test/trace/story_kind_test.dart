import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/trace/story.dart';

void main() {
  test('a cause keeps its kind through JSON', () {
    for (final kind in StoryKind.values) {
      final cause = StoryCause(kind: kind, label: 'x', id: 3);
      final copy = StoryCause.fromJson(cause.toJson());
      expect(copy.kind, kind);
      expect(cause.toJson()['kind'], kind.name);
    }
  });

  test('a missing or unknown kind reads as other', () {
    expect(StoryCause.fromJson(const {}).kind, StoryKind.other);
    expect(StoryCause.fromJson(const {'kind': 'warp'}).kind, StoryKind.other);
  });

  test('only hover is folded as hover', () {
    expect(
      [
        for (final k in StoryKind.values)
          if (k.isHover) k,
      ],
      [StoryKind.hover],
    );
  });
}
