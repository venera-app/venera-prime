import 'package:venera/utils/io.dart';

Future<void> atomicWriteString(File target, String content) async {
  final suffix = DateTime.now().microsecondsSinceEpoch;
  final temporary = File('${target.path}.$suffix.tmp');
  final backup = File('${target.path}.$suffix.bak');
  await temporary.parent.create(recursive: true);
  await temporary.writeAsString(content, flush: true);
  await atomicReplaceWithBackup(
    target: target,
    temporary: temporary,
    backup: backup,
  );
}

/// Replaces [target] with [temporary] while retaining enough state to restore
/// the previous file if the second rename fails.
Future<void> atomicReplaceWithBackup({
  required File target,
  required File temporary,
  required File backup,
  Future<File> Function(String source, String destination)? rename,
}) async {
  if (!await temporary.exists()) {
    throw StateError('Temporary file does not exist: ${temporary.path}');
  }

  await backup.deleteIgnoreError();
  final renameFile =
      rename ?? (source, destination) => File(source).rename(destination);
  var movedOldTarget = false;
  if (await target.exists()) {
    await renameFile(target.path, backup.path);
    movedOldTarget = true;
  }

  try {
    await renameFile(temporary.path, target.path);
  } catch (_) {
    if (movedOldTarget && !await target.exists() && await backup.exists()) {
      try {
        await renameFile(backup.path, target.path);
      } catch (_) {
        // Keep the backup in place when rollback itself cannot be completed.
      }
    }
    rethrow;
  }

  await backup.deleteIgnoreError();
}
