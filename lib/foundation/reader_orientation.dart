import 'dart:convert';

import 'package:flutter/services.dart';

import 'appdata.dart';

enum ReaderOrientationMode {
  automatic,
  portrait,
  landscape;

  ReaderOrientationMode get next => switch (this) {
    automatic => portrait,
    portrait => landscape,
    landscape => automatic,
  };

  List<DeviceOrientation> get orientations => switch (this) {
    automatic => DeviceOrientation.values,
    portrait => const [
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ],
    landscape => const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ],
  };

  static ReaderOrientationMode fromStorage(Object? value) {
    return ReaderOrientationMode.values.firstWhere(
      (mode) => mode.name == value,
      orElse: () => automatic,
    );
  }
}

class ReaderOrientationMemory {
  static const globalModeKey = 'readerOrientationMode';
  static const comicModesKey = 'readerOrientationModesByComic';

  static bool get enabled =>
      appdata.settings['rememberReaderOrientation'] == true;

  static bool get perComic =>
      enabled && appdata.settings['rememberReaderOrientationPerComic'] == true;

  static String comicKey(String comicId, String sourceKey) =>
      jsonEncode([sourceKey, comicId]);

  static ReaderOrientationMode modeFor({
    required String comicId,
    required String sourceKey,
  }) {
    return modeFromData(
      appdata.implicitData,
      comicId: comicId,
      sourceKey: sourceKey,
      perComic: perComic,
    );
  }

  static ReaderOrientationMode modeFromData(
    Map<String, dynamic> data, {
    required String comicId,
    required String sourceKey,
    required bool perComic,
  }) {
    if (!perComic) {
      return ReaderOrientationMode.fromStorage(data[globalModeKey]);
    }
    final modes = data[comicModesKey];
    if (modes is! Map) return ReaderOrientationMode.automatic;
    return ReaderOrientationMode.fromStorage(
      modes[comicKey(comicId, sourceKey)],
    );
  }

  static void remember({
    required String comicId,
    required String sourceKey,
    required ReaderOrientationMode mode,
  }) {
    rememberInData(
      appdata.implicitData,
      comicId: comicId,
      sourceKey: sourceKey,
      mode: mode,
      perComic: perComic,
    );
    appdata.writeImplicitData();
  }

  static void rememberInData(
    Map<String, dynamic> data, {
    required String comicId,
    required String sourceKey,
    required ReaderOrientationMode mode,
    required bool perComic,
  }) {
    if (!perComic) {
      if (mode == ReaderOrientationMode.automatic) {
        data.remove(globalModeKey);
      } else {
        data[globalModeKey] = mode.name;
      }
      return;
    }

    final storedModes = data[comicModesKey];
    final modes = storedModes is Map
        ? Map<String, dynamic>.from(storedModes)
        : <String, dynamic>{};
    final key = comicKey(comicId, sourceKey);
    if (mode == ReaderOrientationMode.automatic) {
      modes.remove(key);
    } else {
      modes[key] = mode.name;
    }
    if (modes.isEmpty) {
      data.remove(comicModesKey);
    } else {
      data[comicModesKey] = modes;
    }
  }
}

class ReaderOrientationSystem {
  static int _operation = 0;

  static Future<void> apply(ReaderOrientationMode mode) {
    _operation++;
    return SystemChrome.setPreferredOrientations(mode.orientations);
  }

  static Future<void> restore({required bool wasPortrait}) async {
    final operation = ++_operation;
    await SystemChrome.setPreferredOrientations(
      wasPortrait
          ? ReaderOrientationMode.portrait.orientations
          : ReaderOrientationMode.landscape.orientations,
    );
    if (operation != _operation) return;

    // Give Android time to rotate back before releasing the orientation lock.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    if (operation != _operation) return;
    await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
  }
}
