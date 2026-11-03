import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/reader_page_layout.dart';

void main() {
  test('wide images break pairs without skipping adjacent pages', () {
    final layout = ReaderPageLayout(
      imageCount: 9,
      imagesPerPage: 2,
      singleCover: false,
      standaloneImages: {1, 2, 6},
    );
    expect(
      [for (var p = 1; p <= layout.pageCount; p++) layout.range(p)],
      [(0, 1), (1, 2), (2, 3), (3, 5), (5, 6), (6, 7), (7, 9)],
    );
    for (var image = 1; image <= 9; image++) {
      final (start, end) = layout.range(layout.pageForImage(image));
      expect(image - 1, inInclusiveRange(start, end - 1));
    }
  });

  test(
    'explicit cross-page pairs override width detection and cover parity',
    () {
      final layout = ReaderPageLayout(
        imageCount: 7,
        imagesPerPage: 2,
        singleCover: true,
        standaloneImages: {0, 2, 3},
        joinedPairs: {0, 2},
      );
      expect(
        [for (var p = 1; p <= layout.pageCount; p++) layout.range(p)],
        [(0, 2), (2, 4), (4, 6), (6, 7)],
      );
    },
  );

  test('manual shift makes a boundary after native spreads', () {
    final layout = ReaderPageLayout(
      imageCount: 8,
      imagesPerPage: 2,
      singleCover: false,
      standaloneImages: {1},
      anchor: 5,
    );
    expect(layout.range(layout.pageForImage(6)), (5, 7));
  });

  test('mixed spreads cover every source image exactly once', () {
    for (var count = 1; count <= 8; count++) {
      for (var mask = 0; mask < 1 << count; mask++) {
        for (final cover in [false, true]) {
          final layout = ReaderPageLayout(
            imageCount: count,
            imagesPerPage: 2,
            singleCover: cover,
            standaloneImages: {
              for (var i = 0; i < count; i++)
                if ((mask & (1 << i)) != 0) i,
            },
          );
          final indices = <int>[];
          for (var p = 1; p <= layout.pageCount; p++) {
            final (start, end) = layout.range(p);
            expect(end - start, inInclusiveRange(1, 2));
            for (var i = start; i < end; i++) {
              expect(layout.pageForImage(i + 1), p);
              indices.add(i);
              if (layout.standaloneImages.contains(i)) expect(end - start, 1);
            }
          }
          expect(indices, List.generate(count, (i) => i));
        }
      }
    }
  });

  test('single-image shifts retain reading order and cover every image', () {
    for (final count in [1, 2, 3, 5, 14, 30]) {
      for (final perPage in [1, 2, 4, 8]) {
        for (final cover in [true, false]) {
          final base = ReaderPageLayout(
            imageCount: count,
            imagesPerPage: perPage,
            singleCover: cover,
          );
          for (var target = 0; target < count; target++) {
            final layout = ReaderPageLayout(
              imageCount: count,
              imagesPerPage: perPage,
              singleCover: cover,
              offset: base.offsetForStart(target),
            );
            expect(layout.range(layout.pageForImage(target + 1)).$1, target);
            final indices = <int>[];
            for (var page = 1; page <= layout.pageCount; page++) {
              final (start, end) = layout.range(page);
              expect(end, greaterThan(start));
              expect(end - start, lessThanOrEqualTo(perPage));
              indices.addAll(List.generate(end - start, (i) => start + i));
            }
            expect(indices, List.generate(count, (i) => i));
          }
        }
      }
    }
  });
}
