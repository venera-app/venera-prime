import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/favorites.dart';

void main() {
  test('rejects oversized imported favorite fields', () {
    expect(
      () => FavoriteItem.fromJson({
        'id': 'id',
        'name': List<String>.filled(1024 * 1024 + 1, 'n').join(),
        'author': '',
        'coverPath': '',
        'type': 0,
        'tags': <String>[],
      }),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => FavoriteItem.fromJson({
        'id': 'id',
        'name': 'name',
        'author': '',
        'coverPath': '',
        'type': 0,
        'tags': List<String>.filled(257, 'tag'),
      }),
      throwsA(isA<FormatException>()),
    );
  });
}
