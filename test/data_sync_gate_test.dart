import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/window_frame.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/utils/data_sync.dart';

void main() {
  testWidgets('disabled automatic uploads do not start or create backups', (
    tester,
  ) async {
    final root = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('sync-gate-'),
    ))!;
    App.dataPath = root.path;
    App.cachePath = root.path;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async => call.method == 'isMaximized' ? false : null,
    );
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: App.rootNavigatorKey,
        builder: (context, child) => WindowFrame(child!),
        home: const SizedBox(),
      ),
    );
    appdata.settings['webdav'] = ['http://127.0.0.1:1', 'fixture', 'fixture'];
    appdata.implicitData['webdavAutoSync'] = false;
    appdata.settings['dataVersion'] = 100;
    final sync = DataSync();
    var notifications = 0;
    void onChange() => notifications++;
    sync.addListener(onChange);
    for (var i = 0; i < 30; i++) {
      expect((await sync.uploadData()).success, isTrue);
    }
    expect(sync.isUploading, isFalse);
    expect(sync.uploadQueued, isFalse);
    expect(notifications, 0);
    expect(appdata.settings['dataVersion'], 100);
    expect(root.listSync(), isEmpty);
    await tester.pump(const Duration(seconds: 2));
    expect(tester.takeException(), isNull);
    sync.removeListener(onChange);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => root.delete(recursive: true));
  });
}
