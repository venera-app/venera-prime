import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';

void main() {
  test('dynamic scalar settings keep their original descriptor', () {
    final result = ComicSource.mergeDynamicSettings(
      {
        'base_url': {
          'title': 'API address',
          'type': 'input',
          'default': 'old.example.com',
        },
      },
      {'base_url': 'new.example.com'},
    );

    expect(result['base_url'], {
      'title': 'API address',
      'type': 'input',
      'default': 'new.example.com',
    });
  });

  test(
    'dynamic setting descriptors are preserved and unknown scalars ignored',
    () {
      final result = ComicSource.mergeDynamicSettings(
        {
          'mode': {'type': 'select', 'default': 'a'},
        },
        {
          'mode': {'type': 'select', 'default': 'b'},
          'unknown': 'value',
        },
      );

      expect(result['mode'], {'type': 'select', 'default': 'b'});
      expect(result.containsKey('unknown'), isFalse);
    },
  );
}
