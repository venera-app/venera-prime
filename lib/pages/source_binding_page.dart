import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_source/source_library.dart';
import 'package:venera/network/app_dio.dart';
import 'package:venera/utils/translations.dart';

class SourceBindingPage extends StatefulWidget {
  const SourceBindingPage({super.key});

  @override
  State<SourceBindingPage> createState() => _SourceBindingPageState();
}

class _SourceBindingPageState extends State<SourceBindingPage> {
  String? busyKey;

  Future<void> _bind(ComicSource source) async {
    final libraries = ComicSourceLibraryManager.enabled();
    if (libraries.isEmpty) {
      context.showMessage(message: 'No enabled source libraries'.tl);
      return;
    }
    final library = await showDialog<ComicSourceLibrary>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('Select source library'.tl),
        children: [
          for (final library in libraries)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, library),
              child: ListTile(
                title: Text(library.name),
                subtitle: Text(library.url),
              ),
            ),
        ],
      ),
    );
    if (library == null || !mounted) return;
    setState(() => busyKey = source.key);
    try {
      final response = await AppDio().get<String>(
        library.url,
        options: Options(
          responseType: ResponseType.plain,
          headers: {'cache-time': 'no'},
        ),
      );
      if (response.statusCode != 200 || response.data == null) {
        throw const FormatException('Catalog unavailable');
      }
      final raw = jsonDecode(response.data!);
      if (raw is! List) throw const FormatException('Invalid catalog');
      final matches = <({String name, String version, String fileName})>[];
      for (final entry in raw.whereType<Map>()) {
        if (entry['key'] != source.key) continue;
        final url = resolveSourceDownloadUrl(
          url: entry['url']?.toString(),
          fileName: entry['fileName']?.toString(),
          listUrl: library.url,
        );
        if (url == null) continue;
        final segments = Uri.parse(url).pathSegments;
        if (segments.isEmpty || segments.last.isEmpty) continue;
        matches.add((
          name: entry['name']?.toString() ?? source.name,
          version: entry['version']?.toString() ?? '',
          fileName: segments.last,
        ));
      }
      if (!mounted) return;
      if (matches.isEmpty) {
        context.showMessage(message: 'No matching source in this library'.tl);
        return;
      }
      final fileName = await showDialog<String>(
        context: context,
        builder: (context) => SimpleDialog(
          title: Text('Bind source'.tl),
          children: [
            for (final entry in matches)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, entry.fileName),
                child: ListTile(
                  title: Text(entry.name),
                  subtitle: Text('${entry.version}\n${entry.fileName}'),
                ),
              ),
          ],
        ),
      );
      if (fileName == null || !mounted) return;
      if (ComicSource.find(source.key) != source ||
          ComicSourceLibraryManager.find(library.id)?.url != library.url) {
        throw StateError('Source or catalog changed');
      }
      await ComicSourceLibraryManager.bindUnassignedSource(
        sourceKey: source.key,
        libraryId: library.id,
        sourceFileName: fileName,
      );
      if (mounted) context.showMessage(message: 'Source bound'.tl);
    } catch (_) {
      if (mounted) {
        context.showMessage(message: 'Failed to bind source. Please retry.'.tl);
      }
    } finally {
      if (mounted) setState(() => busyKey = null);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([appdata.settings, ComicSourceManager()]),
    builder: (context, _) {
      final sources = ComicSource.all()
          .where((s) => ComicSourceLibraryManager.isUnbound(s.key))
          .toList();
      return Scaffold(
        appBar: AppBar(title: Text('Manual binding'.tl)),
        body: sources.isEmpty
            ? Center(child: Text('No unbound sources'.tl))
            : ListView.builder(
                itemCount: sources.length,
                itemBuilder: (context, index) {
                  final source = sources[index];
                  return ListTile(
                    title: Text(source.name),
                    subtitle: Text(source.key),
                    onTap: busyKey == null ? () => _bind(source) : null,
                    trailing: busyKey == source.key
                        ? const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.link),
                  );
                },
              ),
      );
    },
  );
}
