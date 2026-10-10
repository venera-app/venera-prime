import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:venera/components/components.dart';
import 'package:venera/components/window_frame.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/network/app_dio.dart';
import 'package:venera/utils/data.dart';
import 'package:venera/utils/ext.dart';
import 'package:webdav_client/webdav_client.dart' hide File;
import 'package:venera/utils/translations.dart';

import 'io.dart';

@visibleForTesting
List<String> backupFilesToPrune({
  required Iterable<String> existingNames,
  required String dayPrefix,
  required String uploadedFilename,
}) {
  final obsoleteForDay = existingNames
      .where((name) => name.startsWith(dayPrefix) && name != uploadedFilename)
      .toList();
  final remainingFiles = existingNames
      .where(
        (name) => name != uploadedFilename && !obsoleteForDay.contains(name),
      )
      .toList();
  final excessCount = remainingFiles.length + 1 - 10;
  if (excessCount > 0) {
    remainingFiles.sort();
    obsoleteForDay.addAll(remainingFiles.take(excessCount));
  }
  return obsoleteForDay;
}

class DataSync with ChangeNotifier {
  DataSync._() {
    if (isEnabled) {
      downloadData();
    }
    LocalFavoritesManager().addListener(onDataChanged);
    ComicSourceManager().addListener(onDataChanged);
    if (App.isDesktop) {
      Future.delayed(const Duration(seconds: 1), () {
        var controller = WindowFrame.of(App.rootContext);
        controller.addCloseListener(_handleWindowClose);
      });
    }
  }

  void onDataChanged() {
    if (isEnabled) {
      uploadData();
    }
  }

  bool _handleWindowClose() {
    if (_isUploading) {
      _showWindowCloseDialog();
      return false;
    }
    return true;
  }

  void _showWindowCloseDialog() async {
    showLoadingDialog(
      App.rootContext,
      cancelButtonText: "Shut Down".tl,
      onCancel: () => exit(0),
      barrierDismissible: false,
      message: "Uploading data...".tl,
    );
    while (_isUploading) {
      await Future.delayed(const Duration(milliseconds: 50));
    }
    exit(0);
  }

  static DataSync? instance;

  factory DataSync() => instance ?? (instance = DataSync._());

  bool _isDownloading = false;

  bool get isDownloading => _isDownloading;

  bool _isUploading = false;

  bool get isUploading => _isUploading;

  bool _haveWaitingTask = false;

  // At most one trailing upload is retained while another transfer runs.
  // A manual request promotes that batch and waits for its actual result.
  Future<Res<bool>>? _pendingUpload;
  bool _pendingUploadForced = false;

  bool get uploadQueued => _pendingUpload != null;

  String? _lastError;

  String? get lastError => _lastError;

  bool get isEnabled {
    var config = appdata.settings['webdav'];
    var autoSync = appdata.implicitData['webdavAutoSync'] ?? false;
    return autoSync && config is List && config.isNotEmpty;
  }

  List<String>? _validateConfig() {
    var config = appdata.settings['webdav'];
    if (config is! List) {
      return null;
    }
    if (config.isEmpty) {
      return [];
    }
    if (config.length != 3 || config.whereType<String>().length != 3) {
      return null;
    }
    return List.from(config);
  }

  Future<Res<bool>> uploadData({bool force = false}) {
    // Gate every automatic caller before exporting, incrementing dataVersion,
    // notifying listeners, or retaining a pending task.
    if (!force && !isEnabled) return Future.value(const Res(true));
    if (_pendingUpload != null) {
      _pendingUploadForced |= force;
      return _pendingUpload!;
    }
    if (isUploading || isDownloading) {
      final completion = Completer<Res<bool>>();
      _pendingUpload = completion.future;
      _pendingUploadForced = force;
      notifyListeners();
      unawaited(_runPendingUpload(completion));
      return completion.future;
    }
    return _uploadDataNow();
  }

  Future<void> _runPendingUpload(Completer<Res<bool>> completion) async {
    try {
      while (isUploading || isDownloading) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      final force = _pendingUploadForced;
      _pendingUpload = null;
      _pendingUploadForced = false;
      // Recheck the switch: it may have been turned off during the transfer.
      final result = uploadData(force: force);
      notifyListeners();
      completion.complete(await result);
    } catch (error, stack) {
      // A new batch may already have queued behind the transfer we awaited.
      completion.completeError(error, stack);
    }
  }

  Future<Res<bool>> _uploadDataNow() async {
    _isUploading = true;
    _lastError = null;
    notifyListeners();
    try {
      var config = _validateConfig();
      if (config == null) {
        _lastError = 'Invalid WebDAV configuration';
        return const Res.error('Invalid WebDAV configuration');
      }
      if (config.isEmpty) {
        return const Res(true);
      }
      String url = config[0];
      String user = config[1];
      String pass = config[2];

      var client = newClient(
        url,
        user: user,
        password: pass,
        adapter: RHttpAdapter(),
      );

      File? backupFile;
      try {
        appdata.settings['dataVersion']++;
        await appdata.saveData(false);
        var data = await exportAppData(true);
        backupFile = data;
        var time = (DateTime.now().millisecondsSinceEpoch ~/ 86400000)
            .toString();
        var filename = time;
        filename += '-';
        filename += appdata.settings['dataVersion'].toString();
        filename += '.venera';
        var files = await client.readDir('/');
        files = files.where((e) => e.name!.endsWith('.venera')).toList();
        await client.write(filename, await data.readAsBytes());
        Log.info("Upload Data", "Data uploaded successfully");
        // Keep the previous backup until the new remote file is safely written.
        try {
          final namesToPrune = backupFilesToPrune(
            existingNames: files.map((file) => file.name!).toList(),
            dayPrefix: '$time-',
            uploadedFilename: filename,
          );
          for (final name in namesToPrune) {
            await client.remove(name);
          }
        } catch (e, s) {
          Log.error(
            "Upload Data",
            "Uploaded backup but failed to prune old backups: $e",
            s,
          );
        }
        return const Res(true);
      } catch (e, s) {
        Log.error("Upload Data", e, s);
        _lastError = e.toString();
        return Res.error(e.toString());
      } finally {
        await backupFile?.deleteIgnoreError();
      }
    } finally {
      _isUploading = false;
      notifyListeners();
    }
  }

  Future<Res<bool>> downloadData() async {
    if (_haveWaitingTask) return const Res(true);
    while (isDownloading || isUploading) {
      _haveWaitingTask = true;
      await Future.delayed(const Duration(milliseconds: 100));
    }
    _haveWaitingTask = false;
    _isDownloading = true;
    _lastError = null;
    notifyListeners();
    try {
      var config = _validateConfig();
      if (config == null) {
        _lastError = 'Invalid WebDAV configuration';
        return const Res.error('Invalid WebDAV configuration');
      }
      if (config.isEmpty) {
        return const Res(true);
      }
      String url = config[0];
      String user = config[1];
      String pass = config[2];

      var client = newClient(
        url,
        user: user,
        password: pass,
        adapter: RHttpAdapter(),
      );

      Directory? downloadDirectory;
      try {
        var files = await client.readDir('/');
        files.sort((a, b) => b.name!.compareTo(a.name!));
        var file = files.firstWhereOrNull((e) => e.name!.endsWith('.venera'));
        if (file == null) {
          throw 'No data file found';
        }
        var version = file.name!
            .split('-')
            .elementAtOrNull(1)
            ?.split('.')
            .first;
        if (version != null && int.tryParse(version) != null) {
          var currentVersion = appdata.settings['dataVersion'];
          if (currentVersion != null && int.parse(version) <= currentVersion) {
            Log.info("Data Sync", 'No new data to download');
            return const Res(true);
          }
        }
        Log.info("Data Sync", "Downloading data from WebDAV server");
        downloadDirectory = await Directory(
          App.cachePath,
        ).createTemp('webdav-');
        var localFile = File(
          FilePath.join(downloadDirectory.path, 'backup.venera'),
        );
        await client.read2File(file.name!, localFile.path);
        await importAppData(localFile, true);
        Log.info("Data Sync", "Data downloaded successfully");
        return const Res(true);
      } catch (e, s) {
        Log.error("Data Sync", e, s);
        _lastError = e.toString();
        return Res.error(e.toString());
      } finally {
        await downloadDirectory?.deleteIgnoreError(recursive: true);
      }
    } finally {
      _isDownloading = false;
      notifyListeners();
    }
  }
}
