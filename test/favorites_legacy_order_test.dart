import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/favorites.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('legacy missing and tied folder orders survive reopening', () async {
    final directory = await Directory.systemTemp.createTemp('legacy-order-');
    App.dataPath = directory.path;
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => directory.path);
    final manager = LocalFavoritesManager();
    manager.close();
    addTearDown(() async {
      manager.close();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      await directory.delete(recursive: true);
    });
    await manager.init();
    final folders = List.generate(64, (i) => 'Folder ${63 - i}');
    for (final folder in folders) {
      manager.createFolder(folder);
    }
    manager.close();
    final db = sqlite3.open('${directory.path}/local_favorite.db');
    db.execute('DELETE FROM folder_order');
    // Older databases may only have order records for some folders.
    for (final folder in folders.take(32)) {
      db.execute('INSERT INTO folder_order VALUES (?, 0)', [folder]);
    }
    db.dispose();
    await manager.init();
    expect(manager.folderNames, folders);
    final reordered = folders.reversed.toList();
    manager.updateOrder(reordered);
    manager.close();
    await manager.init();
    expect(manager.folderNames, reordered);
  });
}
