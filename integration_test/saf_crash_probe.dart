// Manual, isolated Android crash probe. See doc/issue43-saf-regression-2026-11-06.md.
import 'dart:io';
import 'dart:isolate';
import 'package:flutter/material.dart';
import 'package:flutter_saf/flutter_saf.dart';
import 'package:path_provider/path_provider.dart';
import 'package:venera/utils/io.dart' show overrideIO;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!const bool.fromEnvironment('PRIME_SAF_CRASH_PROBE')) {
    throw StateError('Manual crash probe must be explicitly enabled');
  }
  final status = ValueNotifier<String>('Starting isolated SAF probe');
  runApp(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: ValueListenableBuilder(
            valueListenable: status,
            builder: (_, text, _) => Text(text),
          ),
        ),
      ),
    ),
  );
  final root = const bool.fromEnvironment('PRIME_SAF_EXTERNAL_LOG')
      ? (await getExternalStorageDirectory())!
      : await getApplicationSupportDirectory();
  final log = File('${root.path}/saf-probe.log');
  void record(String text) {
    final line = '${DateTime.now().toIso8601String()} $text';
    log.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
    status.value = text;
  }

  record(
    'START pid=$pid build=${const String.fromEnvironment('PRIME_SAF_BUILD_LABEL', defaultValue: 'old')}',
  );
  if (const bool.fromEnvironment('PRIME_SAF_STORAGE_STRESS')) {
    try {
      await stressStorage(record);
    } catch (error, stack) {
      record("DART ERROR: $error\n$stack");
    }
    return;
  }
  await Future.wait(
    List.generate(
      32,
      (i) => Isolate.run(() {
        AndroidDirectory.fromPathSync('android://primary:prime-saf-missing');
        // Keep workers occupied so they cannot all reuse the same OS thread.
        sleep(const Duration(milliseconds: 500));
      }),
    ),
  );
  record('32 concurrent JNI workers returned; waiting 180 seconds');
  for (var second = 0; second < 180; second++) {
    await Future<void>.delayed(const Duration(seconds: 1));
    if (second % 15 == 14) record('ALIVE after ${second + 1}s');
  }
  record('PASS idle worker retirement');
}

Future<void> stressStorage(void Function(String) record) async {
  await SAFTaskWorker().init();
  record('Select dedicated SAF stress folder');
  final picked = await AndroidDirectory.pickDirectory();
  if (picked == null) throw StateError('No folder selected');
  final path = '${picked.path}/stress-${DateTime.now().millisecondsSinceEpoch}';
  await overrideIO(() async {
    final directory = Directory(path)..createSync();
    final bytes = List<int>.generate(8192, (i) => i % 251);
    for (var chapter = 0; chapter < 12; chapter++) {
      final folder = Directory('$path/chapter$chapter')..createSync();
      for (var page = 0; page < 32; page++) {
        File('${folder.path}/$page.jpg').writeAsBytesSync(bytes);
      }
      record('Created chapter $chapter');
    }
    for (
      var round = 0;
      round <
          const int.fromEnvironment('PRIME_SAF_STRESS_ROUNDS', defaultValue: 8);
      round++
    ) {
      final counts = await Future.wait(
        List.generate(4, (_) => scanInIsolate(path)),
      );
      record('Round $round: $counts');
    }
    const idleSeconds = int.fromEnvironment(
      'PRIME_SAF_IDLE_SECONDS',
      defaultValue: 180,
    );
    record('STRESS COMPLETE; idle ${idleSeconds}s');
    for (var i = 0; i < idleSeconds ~/ 15; i++) {
      await Future<void>.delayed(const Duration(seconds: 15));
      record('STRESS ALIVE after ${(i + 1) * 15}s');
    }
    directory.deleteSync(recursive: true);
    record('SURVIVED SAF stress and idle; review I/O counts separately');
  });
}

Future<String> scanInIsolate(String path) => Isolate.run(
  () => overrideIO(() {
    var files = 0;
    var failures = 0;
    for (final entity in Directory(path).listSync(recursive: true)) {
      if (entity is! File) continue;
      files++;
      try {
        if (entity.lengthSync() != 8192) failures++;
        if (File(entity.path).readAsBytesSync().length != 8192) failures++;
      } catch (_) {
        failures++;
      }
    }
    // Pressure Dart GC so temporary SAF wrappers release native handles.
    var checksum = 0;
    for (var i = 0; i < 12; i++) {
      final garbage = List<int>.filled(256 * 1024, i);
      checksum += garbage.last;
    }
    return '$files files / $failures errors / checksum $checksum';
  }),
);
