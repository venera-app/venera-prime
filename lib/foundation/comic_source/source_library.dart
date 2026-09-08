import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';

T? _firstOrNull<T>(Iterable<T> values) {
  final iterator = values.iterator;
  return iterator.moveNext() ? iterator.current : null;
}

/// A remote catalog of comic-source scripts.
class ComicSourceLibrary {
  ComicSourceLibrary({
    required this.id,
    required this.name,
    required this.url,
    this.enabled = true,
    this.priority = 0,
    this.lastChecked,
  });

  final String id;
  String name;
  String url;
  bool enabled;
  int priority;
  int? lastChecked;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'url': url,
    'enabled': enabled,
    'priority': priority,
    'lastChecked': lastChecked,
  };

  factory ComicSourceLibrary.fromJson(Map<String, dynamic> json) {
    final url = json['url']?.toString() ?? '';
    return ComicSourceLibrary(
      id: json['id']?.toString() ?? stableLibraryId(url),
      name: json['name']?.toString() ?? defaultLibraryName(url),
      url: url,
      enabled: json['enabled'] != false,
      priority: json['priority'] is num ? (json['priority'] as num).toInt() : 0,
      lastChecked: json['lastChecked'] is num
          ? (json['lastChecked'] as num).toInt()
          : null,
    );
  }
}

/// Records where an installed source was obtained and which catalogs offer it.
class SourceProvenance {
  SourceProvenance({
    List<String>? libraryIds,
    this.originId,
    this.updateLibraryId,
    this.sourceFileName,
  }) : libraryIds = libraryIds ?? [];

  List<String> libraryIds;
  String? originId;
  String? updateLibraryId;
  String? sourceFileName;

  Map<String, dynamic> toJson() => {
    'libraryIds': libraryIds,
    'originId': originId,
    'updateLibraryId': updateLibraryId,
    'sourceFileName': sourceFileName,
  };

  factory SourceProvenance.fromJson(Map<String, dynamic> json) {
    return SourceProvenance(
      libraryIds: json['libraryIds'] is List
          ? (json['libraryIds'] as List).whereType<String>().toList()
          : [],
      originId: json['originId']?.toString(),
      updateLibraryId: json['updateLibraryId']?.toString(),
      sourceFileName: json['sourceFileName']?.toString(),
    );
  }
}

String canonicalLibraryUrl(String url) {
  final trimmed = url.trim();
  if (trimmed.isEmpty) return 'empty';
  final uri = Uri.tryParse(trimmed);
  if (uri == null || uri.scheme.isEmpty || uri.host.isEmpty) {
    return trimmed.replaceFirst(RegExp(r'/+$'), '');
  }
  final pathSegments = uri.pathSegments.toList();
  while (pathSegments.isNotEmpty && pathSegments.last.isEmpty) {
    pathSegments.removeLast();
  }
  return uri
      .replace(
        scheme: uri.scheme.toLowerCase(),
        host: uri.host.toLowerCase(),
        pathSegments: pathSegments,
      )
      .toString();
}

String stableLibraryId(String url) => md5
    .convert(utf8.encode(canonicalLibraryUrl(url)))
    .toString()
    .substring(0, 12);

String defaultLibraryName(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || uri.host.isEmpty) return url.trim();
  final segments = uri.pathSegments
      .where((s) => s.isNotEmpty && !s.toLowerCase().endsWith('.json'))
      .toList();
  return segments.isEmpty ? uri.host : '${uri.host}/${segments.last}';
}

bool isHttpSourceUrl(String value) {
  final uri = Uri.tryParse(value.trim());
  return uri != null &&
      (uri.scheme == 'http' || uri.scheme == 'https') &&
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty;
}

String? resolveSourceDownloadUrl({
  String? url,
  String? fileName,
  required String listUrl,
}) {
  final base = Uri.tryParse(listUrl);
  if (base == null || !isHttpSourceUrl(listUrl)) return null;
  final candidate = url?.trim().isNotEmpty == true ? url!.trim() : fileName;
  if (candidate == null || candidate.trim().isEmpty) return null;
  final uri = Uri.tryParse(candidate.trim());
  if (uri == null) return null;
  final resolved = base.resolveUri(uri).toString();
  return isHttpSourceUrl(resolved) ? resolved : null;
}

@visibleForTesting
String allocateLibraryId(String url, Iterable<String> usedIds) {
  final used = usedIds.toSet();
  final bytes = utf8.encode(canonicalLibraryUrl(url));
  final md5Value = md5.convert(bytes).toString();
  for (final candidate in [
    md5Value.substring(0, 12),
    md5Value,
    sha256.convert(bytes).toString(),
  ]) {
    if (!used.contains(candidate)) return candidate;
  }
  throw StateError('Unable to allocate a unique source library id');
}

ComicSourceLibrary? findLibraryByUrl(
  Iterable<ComicSourceLibrary> libraries,
  String url,
) {
  final canonical = canonicalLibraryUrl(url);
  return _firstOrNull(
    libraries.where((library) => canonicalLibraryUrl(library.url) == canonical),
  );
}

/// Persists source catalogs and source-to-catalog provenance in appdata.
class ComicSourceLibraryManager {
  static bool isUnbound(String sourceKey) {
    final origin = provenanceFor(sourceKey)?.originId;
    return origin == null || find(origin) == null;
  }

  static Future<void> bindUnassignedSource({
    required String sourceKey,
    required String libraryId,
    required String sourceFileName,
  }) async {
    final library = find(libraryId);
    if (library == null || !library.enabled || !isUnbound(sourceKey)) {
      throw StateError('Source binding is no longer available');
    }
    if (sourceFileName.isEmpty || sourceFileName.contains('/')) {
      throw ArgumentError('Invalid source file name');
    }
    final map = _provenanceMap();
    final previous = Map<String, dynamic>.from(map);
    final value = provenanceFor(sourceKey) ?? SourceProvenance();
    value.originId = libraryId;
    value.updateLibraryId = libraryId;
    value.sourceFileName = sourceFileName;
    if (!value.libraryIds.contains(libraryId)) value.libraryIds.add(libraryId);
    map[sourceKey] = value.toJson();
    appdata.settings[provenanceKey] = map;
    ComicSourceManager().clearUpdateCandidates();
    try {
      await appdata.saveData();
    } catch (_) {
      appdata.settings[provenanceKey] = previous;
      rethrow;
    }
  }

  static const librariesKey = 'comicSourceLibraries';
  static const provenanceKey = 'comicSourceProvenance';

  static List<ComicSourceLibrary> all() {
    final raw = appdata.settings[librariesKey];
    if (raw is! List) return [];
    final result = raw
        .whereType<Map>()
        .map((e) => ComicSourceLibrary.fromJson(Map<String, dynamic>.from(e)))
        .toList();
    result.sort((a, b) => a.priority.compareTo(b.priority));
    return result;
  }

  static List<ComicSourceLibrary> enabled() => all()
      .where((library) => library.enabled && library.url.isNotEmpty)
      .toList();

  static ComicSourceLibrary? find(String id) =>
      _firstOrNull(all().where((library) => library.id == id));

  static void save(List<ComicSourceLibrary> libraries) {
    for (var i = 0; i < libraries.length; i++) {
      libraries[i].priority = i;
    }
    appdata.settings[librariesKey] = libraries.map((e) => e.toJson()).toList();
    appdata.settings['comicSourceLibrariesMigrated'] = true;
    ComicSourceManager().clearUpdateCandidates();
    appdata.saveData();
  }

  static ComicSourceLibrary add(String name, String url) {
    if (!isHttpSourceUrl(url)) throw ArgumentError('Invalid catalog URL');
    final libraries = all();
    final existing = findLibraryByUrl(libraries, url);
    if (existing != null) {
      if (name.trim().isNotEmpty) existing.name = name.trim();
      save(libraries);
      return existing;
    }
    final library = ComicSourceLibrary(
      id: allocateLibraryId(url, libraries.map((e) => e.id)),
      name: name.trim().isEmpty ? defaultLibraryName(url) : name.trim(),
      url: url.trim(),
      priority: libraries.length,
    );
    libraries.add(library);
    save(libraries);
    return library;
  }

  static void edit(String id, {String? name, String? url}) {
    final libraries = all();
    if (url != null) {
      final existing = findLibraryByUrl(libraries, url);
      if (!isHttpSourceUrl(url) || (existing != null && existing.id != id)) {
        throw ArgumentError('Invalid or duplicate catalog URL');
      }
    }
    final library = _firstOrNull(libraries.where((e) => e.id == id));
    if (library == null) return;
    if (url != null && url.trim().isNotEmpty) library.url = url.trim();
    if (name != null) {
      library.name = name.trim().isEmpty
          ? defaultLibraryName(library.url)
          : name.trim();
    }
    save(libraries);
  }

  static void setEnabled(String id, bool enabled) {
    final libraries = all();
    final library = _firstOrNull(libraries.where((e) => e.id == id));
    if (library == null) return;
    library.enabled = enabled;
    save(libraries);
  }

  static void reorder(int oldIndex, int newIndex) {
    final libraries = all();
    if (oldIndex < 0 || oldIndex >= libraries.length) return;
    final item = libraries.removeAt(oldIndex);
    libraries.insert(newIndex.clamp(0, libraries.length), item);
    save(libraries);
  }

  static void remove(String id) {
    final libraries = all()..removeWhere((e) => e.id == id);
    final provenance = _provenanceMap();
    for (final entry in provenance.entries.toList()) {
      if (entry.value is! Map) continue;
      final value = SourceProvenance.fromJson(
        Map<String, dynamic>.from(entry.value as Map),
      );
      value.libraryIds.remove(id);
      if (value.originId == id) value.originId = null;
      if (value.updateLibraryId == id) {
        value.updateLibraryId = value.libraryIds.isEmpty
            ? null
            : value.libraryIds.first;
      }
      provenance[entry.key] = value.toJson();
    }
    appdata.settings[provenanceKey] = provenance;
    save(libraries);
  }

  static SourceProvenance? provenanceFor(String sourceKey) {
    final value = _provenanceMap()[sourceKey];
    if (value is! Map) return null;
    return SourceProvenance.fromJson(Map<String, dynamic>.from(value));
  }

  static void setProvenance(String sourceKey, SourceProvenance provenance) {
    final map = _provenanceMap();
    map[sourceKey] = provenance.toJson();
    appdata.settings[provenanceKey] = map;
    appdata.saveData();
  }

  static void setProvenanceBatch(Map<String, SourceProvenance> values) {
    if (values.isEmpty) return;
    final map = _provenanceMap();
    values.forEach((key, value) => map[key] = value.toJson());
    appdata.settings[provenanceKey] = map;
    appdata.saveData(false);
  }

  static void markChecked(String id) {
    final libraries = all();
    final library = _firstOrNull(libraries.where((e) => e.id == id));
    if (library == null) return;
    library.lastChecked = DateTime.now().millisecondsSinceEpoch;
    appdata.settings[librariesKey] = libraries.map((e) => e.toJson()).toList();
    appdata.saveData(false);
  }

  static void recordOrigin(
    String sourceKey,
    String libraryId, {
    String? sourceFileName,
  }) {
    final value = provenanceFor(sourceKey) ?? SourceProvenance();
    value.originId = libraryId;
    value.updateLibraryId = libraryId;
    value.sourceFileName = sourceFileName ?? value.sourceFileName;
    if (!value.libraryIds.contains(libraryId)) value.libraryIds.add(libraryId);
    setProvenance(sourceKey, value);
  }

  static void clearProvenance(String sourceKey) {
    final map = _provenanceMap();
    if (map.remove(sourceKey) != null) {
      appdata.settings[provenanceKey] = map;
      appdata.saveData();
    }
  }

  /// Creates a library for the old single-catalog setting without changing it.
  static void migrateLegacy() {
    if (appdata.settings['comicSourceLibrariesMigrated'] == true) return;
    appdata.settings['comicSourceLibrariesMigrated'] = true;
    final legacy =
        appdata.settings['comicSourceListUrl']?.toString().trim() ?? '';
    if (!isHttpSourceUrl(legacy) || findLibraryByUrl(all(), legacy) != null) {
      appdata.saveData(false);
      return;
    }
    final libraries = all();
    libraries.add(
      ComicSourceLibrary(
        id: allocateLibraryId(legacy, libraries.map((e) => e.id)),
        name: defaultLibraryName(legacy),
        url: legacy,
        priority: libraries.length,
      ),
    );
    appdata.settings[librariesKey] = libraries.map((e) => e.toJson()).toList();
    appdata.saveData(false);
  }

  static Map<String, dynamic> _provenanceMap() {
    final raw = appdata.settings[provenanceKey];
    return raw is Map ? Map<String, dynamic>.from(raw) : {};
  }
}
