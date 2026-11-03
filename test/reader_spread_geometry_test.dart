import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/reader_spread_geometry.dart';

void main() {
  test(
    'unequal pages share height, preserve proportions and meet at the seam',
    () {
      for (final viewport in [const Size(1000, 600), const Size(600, 1000)]) {
        final rects = readerSpreadRects(viewport, [
          const Size(300, 600),
          const Size(510, 600),
        ]);
        expect(rects[0].height, closeTo(rects[1].height, 1e-8));
        expect(rects[0].top, rects[1].top);
        expect(rects[0].right, closeTo(rects[1].left, 1e-8));
        expect(rects[0].width / rects[0].height, closeTo(.5, 1e-8));
        expect(rects[1].width / rects[1].height, closeTo(.85, 1e-8));
        for (final rect in rects) {
          expect(rect.left, greaterThanOrEqualTo(-1e-8));
          expect(rect.right, lessThanOrEqualTo(viewport.width + 1e-8));
          expect(rect.height, lessThanOrEqualTo(viewport.height));
        }
      }
    },
  );

  test(
    'cover blanks match the actual page and wide artwork uses both slots',
    () {
      const viewport = Size(1000, 600);
      final cover = readerSpreadRects(viewport, [null, const Size(400, 600)]);
      expect(cover[0].size, cover[1].size);
      final wide = readerSpreadRects(viewport, [const Size(1200, 600)]).single;
      expect(wide.width, 1000);
      expect(wide.height, 500);
    },
  );

  test('unknown and invalid sizes have finite placeholders', () {
    for (final size in [null, Size.zero, const Size(double.infinity, 600)]) {
      final rects = readerSpreadRects(const Size(1000, 600), [size, null]);
      expect(rects, hasLength(2));
      expect(rects.every((rect) => rect.isFinite && !rect.isEmpty), isTrue);
    }
    expect(readerSpreadRects(Size.zero, [null]), isEmpty);
  });

  test('width detection is conservative and rejects invalid metadata', () {
    expect(isWideReaderImage(const Size(2000, 1500)), isTrue);
    expect(isWideReaderImage(const Size(1000, 1500)), isFalse);
    expect(isWideReaderImage(const Size(1000, 1000)), isFalse);
    expect(isWideReaderImage(Size.zero), isFalse);
  });
}
