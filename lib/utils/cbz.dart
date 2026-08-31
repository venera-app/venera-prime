import 'dart:convert';
import 'package:xml/xml.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/utils/ext.dart';
import 'package:venera/utils/file_type.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/natural_sort.dart';
import 'package:venera/utils/archive_security.dart';
import 'package:zip_flutter/zip_flutter.dart';

class ComicMetaData {
  final String title;

  final String author;

  final String description;

  final List<String> tags;

  final List<ComicChapter>? chapters;

  Map<String, dynamic> toJson() => {
    'title': title,
    'author': author,
    'description': description,
    'tags': tags,
    'chapters': chapters?.map((e) => e.toJson()).toList(),
  };

  ComicMetaData.fromJson(Map<String, dynamic> json)
    : title = (json['title'] ?? json['Title'] ?? '').toString(),
      author = (json['author'] ?? json['作者'] ?? json['Author'] ?? '')
          .toString(),
      description = (json['description'] ?? json['summary'] ?? '').toString(),
      tags = (json['tags'] is List
          ? (json['tags'] as List).map((e) => e.toString()).toList()
          : json['tags'] is String
          ? (json['tags'] as String)
                .split(RegExp(r'[,;|]'))
                .map((e) => e.trim())
                .where((e) => e.isNotEmpty)
                .toList()
          : <String>[]),
      chapters = _parseChapters(json['chapters']);

  ComicMetaData({
    required this.title,
    required this.author,
    required this.tags,
    this.description = '',
    this.chapters,
  });

  static ComicMetaData fromComicInfoXml(
    String content, {
    String fallbackTitle = '',
  }) {
    final document = XmlDocument.parse(content);
    String read(String name) {
      final values = document.descendants
          .whereType<XmlElement>()
          .where((element) => element.localName == name)
          .map((element) => element.innerText.trim())
          .where((value) => value.isNotEmpty)
          .toList();
      return values.join(', ');
    }

    final genres = read('Genre')
        .split(RegExp(r'[,;]'))
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toList();
    final title = read('Title');
    final writer = read('Writer');
    final notes = read('Notes');
    return ComicMetaData(
      title: title.isEmpty ? fallbackTitle : title,
      author: writer.isEmpty ? read('Penciller') : writer,
      description: read('Summary'),
      tags: genres,
      chapters: _parseChapterNotes(notes),
    );
  }

  static List<ComicChapter>? _parseChapters(dynamic value) {
    if (value is! List) return null;
    final result = <ComicChapter>[];
    for (final item in value) {
      if (item is! Map) continue;
      try {
        result.add(ComicChapter.fromJson(Map<String, dynamic>.from(item)));
      } catch (_) {
        // Ignore one malformed chapter while keeping the rest of the archive usable.
      }
    }
    return result.isEmpty ? null : result;
  }

  static List<ComicChapter>? _parseChapterNotes(String notes) {
    final marker = notes.indexOf('Chapters:');
    if (marker < 0) return null;
    final result = <ComicChapter>[];
    final content = notes.substring(marker + 'Chapters:'.length);
    final pattern = RegExp(r'(.+):\s*(\d+)\s*-\s*(\d+)');
    for (final item in content.split(';')) {
      final match = pattern.firstMatch(item.trim());
      if (match == null) continue;
      result.add(
        ComicChapter(
          title: match.group(1)!.trim(),
          start: int.parse(match.group(2)!),
          end: int.parse(match.group(3)!),
        ),
      );
    }
    return result.isEmpty ? null : result;
  }
}

class ComicChapter {
  final String title;

  final int start;

  final int end;

  Map<String, dynamic> toJson() => {'title': title, 'start': start, 'end': end};

  ComicChapter.fromJson(Map<String, dynamic> json)
    : title = (json['title'] ?? json['name'] ?? '').toString(),
      start = int.parse((json['start'] ?? json['startPage']).toString()),
      end = int.parse((json['end'] ?? json['endPage']).toString());

  ComicChapter({required this.title, required this.start, required this.end});
}

/// Comic Book Archive. Currently supports CBZ, ZIP and 7Z formats.
abstract class CBZ {
  static Future<FileType> checkType(File file) async {
    var header = <int>[];
    await for (var bytes in file.openRead()) {
      header.addAll(bytes);
      if (header.length >= 32) break;
    }
    return detectFileType(header);
  }

  static Future<void> extractArchive(File file, Directory out) async {
    await ArchiveSecurity.extract(file, out);
  }

  static Future<LocalComic> import(File file) async {
    final extractionRoot = Directory(
      FilePath.join(
        App.cachePath,
        'cbz_import_${DateTime.now().microsecondsSinceEpoch}',
      ),
    );
    try {
      return await _importFromDirectory(file, extractionRoot);
    } finally {
      await extractionRoot.deleteIgnoreError(recursive: true);
    }
  }

  static Future<LocalComic> _importFromDirectory(
    File file,
    Directory extractionRoot,
  ) async {
    var cache = extractionRoot;
    await cache.create(recursive: true);
    await extractArchive(file, cache);
    var f = cache.listSync();
    if (f.length == 1 && f.first is Directory) {
      cache = f.first as Directory;
    }
    final extractedFiles = cache.listSync(recursive: true).whereType<File>();
    File? findMetadata(String name) {
      for (final candidate in extractedFiles) {
        if (candidate.name.toLowerCase() == name.toLowerCase()) {
          return candidate;
        }
      }
      return null;
    }

    var metaDataFile = findMetadata('metadata.json');
    ComicMetaData? metaData;
    if (metaDataFile != null && metaDataFile.existsSync()) {
      try {
        metaData = ComicMetaData.fromJson(
          jsonDecode(metaDataFile.readAsStringSync()),
        );
      } catch (_) {}
    }
    if (metaData == null) {
      final comicInfo = findMetadata('ComicInfo.xml');
      if (comicInfo != null && comicInfo.existsSync()) {
        try {
          metaData = ComicMetaData.fromComicInfoXml(
            comicInfo.readAsStringSync(),
            fallbackTitle: file.basenameWithoutExt,
          );
        } catch (_) {
          // A malformed optional metadata file must not make a valid archive unreadable.
        }
      }
    }
    metaData ??= ComicMetaData(
      title: file.basenameWithoutExt,
      author: "",
      tags: [],
    );
    var old = LocalManager().findByName(metaData.title);
    if (old != null) {
      throw Exception('Comic with name ${metaData.title} already exists');
    }
    var files = cache.listSync(recursive: true).whereType<File>().toList();
    files.removeWhere((e) {
      var ext = e.path.split('.').last;
      return ![
        'jpg',
        'jpeg',
        'png',
        'webp',
        'gif',
        'jpe',
        'avif',
        'bmp',
      ].contains(ext.toLowerCase());
    });
    if (files.isEmpty) {
      cache.deleteSync(recursive: true);
      throw Exception('No images found in the archive');
    }
    files.sort((a, b) => naturalCompare(a.path, b.path));
    var coverFile = files.firstWhereOrNull(
      (element) => element.basenameWithoutExt.toLowerCase() == 'cover',
    );
    if (coverFile != null) {
      files.remove(coverFile);
    } else {
      coverFile = files.first;
    }
    if (metaData.chapters != null &&
        metaData.chapters!.any(
          (chapter) =>
              chapter.start < 1 ||
              chapter.start > chapter.end ||
              chapter.end > files.length,
        )) {
      throw const FormatException(
        'Comic metadata contains an invalid chapter range',
      );
    }

    Map<String, String>? cpMap;
    var dest = Directory(
      FilePath.join(LocalManager().path, sanitizeFileName(metaData.title)),
    );
    var destinationCreated = false;
    try {
      dest.createSync();
      destinationCreated = true;
      await coverFile.copyMem(
        FilePath.join(dest.path, 'cover.${coverFile.extension}'),
      );
      if (metaData.chapters == null) {
        for (var i = 0; i < files.length; i++) {
          var src = files[i];
          var dst = File(
            FilePath.join(dest.path, '${i + 1}.${src.path.split('.').last}'),
          );
          await src.copyMem(dst.path);
        }
      } else {
        var chapters = <String, List<File>>{};
        for (var chapter in metaData.chapters!) {
          chapters[chapter.title] = files.sublist(
            chapter.start - 1,
            chapter.end,
          );
        }
        int i = 0;
        cpMap = <String, String>{};
        for (var chapter in chapters.entries) {
          cpMap[i.toString()] = chapter.key;
          var chapterDir = Directory(FilePath.join(dest.path, i.toString()));
          chapterDir.createSync();
          for (var i = 0; i < chapter.value.length; i++) {
            var src = chapter.value[i];
            var dst = File(
              FilePath.join(
                chapterDir.path,
                '${i + 1}.${src.path.split('.').last}',
              ),
            );
            await src.copyMem(dst.path);
          }
        }
      }
    } catch (_) {
      if (destinationCreated) {
        await dest.deleteIgnoreError(recursive: true);
      }
      rethrow;
    }
    var comic = LocalComic(
      id: LocalManager().findValidId(ComicType.local),
      title: metaData.title,
      subtitle: metaData.author,
      descriptionText: metaData.description,
      tags: metaData.tags,
      comicType: ComicType.local,
      directory: dest.name,
      chapters: ComicChapters.fromJsonOrNull(cpMap),
      downloadedChapters: cpMap?.keys.toList() ?? [],
      cover: 'cover.${coverFile.extension}',
      createdAt: DateTime.now(),
    );
    return comic;
  }

  static Future<File> export(LocalComic comic, String outFilePath) async {
    var cache = Directory(FilePath.join(App.cachePath, 'cbz_export'));
    if (cache.existsSync()) cache.deleteSync(recursive: true);
    cache.createSync();
    List<ComicChapter>? chapters;
    if (comic.chapters == null) {
      var images = await LocalManager().getImages(comic.id, comic.comicType, 1);
      int i = 1;
      for (var image in images) {
        var src = File(image.replaceFirst('file://', ''));
        var width = images.length.toString().length;
        var dstName =
            '${i.toString().padLeft(width, '0')}.${image.split('.').last}';
        var dst = File(FilePath.join(cache.path, dstName));
        await src.copyMem(dst.path);
        i++;
      }
    } else {
      chapters = [];
      var allImages = <String>[];
      for (var c in comic.downloadedChapters) {
        var chapterName = comic.chapters![c];
        var images = await LocalManager().getImages(
          comic.id,
          comic.comicType,
          c,
        );
        allImages.addAll(images);
        var chapter = ComicChapter(
          title: chapterName!,
          start: chapters.length + 1,
          end: chapters.length + images.length,
        );
        chapters.add(chapter);
      }
      int i = 1;
      for (var image in allImages) {
        var src = File(image);
        var width = allImages.length.toString().length;
        var dstName =
            '${i.toString().padLeft(width, '0')}.${image.split('.').last}';
        var dst = File(FilePath.join(cache.path, dstName));
        await src.copyMem(dst.path);
        i++;
      }
    }
    var cover = comic.coverFile;
    await cover.copyMem(
      FilePath.join(cache.path, 'cover.${cover.path.split('.').last}'),
    );
    final metaData = ComicMetaData(
      title: comic.title,
      author: comic.subtitle,
      description: comic.description,
      tags: comic.tags,
      chapters: chapters,
    );
    await File(
      FilePath.join(cache.path, 'metadata.json'),
    ).writeAsString(jsonEncode(metaData));
    await File(
      FilePath.join(cache.path, 'ComicInfo.xml'),
    ).writeAsString(_buildComicInfoXml(metaData));
    var cbz = File(outFilePath);
    if (cbz.existsSync()) cbz.deleteSync();
    await _compress(cache.path, cbz.path);
    cache.deleteSync(recursive: true);
    return cbz;
  }

  static String _buildComicInfoXml(ComicMetaData data) {
    final buffer = StringBuffer();
    buffer.writeln('<?xml version="1.0" encoding="utf-8"?>');
    buffer.writeln(
      '<ComicInfo xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">',
    );

    buffer.writeln('  <Title>${_escapeXml(data.title)}</Title>');
    buffer.writeln('  <Series>${_escapeXml(data.title)}</Series>');

    if (data.author.isNotEmpty) {
      buffer.writeln('  <Writer>${_escapeXml(data.author)}</Writer>');
    }
    if (data.description.isNotEmpty) {
      buffer.writeln('  <Summary>${_escapeXml(data.description)}</Summary>');
    }

    if (data.tags.isNotEmpty) {
      var tags = data.tags;
      if (tags.length > 5) {
        tags = tags.sublist(0, 5);
      }
      buffer.writeln('  <Genre>${_escapeXml(tags.join(', '))}</Genre>');
    }

    if (data.chapters != null && data.chapters!.isNotEmpty) {
      final chaptersInfo = data.chapters!
          .map(
            (chapter) =>
                '${_escapeXml(chapter.title)}: ${chapter.start}-${chapter.end}',
          )
          .join('; ');
      buffer.writeln('  <Notes>Chapters: $chaptersInfo</Notes>');
    }

    buffer.writeln('  <Manga>Unknown</Manga>');
    buffer.writeln('  <BlackAndWhite>Unknown</BlackAndWhite>');

    final now = DateTime.now();
    buffer.writeln('  <Year>${now.year}</Year>');

    buffer.writeln('</ComicInfo>');
    return buffer.toString();
  }

  static String _escapeXml(String text) {
    return text
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&apos;');
  }

  static _compress(String src, String dst) async {
    await ZipFile.compressFolderAsync(src, dst, 4);
  }
}
