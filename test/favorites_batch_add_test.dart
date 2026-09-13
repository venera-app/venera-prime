import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('batch add gives a large-folder listener one complete update', () async {
    final directory = await Directory.systemTemp.createTemp(
      'venera-favorites-batch-',
    );
    App.dataPath = directory.path;
    const pathProviderChannel = MethodChannel(
      'plugins.flutter.io/path_provider',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          pathProviderChannel,
          (_) async => directory.path,
        );

    final manager = LocalFavoritesManager();
    manager.close();
    await manager.init();
    manager.createFolder('Synced');

    FavoriteItem comic(int index) => FavoriteItem(
      id: 'comic-$index',
      name: 'Comic $index',
      coverPath: 'cover-$index',
      author: 'Author',
      type: const ComicType(123),
      tags: const ['language:english'],
    );
    final existingComics = List.generate(501, comic);
    expect(manager.addComics('Synced', existingComics), 501);

    var notifications = 0;
    Future<List<FavoriteItem>>? refreshedComics;
    void listener() {
      notifications++;
      refreshedComics = manager.getFolderComicsAsync('Synced');
    }

    manager.addListener(listener);
    final newComics = List.generate(
      30,
      (index) => FavoriteItem(
        id: 'new-comic-$index',
        name: 'New Comic $index',
        coverPath: 'new-cover-$index',
        author: 'New Author',
        type: const ComicType(123),
        tags: const [],
      ),
    );

    expect(manager.addComics('Synced', newComics), 30);
    expect(manager.folderComics('Synced'), 531);
    expect(await refreshedComics, hasLength(531));
    expect(notifications, 1);

    expect(manager.addComics('Synced', newComics), 0);
    expect(manager.folderComics('Synced'), 531);
    expect(notifications, 1);

    manager.removeListener(listener);
    manager.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);
    await directory.delete(recursive: true);
  });
}
