import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/data_sync.dart';
import 'package:venera/utils/init.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/atomic_file.dart';

class Appdata with Init {
  Appdata._create();

  final Settings settings = Settings._create();

  var searchHistory = <String>[];

  bool _isSavingData = false;

  static final _invalidSetting = Object();

  Object? _sanitizeValue(Object? value, [int depth = 0]) {
    if (depth > 8) return _invalidSetting;
    if (value == null || value is bool || value is num) return value;
    if (value is String) {
      return value.length <= 1024 * 1024 ? value : _invalidSetting;
    }
    if (value is List) {
      if (value.length > 10000) return _invalidSetting;
      final result = <dynamic>[];
      for (final item in value) {
        final sanitized = _sanitizeValue(item, depth + 1);
        if (identical(sanitized, _invalidSetting)) return _invalidSetting;
        result.add(sanitized);
      }
      return result;
    }
    if (value is Map) {
      if (value.length > 1000) return _invalidSetting;
      final result = <String, dynamic>{};
      for (final entry in value.entries) {
        if (entry.key is! String) return _invalidSetting;
        final sanitized = _sanitizeValue(entry.value, depth + 1);
        if (identical(sanitized, _invalidSetting)) return _invalidSetting;
        result[entry.key as String] = sanitized;
      }
      return result;
    }
    return _invalidSetting;
  }

  bool _matchesExpectedType(Object? expected, Object? value) {
    if (expected == null || value == null) return true;
    if (expected is bool) return value is bool;
    if (expected is num) return value is num;
    if (expected is String) return value is String;
    if (expected is List) return value is List;
    if (expected is Map) return value is Map;
    return true;
  }

  Map<String, dynamic> _sanitizeSettings(Map raw) {
    final result = <String, dynamic>{};
    for (final entry in raw.entries) {
      if (entry.key is! String) continue;
      final value = _sanitizeValue(entry.value);
      if (identical(value, _invalidSetting) ||
          !_matchesExpectedType(settings._data[entry.key], value)) {
        Log.warning("Appdata", "Ignoring an invalid setting: ${entry.key}");
        continue;
      }
      result[entry.key as String] = value;
    }
    return result;
  }

  Future<void> saveData([bool sync = true]) async {
    while (_isSavingData) {
      await Future.delayed(const Duration(milliseconds: 20));
    }
    _isSavingData = true;
    try {
      var futures = <Future>[];
      var json = toJson();
      var data = jsonEncode(json);
      var file = File(FilePath.join(App.dataPath, 'appdata.json'));
      futures.add(atomicWriteString(file, data));

      var disableSyncFields =
          json["settings"]["disableSyncFields"]?.toString() ?? '';
      var json4sync = jsonDecode(data);
      final customDisableSync = splitField(disableSyncFields);
      _removeSyncDisabledFields(
        json4sync["settings"],
        {..._disableSync, ...customDisableSync}.toList(),
      );
      var data4sync = jsonEncode(json4sync);
      var file4sync = File(FilePath.join(App.dataPath, 'syncdata.json'));
      futures.add(atomicWriteString(file4sync, data4sync));

      await Future.wait(futures);
    } finally {
      _isSavingData = false;
    }
    if (sync) {
      DataSync().uploadData();
    }
  }

  void addSearchHistory(String keyword) {
    if (searchHistory.contains(keyword)) {
      searchHistory.remove(keyword);
    }
    searchHistory.insert(0, keyword);
    if (searchHistory.length > 50) {
      searchHistory.removeLast();
    }
    saveData();
  }

  void removeSearchHistory(String keyword) {
    searchHistory.remove(keyword);
    saveData();
  }

  void clearSearchHistory() {
    searchHistory.clear();
    saveData();
  }

  Map<String, dynamic> toJson() {
    return {'settings': settings._data, 'searchHistory': searchHistory};
  }

  List<String> splitField(String merged) {
    return merged
        .split(',')
        .map((field) => field.trim())
        .where((field) => field.isNotEmpty)
        .toList();
  }

  bool isSyncFieldDisabled(String field) {
    return splitField(
      settings["disableSyncFields"]?.toString() ?? '',
    ).contains(field);
  }

  void setSyncFieldDisabled(String field, bool disabled) {
    var fields = splitField(settings["disableSyncFields"]?.toString() ?? '');
    if (disabled) {
      if (!fields.contains(field)) {
        fields.add(field);
      }
    } else {
      fields.remove(field);
    }
    settings["disableSyncFields"] = fields.join(", ");
  }

  static const _readerScopedSettingContainers = [
    "comicSpecificSettings",
    "deviceSpecificSettings",
  ];

  static const _secretSyncFields = {
    "account",
    "password",
    "passwd",
    "pwd",
    "token",
    "access_token",
    "refresh_token",
    "authorization",
    "cookie",
    "set_cookie",
    "secret",
  };

  static bool _isSecretSyncField(String field) {
    final normalized = field.toLowerCase().replaceAll('-', '_');
    return _secretSyncFields.contains(normalized) ||
        normalized.contains('token');
  }

  static void _removeSyncDisabledFields(
    Map<String, dynamic> settings,
    List<String> disabledFields,
  ) {
    for (final field in settings.keys.toList()) {
      if (disabledFields.contains(field) || _isSecretSyncField(field)) {
        settings.remove(field);
      }
    }
    for (var containerKey in _readerScopedSettingContainers) {
      var container = settings[containerKey];
      if (container is Map) {
        for (var scopedSettings in container.values) {
          if (scopedSettings is Map) {
            for (final field in scopedSettings.keys.toList()) {
              if (disabledFields.contains(field) ||
                  _isSecretSyncField(field.toString())) {
                scopedSettings.remove(field);
              }
            }
          }
        }
      }
    }
  }

  Map<String, dynamic> _mergeSyncDisabledReaderScopedSettings(
    Map current,
    Map incoming,
    List<String> disabledFields,
  ) {
    var result = <String, dynamic>{};
    for (var entry in incoming.entries) {
      var incomingSettings = entry.value;
      if (incomingSettings is Map) {
        var scopedSettings = Map<String, dynamic>.from(incomingSettings);
        var currentSettings = current[entry.key];
        if (currentSettings is Map) {
          for (var field in disabledFields) {
            if (currentSettings.containsKey(field)) {
              scopedSettings[field] = currentSettings[field];
            }
          }
        }
        result[entry.key.toString()] = scopedSettings;
      } else {
        result[entry.key.toString()] = incomingSettings;
      }
    }
    for (var entry in current.entries) {
      if (result.containsKey(entry.key)) {
        continue;
      }
      var currentSettings = entry.value;
      if (currentSettings is Map) {
        var scopedSettings = <String, dynamic>{};
        for (var field in disabledFields) {
          if (currentSettings.containsKey(field)) {
            scopedSettings[field] = currentSettings[field];
          }
        }
        if (scopedSettings.isNotEmpty) {
          result[entry.key.toString()] = scopedSettings;
        }
      }
    }
    return result;
  }

  /// Following fields are related to device-specific data and should not be synced.
  static const _disableSync = [
    "proxy",
    "authorizationRequired",
    "customImageProcessing",
    "webdav",
    "disableSyncFields",
    "deviceId",
    "account",
    "password",
    "passwd",
    "pwd",
    "token",
    "access_token",
    "refresh_token",
    "authorization",
    "cookie",
    "secret",
  ];

  /// Sync data from another device
  void syncData(Map<String, dynamic> data, {bool persist = true}) {
    if (data['settings'] is Map) {
      var settings = _sanitizeSettings(data['settings'] as Map);

      List<String> customDisableSync = splitField(
        this.settings["disableSyncFields"]?.toString() ?? '',
      );
      _removeSyncDisabledFields(settings, customDisableSync);

      for (var key in settings.keys) {
        if (!_disableSync.contains(key) && !customDisableSync.contains(key)) {
          if (_readerScopedSettingContainers.contains(key) &&
              settings[key] is Map &&
              customDisableSync.isNotEmpty) {
            this.settings[key] = _mergeSyncDisabledReaderScopedSettings(
              this.settings[key] is Map ? this.settings[key] : {},
              settings[key],
              customDisableSync,
            );
          } else {
            this.settings[key] = settings[key];
          }
        }
      }
    }
    // Remote files may be partially written or produced by an older version.
    // Ignore malformed history instead of crashing during startup sync.
    final remoteHistory = data['searchHistory'];
    if (remoteHistory is List) {
      searchHistory = remoteHistory
          .whereType<String>()
          .where((value) => value.length <= 4096)
          .take(50)
          .toList();
    }
    if (persist) {
      saveData();
    }
  }

  var implicitData = <String, dynamic>{};

  void writeImplicitData() async {
    while (_isSavingData) {
      await Future.delayed(const Duration(milliseconds: 20));
    }
    _isSavingData = true;
    try {
      var file = File(FilePath.join(App.dataPath, 'implicitData.json'));
      await atomicWriteString(file, jsonEncode(implicitData));
    } finally {
      _isSavingData = false;
    }
  }

  @override
  Future<void> doInit() async {
    var dataPath = (await getApplicationSupportDirectory()).path;
    var file = File(FilePath.join(dataPath, 'appdata.json'));
    if (!await file.exists()) {
      return;
    }
    try {
      var json = jsonDecode(await file.readAsString());
      final rawSettings = json is Map ? json['settings'] : null;
      if (rawSettings is Map) {
        for (var entry in _sanitizeSettings(rawSettings).entries) {
          if (entry.value != null) settings[entry.key] = entry.value;
        }
      }
      final loadedHistory = json is Map ? json['searchHistory'] : null;
      if (loadedHistory is List) {
        searchHistory = loadedHistory
            .whereType<String>()
            .where((value) => value.length <= 4096)
            .take(50)
            .toList();
      }
    } catch (e, s) {
      Log.error("Appdata", "Failed to load appdata", e);
      final corrupt = File(
        '${file.path}.corrupt.${DateTime.now().millisecondsSinceEpoch}',
      );
      try {
        await file.rename(corrupt.path);
        Log.info("Appdata", "Moved invalid appdata to ${corrupt.path}");
      } catch (renameError, renameStack) {
        Log.error(
          "Appdata",
          "Failed to preserve invalid appdata: $renameError",
          renameStack,
        );
        Log.error("Appdata", "Original appdata error: $e", s);
      }
    }
    if (settings["deviceId"]?.toString().isEmpty ?? true) {
      settings._data["deviceId"] = const Uuid().v4();
      await saveData(false);
    }
    try {
      var implicitDataFile = File(FilePath.join(dataPath, 'implicitData.json'));
      if (await implicitDataFile.exists()) {
        final decoded = jsonDecode(await implicitDataFile.readAsString());
        if (decoded is Map) {
          implicitData = decoded.map(
            (key, value) => MapEntry(key.toString(), value),
          );
        } else {
          throw const FormatException('implicit data must be an object');
        }
      }
    } catch (e) {
      Log.error("Appdata", "Failed to load implicit data", e);
      Log.info("Appdata", "Resetting implicit data");
      var implicitDataFile = File(FilePath.join(dataPath, 'implicitData.json'));
      implicitDataFile.deleteIgnoreError();
      implicitData = <String, dynamic>{};
    }
  }
}

final appdata = Appdata._create();

class Settings with ChangeNotifier {
  Settings._create();

  final _data = <String, dynamic>{
    'comicDisplayMode': 'detailed', // detailed, brief
    'comicTileScale': 1.00, // 0.75-1.25
    'color': 'system', // red, pink, purple, green, orange, blue
    'theme_mode': 'system', // light, dark, system
    'newFavoriteAddTo': 'end', // start, end
    'moveFavoriteAfterRead': 'none', // none, end, start
    'proxy': 'system', // direct, system, proxy string
    'explore_pages': [],
    'categories': [],
    'favorites': [],
    'searchSources': null,
    'showFavoriteStatusOnTile': true,
    'showHistoryStatusOnTile': false,
    'blockedWords': [],
    'blockedCommentWords': [],
    'defaultSearchTarget': null,
    'autoPageTurningInterval': 5, // in seconds
    'readerMode': 'galleryLeftToRight', // values of [ReaderMode]
    'readerScreenPicNumberForLandscape': 1, // 1 - 5
    'readerScreenPicNumberForPortrait': 1, // 1 - 5
    'enableTapToTurnPages': true,
    'reverseTapToTurnPages': false,
    'enablePageAnimation': true,
    'flashWhiteScreenOnPageTurn': false,
    'convertTraditionalToSimplified': false,
    'language': 'system', // system, zh-CN, zh-TW, en-US
    'cacheSize': 2048, // in MB
    'downloadThreads': 5,
    'enableLongPressToZoom': true,
    'longPressZoomPosition': "press", // press, center
    'checkUpdateOnStart': true,
    'limitImageWidth': true,
    'webdav': [], // empty means not configured
    "disableSyncFields": "", // "field1, field2, ..."
    'dataVersion': 0,
    'quickFavorite': null,
    'enableTurnPageByVolumeKey': true,
    'enableClockAndBatteryInfoInReader': true,
    'quickCollectImage': 'No', // No, DoubleTap, Swipe
    'authorizationRequired': false,
    'onClickFavorite': 'viewDetail', // viewDetail, read
    'enableDnsOverrides': false,
    'dnsOverrides': {},
    'enableCustomImageProcessing': false,
    'customImageProcessing': defaultCustomImageProcessing,
    'sni': true,
    'autoAddLanguageFilter': 'none', // none, chinese, english, japanese
    'comicSourceListUrl': _defaultSourceListUrl,
    'comicSourceOrder': <String>[],
    'preloadImageCount': 4,
    'followUpdatesFolder': null,
    'followUpdatesCheckOnStart': true,
    'followUpdatesCheckIntervalHours': 24,
    'followUpdatesCheckFixedTime': '',
    'initialPage': '0',
    'comicListDisplayMode': 'paging', // paging, continuous
    'showPageNumberInReader': true,
    'showSingleImageOnFirstPage': false,
    'enableDoubleTapToZoom': true,
    'reverseChapterOrder': false,
    'showSystemStatusBar': false,
    'comicSpecificSettings': <String, Map<String, dynamic>>{},
    'deviceSpecificSettings': <String, Map<String, dynamic>>{},
    'deviceId': '',
    'ignoreBadCertificate': false,
    'readerScrollSpeed': 1.0, // 0.5 - 3.0
    'localFavoritesFirst': true,
    'autoCloseFavoritePanel': false,
    'showChapterComments': true, // show chapter comments in reader
    'showChapterCommentsAtEnd':
        false, // show chapter comments at end of chapter
    'readerBackground': 'theme', // theme, white, gray, black, sepia
    'readerNightMode': 'none', // none, warm, dark, red
    'readerNightModeIntensity': 0.25, // 0.0 - 0.8
    'removeReadLaterOnComplete': true,
    'hideDuplicateChapters': true,
  };

  operator [](String key) {
    return _data[key];
  }

  operator []=(String key, dynamic value) {
    _data[key] = value;
    if (key != "dataVersion") {
      notifyListeners();
    }
  }

  void setEnabledComicSpecificSettings(
    String comicId,
    String sourceKey,
    bool enabled,
  ) {
    setReaderSetting(comicId, sourceKey, "enabled", enabled);
  }

  bool isComicSpecificSettingsEnabled(String? comicId, String? sourceKey) {
    if (comicId == null || sourceKey == null) {
      return false;
    }
    return _data['comicSpecificSettings']["$comicId@$sourceKey"]?["enabled"] ==
        true;
  }

  dynamic getReaderSetting(String comicId, String sourceKey, String key) {
    if (isComicSpecificSettingsEnabled(comicId, sourceKey)) {
      var comicValue =
          _data['comicSpecificSettings']["$comicId@$sourceKey"]?[key];
      if (comicValue != null) {
        return comicValue;
      }
    }
    return getDeviceReaderSetting(key);
  }

  void setReaderSetting(
    String comicId,
    String sourceKey,
    String key,
    dynamic value,
  ) {
    (_data['comicSpecificSettings'] as Map<String, dynamic>).putIfAbsent(
      "$comicId@$sourceKey",
      () => <String, dynamic>{},
    )[key] = value;
    notifyListeners();
  }

  void resetComicReaderSettings(String key) {
    (_data['comicSpecificSettings'] as Map).remove(key);
    notifyListeners();
  }

  void setEnabledDeviceSpecificSettings(bool enabled) {
    setDeviceReaderSetting("enabled", enabled);
  }

  bool isDeviceSpecificSettingsEnabled() {
    var deviceId = _data['deviceId'] as String;
    if (deviceId.isEmpty) {
      return false;
    }
    return _data['deviceSpecificSettings'][deviceId]?["enabled"] == true;
  }

  dynamic getDeviceReaderSetting(String key) {
    if (!isDeviceSpecificSettingsEnabled()) {
      return _data[key];
    }
    var deviceId = _data['deviceId'] as String;
    return _data['deviceSpecificSettings'][deviceId]?[key] ?? _data[key];
  }

  void setDeviceReaderSetting(String key, dynamic value) {
    var deviceId = _getOrCreateDeviceId();
    (_data['deviceSpecificSettings'] as Map<String, dynamic>).putIfAbsent(
      deviceId,
      () => <String, dynamic>{},
    )[key] = value;
    notifyListeners();
  }

  void resetDeviceReaderSettings() {
    var deviceId = _data['deviceId'] as String;
    if (deviceId.isEmpty) {
      return;
    }
    (_data['deviceSpecificSettings'] as Map).remove(deviceId);
    notifyListeners();
  }

  String _getOrCreateDeviceId() {
    var deviceId = _data['deviceId'] as String;
    if (deviceId.isNotEmpty) {
      return deviceId;
    }
    var id = const Uuid().v4();
    _data['deviceId'] = id;
    return id;
  }

  @override
  String toString() {
    return _data.toString();
  }
}

const defaultCustomImageProcessing = '''
/**
 * Process an image
 * @param image {ArrayBuffer} - The image to process
 * @param cid {string} - The comic ID
 * @param eid {string} - The episode ID
 * @param page {number} - The page number
 * @param sourceKey {string} - The source key
 * @returns {Promise<ArrayBuffer> | {image: Promise<ArrayBuffer>, onCancel: () => void}} - The processed image
 */
async function processImage(image, cid, eid, page, sourceKey) {
    let futureImage = new Promise((resolve, reject) => {
        resolve(image);
    });
    return futureImage;
}
''';

const _defaultSourceListUrl =
    "https://cdn.jsdelivr.net/gh/venera-app/venera-configs@main/index.json";
