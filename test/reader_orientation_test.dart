import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/reader_orientation.dart';

void main() {
  group('ReaderOrientationMode', () {
    test('cycles through automatic, portrait, and landscape', () {
      expect(
        ReaderOrientationMode.automatic.next,
        ReaderOrientationMode.portrait,
      );
      expect(
        ReaderOrientationMode.portrait.next,
        ReaderOrientationMode.landscape,
      );
      expect(
        ReaderOrientationMode.landscape.next,
        ReaderOrientationMode.automatic,
      );
    });
  });

  group('ReaderOrientationMemory', () {
    test('stores one global reader orientation', () {
      final data = <String, dynamic>{};

      ReaderOrientationMemory.rememberInData(
        data,
        comicId: 'comic-a',
        sourceKey: 'source-a',
        mode: ReaderOrientationMode.landscape,
        perComic: false,
      );

      expect(
        ReaderOrientationMemory.modeFromData(
          data,
          comicId: 'comic-b',
          sourceKey: 'source-b',
          perComic: false,
        ),
        ReaderOrientationMode.landscape,
      );
    });

    test('keeps orientations isolated by source and comic', () {
      final data = <String, dynamic>{};

      ReaderOrientationMemory.rememberInData(
        data,
        comicId: 'same-id',
        sourceKey: 'source-a',
        mode: ReaderOrientationMode.portrait,
        perComic: true,
      );
      ReaderOrientationMemory.rememberInData(
        data,
        comicId: 'same-id',
        sourceKey: 'source-b',
        mode: ReaderOrientationMode.landscape,
        perComic: true,
      );

      expect(
        ReaderOrientationMemory.modeFromData(
          data,
          comicId: 'same-id',
          sourceKey: 'source-a',
          perComic: true,
        ),
        ReaderOrientationMode.portrait,
      );
      expect(
        ReaderOrientationMemory.modeFromData(
          data,
          comicId: 'same-id',
          sourceKey: 'source-b',
          perComic: true,
        ),
        ReaderOrientationMode.landscape,
      );
      expect(
        ReaderOrientationMemory.modeFromData(
          data,
          comicId: 'not-read-yet',
          sourceKey: 'source-a',
          perComic: true,
        ),
        ReaderOrientationMode.automatic,
      );
    });

    test('source and comic IDs cannot collide at separator characters', () {
      final data = <String, dynamic>{};

      ReaderOrientationMemory.rememberInData(
        data,
        comicId: 'comic@source-b',
        sourceKey: 'source-a',
        mode: ReaderOrientationMode.portrait,
        perComic: true,
      );
      ReaderOrientationMemory.rememberInData(
        data,
        comicId: 'comic',
        sourceKey: 'source-b@source-a',
        mode: ReaderOrientationMode.landscape,
        perComic: true,
      );

      expect(
        ReaderOrientationMemory.modeFromData(
          data,
          comicId: 'comic@source-b',
          sourceKey: 'source-a',
          perComic: true,
        ),
        ReaderOrientationMode.portrait,
      );
      expect(
        ReaderOrientationMemory.modeFromData(
          data,
          comicId: 'comic',
          sourceKey: 'source-b@source-a',
          perComic: true,
        ),
        ReaderOrientationMode.landscape,
      );
    });

    test('automatic mode removes obsolete stored values', () {
      final data = <String, dynamic>{};

      ReaderOrientationMemory.rememberInData(
        data,
        comicId: 'comic-a',
        sourceKey: 'source-a',
        mode: ReaderOrientationMode.portrait,
        perComic: true,
      );
      ReaderOrientationMemory.rememberInData(
        data,
        comicId: 'comic-a',
        sourceKey: 'source-a',
        mode: ReaderOrientationMode.automatic,
        perComic: true,
      );

      expect(data.containsKey(ReaderOrientationMemory.comicModesKey), isFalse);
    });
  });
}
