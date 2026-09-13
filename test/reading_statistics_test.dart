import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/reading_statistics.dart';

void main() {
  test('splits a reading session across local calendar days', () async {
    final directory = await Directory.systemTemp.createTemp(
      'venera-reading-statistics-',
    );
    App.dataPath = directory.path;
    final manager = ReadingStatisticsManager();
    manager.close();
    await manager.init();
    manager.recordSession(
      comic: const Comic(
        'Statistics comic',
        'cover',
        'same-id',
        'Author',
        [],
        '',
        'local',
        null,
        null,
      ),
      startedAt: DateTime(2026, 1, 1, 23, 59, 50),
      endedAt: DateTime(2026, 1, 2, 0, 0, 10),
    );

    expect(manager.durationForDay(DateTime(2026, 1, 1)), 10);
    expect(manager.durationForDay(DateTime(2026, 1, 2)), 10);
    expect(manager.totalDuration(), 20);
    expect(manager.recent(days: 365), hasLength(2));

    manager.close();
    await directory.delete(recursive: true);
  });

  test('pause, per-comic deletion, and clearing protect reading data', () async {
    final directory = await Directory.systemTemp.createTemp(
      'venera-reading-statistics-privacy-',
    );
    App.dataPath = directory.path;
    final manager = ReadingStatisticsManager();
    manager.close();
    appdata.settings['recordReadingStatistics'] = true;
    await manager.init();

    final now = DateTime.now();
    const first = Comic(
      'First comic',
      'cover',
      'first-id',
      'Author',
      [],
      '',
      'local',
      null,
      null,
    );
    const second = Comic(
      'Second comic',
      'cover',
      'second-id',
      'Author',
      [],
      '',
      'local',
      null,
      null,
    );

    manager.recordSession(
      comic: first,
      startedAt: now,
      endedAt: now.add(const Duration(seconds: 10)),
    );
    manager.recordSession(
      comic: second,
      startedAt: now,
      endedAt: now.add(const Duration(seconds: 20)),
    );
    expect(manager.totalDuration(), 30);

    manager.setRecordingEnabled(false);
    manager.recordSession(
      comic: first,
      startedAt: now,
      endedAt: now.add(const Duration(minutes: 1)),
    );
    expect(manager.totalDuration(), 30);

    manager.deleteComic('first-id', ComicType.local);
    expect(manager.totalDuration(), 20);
    expect(manager.recent().map((item) => item.comicId), ['second-id']);

    manager.clear();
    expect(manager.totalDuration(), 0);
    expect(manager.recent(), isEmpty);

    manager.setRecordingEnabled(true);
    await appdata.saveData(false);
    manager.close();
    await directory.delete(recursive: true);
  });
}
