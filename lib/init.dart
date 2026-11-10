import 'dart:async';

import 'package:display_mode/display_mode.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_saf/flutter_saf.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/cache_maintenance_service.dart';
import 'package:venera/foundation/background_tasks.dart';
import 'package:venera/foundation/app_update_service.dart';
import 'package:venera/foundation/update_schedule.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_source/source_library.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/network/app_dio.dart';
import 'package:venera/network/cookie_jar.dart';
import 'package:venera/pages/comic_source_page.dart';
import 'package:venera/pages/follow_updates_page.dart';
import 'package:venera/pages/settings/settings_page.dart';
import 'package:venera/utils/app_links.dart';
import 'package:venera/utils/handle_text_share.dart';
import 'package:venera/utils/opencc.dart';
import 'package:venera/utils/tags_translation.dart';
import 'package:venera/utils/translations.dart';
import 'foundation/appdata.dart';

extension _FutureInit<T> on Future<T> {
  /// Prevent unhandled exception
  ///
  /// A unhandled exception occurred in init() will cause the app to crash.
  Future<void> wait() async {
    try {
      await this;
    } catch (e, s) {
      Log.error("init", "$e\n$s");
    }
  }
}

class InitializationFailure {
  final String stage;
  final Object error;
  final StackTrace stackTrace;

  const InitializationFailure({
    required this.stage,
    required this.error,
    required this.stackTrace,
  });
}

Future<InitializationFailure?> init() async {
  try {
    await App.init();
  } catch (e, s) {
    Log.error("core init", "$e\n$s");
    return InitializationFailure(
      stage: "application storage",
      error: e,
      stackTrace: s,
    );
  }

  try {
    await SingleInstanceCookieJar.createInstance();
  } catch (e, s) {
    Log.error("cookie init", "$e\n$s");
  }

  try {
    await App.initComponents();
  } catch (e, s) {
    Log.error("core init", "$e\n$s");
    App.closeComponents();
    return InitializationFailure(
      stage: "core databases",
      error: e,
      stackTrace: s,
    );
  }

  try {
    var futures = [
      AppTranslation.init().wait(),
      TagsTranslation.readData().wait(),
      OpenCC.init(),
    ];
    await Future.wait(futures);
  } catch (e, s) {
    Log.error("init", "$e\n$s");
  }
  final taskHistory = appdata.implicitData['backgroundTaskHistory'];
  BackgroundTasks.instance.configure(
    history: taskHistory is Map ? Map<String, dynamic>.from(taskHistory) : {},
    persist: () {
      appdata.implicitData['backgroundTaskHistory'] =
          BackgroundTasks.instance.history;
      appdata.writeImplicitData();
    },
  );
  CacheManager().setLimitSize(appdata.settings['cacheSize']);
  CacheMaintenanceService.instance.start();
  unawaited(
    _ensureComicSourcesInitialized().catchError((
      Object error,
      StackTrace stack,
    ) {
      Log.error('comic source init', error, stack);
    }),
  );
  if (App.isAndroid) {
    unawaited(AppUpdateService.instance.restore());
    handleLinks(_ensureComicSourcesInitialized());
    handleTextShare();
    try {
      await FlutterDisplayMode.setHighRefreshRate();
    } catch (e) {
      Log.error("Display Mode", "Failed to set high refresh rate: $e");
    }
  }
  FlutterError.onError = (details) {
    Log.error("Unhandled Exception", "${details.exception}\n${details.stack}");
  };
  if (App.isWindows) {
    // Report to the monitor thread that the app is running
    // https://github.com/venera-app/venera/issues/343
    Timer.periodic(const Duration(seconds: 1), (_) {
      const methodChannel = MethodChannel('venera/method_channel');
      methodChannel.invokeMethod("heartBeat");
    });
  }
  return null;
}

final _comicSourcesInitialization = RetryableInitialization();
final _safInitialization = RetryableInitialization();
Future<void>? _sourceUpdateCheck;
bool _sourceManagerAttempted = false;
bool _followUpdatesRequested = false;

Future<void> _ensureComicSourcesInitialized() =>
    _comicSourcesInitialization.run(_initComicSources);

Future<void> _initComicSources() => BackgroundTasks.instance.run<void>(
  'source-initialization',
  "Initialize comic sources".tl,
  (task) async {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    task.update(total: 3, message: "Preparing source runtime".tl);
    await Future.wait([
      ensureRHttpInitialized(),
      _safInitialization.run(() => SAFTaskWorker().init()),
    ]);
    // JsEngine currently logs some initialization exceptions internally.
    // Verify the bootstrap before declaring readiness, and discard a broken
    // runtime so a later attempt can genuinely recreate it.
    final engine = JsEngine();
    try {
      await engine.init();
      if (engine.runCode(
            "typeof ComicSource !== 'undefined' && typeof ComicSource.sources === 'object'",
          ) !=
          true) {
        throw StateError('Comic source runtime initialization failed');
      }
    } catch (_) {
      engine.dispose();
      rethrow;
    }
    task.update(completed: 1, message: "Loading comic sources".tl);
    final manager = ComicSourceManager();
    final retry = _sourceManagerAttempted;
    _sourceManagerAttempted = true;
    if (retry) {
      await manager.reload();
    } else {
      await manager.init();
    }
    task.update(completed: 2);
    _checkOldConfigs();
    App.local.restoreDownloadingTasks();
    manager.notifyStateChange();
    task.update(completed: 3);
  },
);

void _checkOldConfigs() {
  if (appdata.settings['searchSources'] == null) {
    appdata.settings['searchSources'] = ComicSource.all()
        .where((e) => e.searchPageData != null)
        .map((e) => e.key)
        .toList();
  }

  if (appdata.implicitData['webdavAutoSync'] == null) {
    var webdavConfig = appdata.settings['webdav'];
    if (webdavConfig is List &&
        webdavConfig.length == 3 &&
        webdavConfig.whereType<String>().length == 3) {
      appdata.implicitData['webdavAutoSync'] = true;
    } else {
      appdata.implicitData['webdavAutoSync'] = false;
    }
    appdata.writeImplicitData();
  }

  if (appdata.settings['comicSourceListUrl'].toString().contains(
    "git.nyne.dev",
  )) {
    // migrate to jsdelivr cdn
    const migratedUrl =
        "https://cdn.jsdelivr.net/gh/venera-app/venera-configs@main/index.json";
    final oldUrl = appdata.settings['comicSourceListUrl'].toString();
    final oldLibrary = findLibraryByUrl(
      ComicSourceLibraryManager.all(),
      oldUrl,
    );
    if (oldLibrary != null) {
      ComicSourceLibraryManager.edit(oldLibrary.id, url: migratedUrl);
    } else {
      appdata.settings['comicSourceListUrl'] = migratedUrl;
      ComicSourceLibraryManager.migrateLegacy();
      appdata.saveData();
    }
  }
}

Future<void> _checkAppUpdates() async {
  // Turning this off must not consume the next successful-check interval.
  if (appdata.settings['checkUpdateOnStart'] != true) return;
  if (!isUpdateCheckDue(
    now: DateTime.now(),
    checkRecord: BackgroundTasks.instance.history['app-update-check'],
  )) {
    return;
  }
  await checkUpdateUi(false, true);
}

void checkUpdates() {
  unawaited(_checkAppUpdates());
  _followUpdatesRequested = true;
  checkSourceUpdates();
}

/// Source checks have their own completion-based daily gate. Initialization
/// failures and failed script application use the shorter retry interval.
void checkSourceUpdates({bool automatic = false}) {
  final optedIn = appdata.settings['autoUpdateComicSources'] == true;
  if (automatic && !optedIn && _comicSourcesInitialization.isInitialized) {
    return;
  }
  if (_sourceUpdateCheck != null) return;
  _sourceUpdateCheck =
      () async {
            final tasks = BackgroundTasks.instance;
            // Initial startup always tries once. Subsequent resume/hourly calls wait
            // after a failure rather than continually retrying a broken runtime.
            if (!_comicSourcesInitialization.isInitialized &&
                !_comicSourcesInitialization.isRunning &&
                !isUpdateCheckDue(
                  now: DateTime.now(),
                  checkRecord: tasks.history['source-initialization'],
                  successInterval: Duration.zero,
                )) {
              return;
            }
            await _ensureComicSourcesInitialized();
            if (_followUpdatesRequested) FollowUpdatesService.initChecker();
            if (automatic &&
                appdata.settings['autoUpdateComicSources'] != true) {
              return;
            }
            if (ComicSource.all().isEmpty) return;
            if (tasks.latest('source-update-all')?.isRunning == true) return;
            if (!isUpdateCheckDue(
              now: DateTime.now(),
              checkRecord: tasks.history['source-check'],
              applicationRecord: tasks.history['source-update-all'],
              hasPendingApplications:
                  ComicSourcePage.automaticUpdateKeys().isNotEmpty,
            )) {
              return;
            }
            await ComicSourcePage.runStartupUpdates();
          }()
          .catchError((Object error, StackTrace stack) {
            Log.error('Automatic source update', error, stack);
          })
          .whenComplete(() => _sourceUpdateCheck = null);
}
