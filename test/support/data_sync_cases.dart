import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/components/window_frame.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/background_tasks.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/read_later.dart';
import 'package:venera/foundation/reading_statistics.dart';
import 'package:venera/utils/data.dart';
import 'package:venera/utils/data_sync.dart';
import 'package:venera/pages/settings/settings_page.dart';
import 'test_translations.dart';

void registerDataSyncTransportTests({bool device = false}) {
  testWidgets(
    'WebDAV upload failure retains backups; success prunes only old files',
    (tester) async {
      await ensureTestTranslations();
      final previousLanguage = appdata.settings['language'];
      appdata.settings['language'] = 'en-US';
      addTearDown(() => appdata.settings['language'] = previousLanguage);
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('prime-webdav-'),
      ))!;
      App.dataPath = root.path;
      App.cachePath = '${root.path}/cache';
      Directory(App.cachePath).createSync();
      for (final name in ['history.db', 'local_favorite.db']) {
        sqlite3.open('${root.path}/$name').dispose();
      }
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('window_manager'),
        (call) async => call.method == 'isMaximized' ? false : null,
      );
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => root.path,
      );
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: App.rootNavigatorKey,
          builder: (context, child) => WindowFrame(child!),
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showWebdavSettings(context),
              child: const Text('Configure backup'),
            ),
          ),
        ),
      );
      final day = DateTime.now().millisecondsSinceEpoch ~/ 86400000;
      final oldName = '$day-1.venera';
      final existingName = '$day-102.venera';
      final remote = <String, List<int>>{
        oldName: utf8.encode('old backup'),
        existingName: utf8.encode('existing backup'),
      };
      final etags = <String, int>{};
      var provideEtags = true;
      final operations = <String>[];
      var rejectUpload = true;
      Completer<void>? putStarted;
      Completer<void>? putGate;
      Completer<void>? readStarted;
      Completer<void>? readGate;
      final server = (await tester.runAsync(
        () => HttpServer.bind(InternetAddress.loopbackIPv4, 0),
      ))!;
      final listener = (await tester.runAsync(
        () async => server.listen((request) async {
          final name = request.uri.pathSegments.lastOrNull ?? '';
          operations.add('${request.method} $name');
          final body = await request.fold<List<int>>(
            [],
            (all, bytes) => all..addAll(bytes),
          );
          switch (request.method) {
            case 'OPTIONS':
              request.response.statusCode = 200;
            case 'MKCOL':
              request.response.statusCode = 201;
            case 'PROPFIND':
              final gate = readGate;
              readGate = null;
              if (readStarted != null && !readStarted!.isCompleted) {
                readStarted!.complete();
              }
              await gate?.future;
              request.response.statusCode = 207;
              request.response.headers.contentType = ContentType(
                'application',
                'xml',
              );
              final entries = [
                '<d:response><d:href>/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>',
                for (final entry in remote.entries)
                  '<d:response><d:href>/${entry.key}</d:href><d:propstat><d:prop><d:resourcetype/>${provideEtags ? '<d:getetag>"${etags[entry.key] ?? 0}"</d:getetag>' : ''}<d:getcontentlength>${entry.value.length}</d:getcontentlength></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>',
              ];
              request.response.write(
                '<?xml version="1.0"?><d:multistatus xmlns:d="DAV:">${entries.join()}</d:multistatus>',
              );
            case 'PUT':
              final gate = putGate;
              putGate = null;
              if (putStarted != null && !putStarted!.isCompleted) {
                putStarted!.complete();
              }
              await gate?.future;
              if (rejectUpload) {
                request.response.statusCode = 507;
              } else {
                remote[name] = body;
                etags[name] = (etags[name] ?? 0) + 1;
                request.response.statusCode = 201;
              }
            case 'GET':
              final bytes = remote[name];
              request.response.statusCode = bytes == null ? 404 : 200;
              if (bytes != null) request.response.add(bytes);
            case 'DELETE':
              remote.remove(name);
              request.response.statusCode = 204;
            default:
              request.response.statusCode = 405;
          }
          await request.response.close();
        }),
      ))!;
      appdata.settings['proxy'] = 'direct';
      appdata.settings['webdav'] = [
        'http://127.0.0.1:${server.port}',
        'fixture-user',
        'fixture-password',
      ];
      appdata.settings['dataVersion'] = 100;
      appdata.implicitData['webdavAutoSync'] = false;
      final sync = DataSync();
      try {
        // Startup, settings writes and JS save_data must remain local when off.
        final source = ComicSource(
          'Fixture',
          'sync-fixture',
          null,
          null,
          null,
          null,
          [],
          null,
          null,
          null,
          null,
          null,
          null,
          null,
          '',
          '',
          '1',
          null,
          null,
          null,
          null,
          null,
          null,
          null,
          null,
          null,
          null,
          null,
          null,
          false,
          false,
          null,
          null,
        );
        await tester.runAsync(() async {
          for (var i = 0; i < 12; i++) {
            source.data['popunder_state'] = i;
            await source.saveData();
            await appdata.saveData();
            sync.onDataChanged();
            await sync.uploadData();
          }
          await Future<void>.delayed(const Duration(milliseconds: 200));
        });
        expect(operations, isEmpty);
        expect(appdata.settings['dataVersion'], 100);
        expect(sync.uploadQueued, isFalse);
        expect(Directory(App.cachePath).listSync(), isEmpty);
        expect(
          jsonDecode(
            File(
              '${root.path}/comic_source/sync-fixture.data',
            ).readAsStringSync(),
          )['popunder_state'],
          11,
        );
        // The settings action must transfer even when automatic sync is off.
        await tester.tap(find.text('Configure backup'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Continue'));
        await tester.pumpAndSettle();
        await tester.runAsync(() => tester.tap(find.text('Continue')));
        for (var i = 0; i < 300 && sync.isUploading; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)),
          );
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(operations.any((op) => op.startsWith('PUT ')), isTrue);
        expect(appdata.implicitData['webdavAutoSync'], isFalse);
        App.rootPop();
        await tester.pumpAndSettle();
        // Settings rollback persists on the widget clock. Drain its writes
        // before starting the next transfer on the real network clock.
        for (var i = 0; i < 10; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 30)),
          );
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(
          BackgroundTasks.instance.latest('webdav-upload')!.status,
          BackgroundTaskStatus.failed,
        );
        expect(remote.keys, unorderedEquals([oldName, existingName]));
        expect(appdata.settings['dataVersion'], 100);
        expect(operations.where((op) => op.startsWith('DELETE')), isEmpty);
        expect(sync.isUploading, isFalse);
        rejectUpload = false;
        operations.clear();
        final uploaded = await tester.runAsync(
          () =>
              sync.uploadData(force: true).timeout(const Duration(seconds: 15)),
        );
        expect(uploaded!.error, isFalse);
        expect(
          BackgroundTasks.instance.latest('webdav-upload')!.status,
          BackgroundTaskStatus.completed,
        );
        final newName = remote.keys.single;
        expect(newName, startsWith('$day-103-'));
        expect(appdata.settings['dataVersion'], 103);
        expect(remote[newName]!.take(2), [0x50, 0x4b]);
        expect(
          operations.indexOf('PUT $newName'),
          lessThan(operations.indexOf('DELETE $oldName')),
        );
        expect(operations, isNot(contains('DELETE $newName')));
        expect(sync.isUploading, isFalse);
        expect(sync.lastError, isNull);
        // Source requests repeatedly persist the same cookie/token. With auto
        // sync enabled those no-op saves must never start a backup or queue one.
        operations.clear();
        appdata.implicitData['webdavAutoSync'] = true;
        final versionBeforeNoOp = appdata.settings['dataVersion'];
        await tester.runAsync(() async {
          await Future.wait(List.generate(30, (_) => source.saveData()));
          await source.loadData();
          await source.saveData();
        });
        expect(operations, isEmpty);
        expect(appdata.settings['dataVersion'], versionBeforeNoOp);
        expect(sync.isUploading, isFalse);
        expect(sync.uploadQueued, isFalse);

        // Changing source tokens throughout overlapping checks uploads once,
        // after the outer batch finishes, including an exceptional exit.
        operations.clear();
        await tester.runAsync(() async {
          await sync.batchAutomaticUploads(() async {
            for (var i = 0; i < 8; i++) {
              source.data['batch-token'] = i;
              await source.saveData();
            }
            await expectLater(
              sync.batchAutomaticUploads(() async {
                await sync.uploadData();
                throw StateError('cancelled check fixture');
              }),
              throwsStateError,
            );
            expect(operations, isEmpty);
            expect(sync.isUploading, isFalse);
          });
          final deadline = DateTime.now().add(const Duration(seconds: 15));
          while (sync.isUploading || sync.uploadQueued) {
            if (DateTime.now().isAfter(deadline)) {
              fail('batch upload timed out');
            }
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
        });
        expect(operations.where((op) => op.startsWith('PUT ')), hasLength(1));
        expect(sync.lastError, isNull);

        // Hold the network transfer so overlapping saves are deterministic.
        Future<void> uploadBurst({
          required bool disable,
          required bool manual,
        }) async {
          operations.clear();
          appdata.implicitData['webdavAutoSync'] = true;
          final before = appdata.settings['dataVersion'] as int;
          final release = Completer<void>();
          putGate = release;
          putStarted = Completer<void>();
          final first = sync.uploadData();
          await putStarted!.future.timeout(const Duration(seconds: 15));
          expect(
            BackgroundTasks.instance.latest('webdav-upload')!.isRunning,
            isTrue,
          );
          final waiting = List.generate(30, (_) => sync.uploadData());
          expect(sync.uploadQueued, isTrue);
          if (disable) appdata.implicitData['webdavAutoSync'] = false;
          if (manual) waiting.add(sync.uploadData(force: true));
          release.complete();
          final results = await Future.wait([
            first,
            ...waiting,
          ]).timeout(const Duration(seconds: 15));
          expect(results.every((result) => result.success), isTrue);
          final expected = disable && !manual ? 1 : 2;
          expect(
            operations.where((op) => op.startsWith('PUT ')).length,
            expected,
          );
          expect(appdata.settings['dataVersion'], before + expected);
          expect(sync.uploadQueued, isFalse);
        }

        await tester.runAsync(() => uploadBurst(disable: false, manual: false));
        await tester.runAsync(() => uploadBurst(disable: true, manual: false));
        await tester.runAsync(() => uploadBurst(disable: true, manual: true));

        Future<void> downloadThenUpload({
          required bool disable,
          required bool manual,
        }) async {
          operations.clear();
          appdata.implicitData['webdavAutoSync'] = !manual;
          final release = Completer<void>();
          readGate = release;
          readStarted = Completer<void>();
          final downloading = sync.downloadData();
          await readStarted!.future.timeout(const Duration(seconds: 15));
          expect(
            BackgroundTasks.instance.latest('webdav-download')!.isRunning,
            isTrue,
          );
          if (manual) {
            await sync.uploadData();
            expect(sync.uploadQueued, isFalse);
          }
          final uploading = sync.uploadData(force: manual);
          expect(sync.uploadQueued, isTrue);
          if (disable) appdata.implicitData['webdavAutoSync'] = false;
          expect(operations.where((op) => op.startsWith('PUT ')), isEmpty);
          release.complete();
          expect((await downloading).success, isTrue);
          expect(
            BackgroundTasks.instance.latest('webdav-download')!.status,
            BackgroundTaskStatus.completed,
          );
          expect(
            (await uploading.timeout(const Duration(seconds: 15))).success,
            isTrue,
          );
          expect(
            operations.where((op) => op.startsWith('PUT ')).length,
            disable && !manual ? 0 : 1,
          );
          expect(sync.uploadQueued, isFalse);
        }

        await tester.runAsync(
          () => downloadThenUpload(disable: false, manual: false),
        );
        await tester.runAsync(
          () => downloadThenUpload(disable: true, manual: false),
        );
        await tester.runAsync(
          () => downloadThenUpload(disable: true, manual: true),
        );

        // Two devices start from the user's version 3687. The second upload
        // must advance past the remote revision, even with an older local one.
        await tester.runAsync(() async {
          remote.clear();
          appdata.implicitData['webdavAutoSync'] = false;
          appdata.settings['dataVersion'] = 3687;
          appdata.searchHistory = ['device-a'];
          expect((await sync.uploadData(force: true)).success, isTrue);
          final deviceAMarker = Map<String, dynamic>.from(
            appdata.implicitData['webdavLastBackup'],
          );
          expect(appdata.settings['dataVersion'], 3688);
          appdata.settings['dataVersion'] = 3687;
          appdata.searchHistory = ['device-b'];
          appdata.implicitData.remove('webdavLastBackup');
          expect((await sync.uploadData(force: true)).success, isTrue);
          expect(appdata.settings['dataVersion'], 3689);
          final deviceBBytes = List<int>.from(remote.values.single);

          // Download into A while its independent local counter is higher.
          // Importing database notifications must not queue another upload.
          appdata.settings['dataVersion'] = 9999;
          appdata.searchHistory = ['device-a'];
          appdata.implicitData['webdavLastBackup'] = deviceAMarker;
          appdata.implicitData['webdavAutoSync'] = true;
          operations.clear();
          expect((await sync.downloadData()).success, isTrue);
          expect(appdata.searchHistory, ['device-b']);
          expect(appdata.settings['dataVersion'], 3689);
          expect(sync.uploadQueued, isFalse);
          expect(operations.where((op) => op.startsWith('PUT ')), isEmpty);
          operations.clear();
          expect((await sync.downloadData()).success, isTrue);
          expect(operations.where((op) => op.startsWith('GET ')), isEmpty);

          // Legacy clients can overwrite the same name at the same version.
          // An ETag change must restore it instead of treating 3689 == 3689
          // as proof that its contents are already present locally.
          remote.clear();
          final legacyName = '$day-3689.venera';
          remote[legacyName] = deviceBBytes;
          etags[legacyName] = 1;
          appdata.implicitData.remove('webdavLastBackup');
          expect((await sync.downloadData()).success, isTrue);
          appdata.searchHistory = ['device-c'];
          final deviceCBackup = await exportAppData(true);
          final deviceCBytes = await deviceCBackup.readAsBytes();
          remote[legacyName] = deviceCBytes;
          await deviceCBackup.delete();
          etags[legacyName] = 2;
          appdata.searchHistory = ['device-b'];
          operations.clear();
          expect((await sync.downloadData()).success, isTrue);
          expect(appdata.searchHistory, ['device-c']);
          expect(operations, contains('GET $legacyName'));
          expect(sync.uploadQueued, isFalse);

          // Without metadata, an unchanged name and size are insufficient to
          // skip a legacy snapshot: fetch it rather than silently freezing it.
          provideEtags = false;
          expect((await sync.downloadData()).success, isTrue);
          remote[legacyName] = deviceBBytes;
          operations.clear();
          expect((await sync.downloadData()).success, isTrue);
          expect(appdata.searchHistory, ['device-b']);
          expect(operations, contains('GET $legacyName'));
          provideEtags = true;

          // Simultaneous devices can still allocate the same counter. Their
          // unique filenames retain both snapshots and allow the later one
          // to be restored even though the numeric versions are equal.
          remote.clear();
          final concurrentA =
              '$day-3689-00000000000000000001-'
              '${'a' * 32}.venera';
          final concurrentB =
              '$day-3689-00000000000000000002-'
              '${'b' * 32}.venera';
          remote[concurrentA] = deviceBBytes;
          remote[concurrentB] = deviceCBytes;
          final last = appdata.implicitData['webdavLastBackup'] as Map;
          appdata.implicitData['webdavLastBackup'] = {
            ...last,
            'name': concurrentA,
            'identity': jsonEncode([concurrentA]),
          };
          expect((await sync.downloadData()).success, isTrue);
          expect(appdata.settings['dataVersion'], 3689);
          expect(appdata.searchHistory, ['device-c']);
          operations.clear();
          expect((await sync.downloadData()).success, isTrue);
          expect(operations.where((op) => op.startsWith('GET ')), isEmpty);

          // The last-snapshot marker is scoped to a particular WebDAV target.
          appdata.settings['webdav'] = [
            'http://127.0.0.1:${server.port}',
            'fixture-other-user',
            'fixture-password',
          ];
          appdata.searchHistory = ['other-device'];
          expect((await sync.downloadData()).success, isTrue);
          expect(appdata.searchHistory, ['device-c']);
          expect(appdata.settings['webdav'][1], 'fixture-other-user');
          expect(sync.uploadQueued, isFalse);

          // A higher revision must win even when its device clock moved back.
          remote.clear();
          final futureName = '${day + 1}-3689.venera';
          final newerName = '${day - 1}-3690.venera';
          remote[futureName] = deviceBBytes;
          remote[newerName] = deviceCBytes;
          appdata.implicitData['webdavLastBackup'] = {
            ...appdata.implicitData['webdavLastBackup'] as Map,
            'name': futureName,
            'identity': 'already-seen-future-file',
          };
          operations.clear();
          expect((await sync.downloadData()).success, isTrue);
          expect(operations, contains('GET $newerName'));
          expect(appdata.searchHistory, ['device-c']);
          expect(sync.uploadQueued, isFalse);
        });
        // Exercise feature operations, not direct uploadData calls. Every
        // mutation must upload when enabled, and remain local when disabled.
        await tester.runAsync(() async {
          const comic = Comic(
            'Sync item',
            '',
            'sync-item',
            '',
            [],
            '',
            'local',
            null,
            null,
          );
          final later = ReadLaterComic(
            id: comic.id,
            title: comic.title,
            subtitle: '',
            tags: [],
            cover: '',
            description: '',
            sourceKey: 'local',
            type: ComicType.local,
          );
          void seedHistory() => HistoryManager().addHistory(
            History.fromMap({
              'id': comic.id,
              'title': comic.title,
              'subtitle': '',
              'cover': '',
              'type': 0,
              'time': DateTime.now().millisecondsSinceEpoch,
              'ep': 1,
              'page': 1,
            }),
          );
          void seedStatistics() => ReadingStatisticsManager().recordSession(
            comic: comic,
            startedAt: DateTime.now().subtract(const Duration(seconds: 5)),
            endedAt: DateTime.now(),
          );
          final image = ImageFavorite(
            1,
            'fixture-image',
            false,
            '1',
            comic.id,
            1,
            'local',
            'Chapter',
          );
          ImageFavoritesComic imageComic() => ImageFavoritesComic(
            comic.id,
            [
              ImageFavoritesEp('1', 1, [image], 'Chapter', 1),
            ],
            comic.title,
            'local',
            [],
            [],
            DateTime.now(),
            '',
            {},
            '',
            1,
          );
          final actions = <String, void Function()>{
            'read later add': () => ReadLaterManager().add(comic),
            'read later remove': () =>
                ReadLaterManager().remove(comic.id, ComicType.local),
            'read later restore': () => ReadLaterManager().restore([later]),
            'read later batch remove': () =>
                ReadLaterManager().removeMany([later]),
            'read later clear': () {
              final autoSync = appdata.implicitData['webdavAutoSync'];
              appdata.implicitData['webdavAutoSync'] = false;
              ReadLaterManager().add(comic);
              appdata.implicitData['webdavAutoSync'] = autoSync;
              ReadLaterManager().clear();
            },
            'history remove': () {
              seedHistory();
              HistoryManager().remove(comic.id, ComicType.local);
            },
            'history clear': () {
              seedHistory();
              HistoryManager().clearHistory();
            },
            'history unfavorited': () {
              seedHistory();
              HistoryManager().clearUnfavoritedHistory();
            },
            'history batch remove': () {
              seedHistory();
              HistoryManager().batchDeleteHistories([
                ComicID(ComicType.local, comic.id),
              ]);
            },
            'statistics remove': () {
              seedStatistics();
              ReadingStatisticsManager().deleteComic(comic.id, ComicType.local);
            },
            'statistics clear': () {
              seedStatistics();
              ReadingStatisticsManager().clear();
            },
            'image favorite add': () =>
                ImageFavoriteManager().addOrUpdateOrDelete(imageComic()),
            'image favorite remove': () =>
                ImageFavoriteManager().deleteImageFavorite([image]),
          };
          for (final enabled in [true, false]) {
            appdata.implicitData['webdavAutoSync'] = enabled;
            for (final action in actions.entries) {
              operations.clear();
              action.value();
              if (enabled) {
                expect(
                  sync.isUploading || sync.uploadQueued,
                  isTrue,
                  reason: action.key,
                );
                final deadline = DateTime.now().add(
                  const Duration(seconds: 15),
                );
                while ((sync.isUploading || sync.uploadQueued) &&
                    DateTime.now().isBefore(deadline)) {
                  await Future<void>.delayed(const Duration(milliseconds: 10));
                }
                expect(
                  sync.isUploading || sync.uploadQueued,
                  isFalse,
                  reason: action.key,
                );
                expect(sync.lastError, isNull, reason: action.key);
                expect(
                  operations.where((op) => op.startsWith('PUT ')),
                  isNotEmpty,
                  reason: action.key,
                );
              } else {
                expect(
                  sync.isUploading || sync.uploadQueued,
                  isFalse,
                  reason: action.key,
                );
                expect(operations, isEmpty, reason: action.key);
              }
            }
          }
        });
        operations.clear();
        appdata.implicitData['webdavAutoSync'] = false;
        await tester.tap(find.text('Configure backup'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byType(RadioGroup<bool>));
        await tester.tap(
          find.byWidgetPredicate(
            (widget) => widget is Radio<bool> && widget.value == false,
          ),
        );
        await tester.ensureVisible(find.text('Continue'));
        await tester.runAsync(() => tester.tap(find.text('Continue')));
        for (var i = 0; i < 300 && sync.isDownloading; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)),
          );
          await tester.pump(const Duration(milliseconds: 50));
        }
        await tester.pumpAndSettle();
        expect(operations.any((op) => op.startsWith('PROPFIND ')), isTrue);
        expect(operations.any((op) => op.startsWith('PUT ')), isFalse);
        expect(appdata.implicitData['webdavAutoSync'], isFalse);
        expect(find.text('Continue'), findsNothing);

        operations.clear();
        await tester.tap(find.text('Configure backup'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byType(Switch));
        await tester.tap(find.byType(Switch));
        expect(appdata.implicitData['webdavAutoSync'], isFalse);
        await tester.ensureVisible(find.text('Save'));
        await tester.runAsync(() => tester.tap(find.text('Save')));
        for (
          var i = 0;
          i < 100 && find.text('Save').evaluate().isNotEmpty;
          i++
        ) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 30)),
          );
          await tester.pump(const Duration(milliseconds: 50));
        }
        await tester.pumpAndSettle();
        expect(appdata.implicitData['webdavAutoSync'], isTrue);
        expect(operations, isEmpty);
        print(
          'WEBDAV_GATE_PASS: disabled writes=0 PUT; manual upload works; bursts merged; queued gate rechecked; multiple devices and legacy snapshots sync without reupload',
        );
        await tester.pump(const Duration(seconds: 2));
        expect(tester.takeException(), isNull);
      } finally {
        await tester.runAsync(() async {
          JsEngine().dispose();
          HistoryManager().close();
          LocalFavoritesManager().close();
          ReadLaterManager().close();
          ReadingStatisticsManager().close();
          await server.close(force: true);
          await listener.cancel();
          await root.delete(recursive: true);
        });
      }
    },
    skip: !device && Platform.environment['PRIME_NATIVE_ZIP_TEST'] != '1',
  );
}
