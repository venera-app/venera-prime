import 'package:flutter/material.dart';
import 'package:venera/foundation/appdata.dart';

Color readerBackgroundColor(
  BuildContext context,
  String comicId,
  String sourceKey,
) {
  final key = appdata.settings.getReaderSetting(
    comicId,
    sourceKey,
    'readerBackground',
  );
  return switch (key) {
    'white' => Colors.white,
    'gray' => const Color(0xffd0d0d0),
    'black' => Colors.black,
    'sepia' => const Color(0xfff1e4c3),
    _ => Theme.of(context).colorScheme.surface,
  };
}
