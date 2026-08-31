import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
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
}
