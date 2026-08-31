import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart' as archive_pkg;
import 'package:path/path.dart' as path_utils;
import 'package:flutter_7zip/flutter_7zip.dart' as seven_zip;
import 'package:zip_flutter/zip_flutter.dart' deferred as zip_flutter;

/// Bounded archive extraction used for untrusted downloads and imports.
///
/// Extraction always happens into a staging directory. Callers should only
/// publish that directory after their own validation succeeds.
abstract final class ArchiveSecurity {
  static const maxEntries = 20000;
  static const maxSingleFileBytes = 256 * 1024 * 1024;
  static const maxTotalBytes = 1024 * 1024 * 1024;
  static const maxCompressionRatio = 1000;
  static const maxArchiveBytes = 512 * 1024 * 1024;

  static String safeTarget(String root, String archiveName) {
    final normalized = archiveName.replaceAll('\\', '/');
    if (normalized.isEmpty || normalized.contains('\u0000')) {
      throw const FormatException('Archive contains an invalid entry name');
    }
    if (normalized.startsWith('/') ||
        normalized.startsWith('//') ||
        RegExp(r'^[A-Za-z]:').hasMatch(normalized)) {
      throw const FormatException('Archive contains an absolute entry path');
    }
    final segments = normalized.split('/');
    if (segments.any((segment) => segment == '..')) {
      throw const FormatException('Archive contains a parent entry path');
    }
    final canonicalRoot = path_utils.canonicalize(root);
    final target = path_utils.canonicalize(
      path_utils.join(canonicalRoot, normalized),
    );
    if (target != canonicalRoot &&
        !path_utils.isWithin(canonicalRoot, target)) {
      throw const FormatException('Archive entry escapes extraction directory');
    }
    return target;
  }

  static void _checkLimits({
    required int entries,
    required int totalBytes,
    required int archiveBytes,
  }) {
    if (entries > maxEntries) {
      throw const FormatException('Archive contains too many entries');
    }
    if (totalBytes > maxTotalBytes) {
      throw const FormatException('Archive expands beyond the allowed size');
    }
    if (archiveBytes > maxArchiveBytes) {
      throw const FormatException('Archive is too large');
    }
    if (archiveBytes > 0 && totalBytes > archiveBytes * maxCompressionRatio) {
      throw const FormatException('Archive compression ratio is unsafe');
    }
  }

  static void _checkExistingPath(String root, String target) {
    var current = target;
    final canonicalRoot = path_utils.canonicalize(root);
    while (true) {
      final type = FileSystemEntity.typeSync(current, followLinks: false);
      if (type == FileSystemEntityType.link) {
        throw const FormatException('Archive extraction encountered a symlink');
      }
      if (current == canonicalRoot) break;
      final parent = path_utils.dirname(current);
      if (parent == current) break;
      current = parent;
    }
  }

  static Future<void> extractZip(File input, Directory output) async {
    final archiveBytes = await input.length();
    if (archiveBytes > maxArchiveBytes) {
      throw const FormatException('Archive is too large');
    }
    final bytes = await input.readAsBytes();
    final archive = archive_pkg.ZipDecoder().decodeBytes(bytes);
    final root = path_utils.canonicalize(output.path);
    final seen = <String>{};
    dynamic nativeArchive;
    final verifiedSizes = <String, int>{};
    // Some Android-produced ZIPs expose zero uncompressed sizes through the
    // Dart decoder. Read the central-directory metadata from the native reader
    // before applying expansion limits or extracting those entries.
    if (Platform.isAndroid &&
        archive.any((entry) => !entry.isDirectory && entry.size == 0)) {
      await zip_flutter.loadLibrary();
      nativeArchive = zip_flutter.ZipFile.openRead(input.path);
      for (final entry in archive) {
        if (entry.isDirectory) continue;
        final nativeEntry = nativeArchive.getEntryByName(entry.name);
        verifiedSizes[entry.name] = entry.size > 0
            ? entry.size
            : nativeEntry.size;
      }
    }
    var total = 0;
    for (final entry in archive) {
      final target = safeTarget(root, entry.name);
      if (!seen.add(target)) {
        throw const FormatException('Archive contains duplicate entry names');
      }
      final size = verifiedSizes[entry.name] ?? entry.size;
      if (size > maxSingleFileBytes) {
        throw const FormatException('Archive entry is too large');
      }
      if (!entry.isDirectory) total += size;
    }
    _checkLimits(
      entries: archive.length,
      totalBytes: total,
      archiveBytes: archiveBytes,
    );
    await output.create(recursive: true);
    try {
      for (var index = 0; index < archive.length; index++) {
        final entry = archive[index];
        final target = safeTarget(root, entry.name);
        _checkExistingPath(root, target);
        if (entry.isSymbolicLink) {
          throw const FormatException('Archive symlinks are not supported');
        }
        if (entry.isDirectory) {
          await Directory(target).create(recursive: true);
          continue;
        }
        final expectedSize = verifiedSizes[entry.name] ?? entry.size;
        Uint8List? content;
        var extractedByNative = false;
        try {
          content = entry.readBytes();
        } catch (_) {
          content = null;
        }
        // zip_flutter creates valid archives whose entries may not be readable
        // through archive's lazy FileContent implementation on Android.
        if (content == null || content.length != expectedSize) {
          await zip_flutter.loadLibrary();
          nativeArchive ??= zip_flutter.ZipFile.openRead(input.path);
          // Do not couple two ZIP readers by their entry indexes. Readers
          // may represent directory or duplicate entries differently.
          final nativeEntry = nativeArchive.getEntryByName(entry.name);
          final targetFile = File(target);
          await targetFile.parent.create(recursive: true);
          nativeEntry.writeToFile(target);
          extractedByNative = true;
          final actualLength = await targetFile.length();
          if (actualLength != expectedSize) {
            throw FormatException(
              'Archive entry size mismatch: expected $expectedSize, got $actualLength',
            );
          }
        }
        if (extractedByNative) continue;
        if (content == null || content.length != expectedSize) {
          throw const FormatException('Archive entry could not be read');
        }
        final targetFile = File(target);
        await targetFile.parent.create(recursive: true);
        await targetFile.writeAsBytes(content, flush: true);
      }
    } finally {
      nativeArchive?.close();
    }
  }

  static Future<void> extract7z(File input, Directory output) async {
    final archive = seven_zip.SZArchive.open(input.path);
    try {
      final root = path_utils.canonicalize(output.path);
      final seen = <String>{};
      var total = 0;
      for (var i = 0; i < archive.numFiles; i++) {
        final entry = archive.getFile(i);
        final target = safeTarget(root, entry.name);
        if (!seen.add(target)) {
          throw const FormatException('Archive contains duplicate entry names');
        }
        if (!entry.isDirectory) {
          if (entry.size > maxSingleFileBytes) {
            throw const FormatException('Archive entry is too large');
          }
          total += entry.size;
        }
      }
      final archiveBytes = await input.length();
      _checkLimits(
        entries: archive.numFiles,
        totalBytes: total,
        archiveBytes: archiveBytes,
      );
      await output.create(recursive: true);
      for (var i = 0; i < archive.numFiles; i++) {
        final entry = archive.getFile(i);
        final target = safeTarget(root, entry.name);
        _checkExistingPath(root, target);
        if (entry.isDirectory) {
          await Directory(target).create(recursive: true);
          continue;
        }
        await Directory(path_utils.dirname(target)).create(recursive: true);
        archive.extractToFile(i, target);
        if (FileSystemEntity.typeSync(target, followLinks: false) ==
            FileSystemEntityType.link) {
          throw const FormatException('Archive symlinks are not supported');
        }
        final actualLength = await File(target).length();
        if (actualLength != entry.size) {
          throw const FormatException('Archive entry size mismatch');
        }
      }
    } finally {
      archive.dispose();
    }
  }

  static Future<void> extract(File input, Directory output) async {
    final header = await input
        .openRead(0, 32)
        .fold<List<int>>(<int>[], (all, chunk) => all..addAll(chunk));
    final name = input.path.toLowerCase();
    if (header.length >= 2 && header[0] == 0x50 && header[1] == 0x4b) {
      await extractZip(input, output);
    } else if (name.endsWith('.7z') ||
        (header.length >= 6 &&
            header[0] == 0x37 &&
            header[1] == 0x7a &&
            header[2] == 0xbc &&
            header[3] == 0xaf &&
            header[4] == 0x27 &&
            header[5] == 0x1c)) {
      await extract7z(input, output);
    } else {
      throw const FormatException('Unsupported archive type');
    }
  }
}
