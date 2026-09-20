import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_type.dart';

void main() {
  test('sourceKey falls back when the source is not loaded', () {
    const comicType = ComicType(123456789);

    expect(comicType.comicSource, isNull);
    expect(comicType.sourceKey, 'Unknown:123456789');
  });

  test('sourceKey stays local for local comics', () {
    expect(ComicType.local.sourceKey, 'local');
  });
}
