import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/data_sync.dart';

void main() {
  test('orders backup revisions before device dates across digit changes', () {
    final names = [
      '20000-9.venera',
      '20000-10.venera',
      '9999-99999.venera',
      '20000-3687.venera',
      '20000-10000.venera',
      '20000-9999.venera',
    ]..sort(compareBackupNames);
    expect(names, [
      '20000-9.venera',
      '20000-10.venera',
      '20000-3687.venera',
      '20000-9999.venera',
      '20000-10000.venera',
      '9999-99999.venera',
    ]);
  });

  test('clock rollback cannot hide or prune a newer revision', () {
    expect(
      compareBackupNames('20000-11.venera', '20001-10.venera'),
      greaterThan(0),
    );
    expect(nextBackupVersion(8, ['20001-10.venera']), 11);
    final prune = backupFilesToPrune(
      existingNames: [
        '20001-10.venera',
        for (var i = 11; i <= 19; i++) '20000-$i.venera',
      ],
      dayPrefix: '19999-',
      uploadedFilename: '19999-20.venera',
    );
    expect(prune, ['20001-10.venera']);
  });

  test('a device importing version 3687 advances past other devices', () {
    expect(nextBackupVersion(3687, ['20000-4000.venera']), 4001);
    expect(nextBackupVersion(5000, ['20000-4000.venera']), 5001);
  });

  test('concurrent snapshots with equal counters have a stable order', () {
    expect(
      compareBackupNames('20000-8-0001-a.venera', '20000-8-0002-b.venera'),
      lessThan(0),
    );
    expect(nextBackupVersion(7, ['20000-8-0002-b.venera']), 9);
  });

  test('pruning keeps equal-counter and newer concurrent snapshots', () {
    expect(
      backupFilesToPrune(
        existingNames: [
          '20000-7.venera',
          '20000-8-0001-a.venera',
          '20000-9-0003-c.venera',
        ],
        dayPrefix: '20000-',
        uploadedFilename: '20000-8-0002-b.venera',
      ),
      ['20000-7.venera'],
    );
  });

  test(
    'does not prune the file just uploaded when its name already exists',
    () {
      final prune = backupFilesToPrune(
        existingNames: ['20000-4.venera', '20000-5.venera', '19999-9.venera'],
        dayPrefix: '20000-',
        uploadedFilename: '20000-5.venera',
      );

      expect(prune, ['20000-4.venera']);
      expect(prune, isNot(contains('20000-5.venera')));
    },
  );

  test('prunes the oldest remaining backup only when over the limit', () {
    final prune = backupFilesToPrune(
      existingNames: [
        '19990-1.venera',
        '19991-1.venera',
        '19992-1.venera',
        '19993-1.venera',
        '19994-1.venera',
        '19995-1.venera',
        '19996-1.venera',
        '19997-1.venera',
        '19998-1.venera',
        '19999-1.venera',
      ],
      dayPrefix: '20000-',
      uploadedFilename: '20000-1.venera',
    );

    expect(prune, ['19990-1.venera']);
    expect(prune, isNot(contains('20000-1.venera')));
  });

  test(
    'prunes every excess backup when the existing set is over the limit',
    () {
      final prune = backupFilesToPrune(
        existingNames: List.generate(
          11,
          (index) => '${19989 + index}-1.venera',
        ),
        dayPrefix: '20000-',
        uploadedFilename: '20000-1.venera',
      );

      expect(prune, ['19989-1.venera', '19990-1.venera']);
    },
  );

  test('retains prior files when ten or fewer remain after upload', () {
    final prune = backupFilesToPrune(
      existingNames: List.generate(9, (index) => '1999$index-1.venera'),
      dayPrefix: '20000-',
      uploadedFilename: '20000-1.venera',
    );

    expect(prune, isEmpty);
  });
}
