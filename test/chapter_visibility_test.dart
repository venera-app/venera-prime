import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/utils/chapter_visibility.dart';

void main() {
  test('maps grouped duplicate chapters to their original indexes', () {
    const chapters = ComicChapters.grouped({
      'volume-1': {'same-id': ' Bonus '},
      'volume-2': {'same-id': 'bonus'},
    });

    expect(ChapterVisibility.grouped(chapters, hideDuplicates: true), [
      [0],
      <int>[],
    ]);
    expect(ChapterVisibility.grouped(chapters, hideDuplicates: false), [
      [0],
      [0],
    ]);
  });
}
