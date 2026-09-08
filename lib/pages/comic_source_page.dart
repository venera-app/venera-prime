import 'dart:convert';
import 'dart:io' as io;
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_source/source_library.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/network/app_dio.dart';
import 'package:venera/network/cookie_jar.dart';
import 'package:venera/pages/webview.dart';
import 'package:venera/pages/source_binding_page.dart';
import 'package:venera/utils/ext.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/atomic_file.dart';
import 'package:venera/utils/translations.dart';

typedef _CatalogSource = ({String version, String? url, String? fileName});

class ComicSourcePage extends StatelessWidget {
  const ComicSourcePage({super.key});

  static Future<bool> update(
    ComicSource source, [
    bool showLoading = true,
    String? candidateUrl,
  ]) async {
    final manager = ComicSourceManager();
    if (!manager.tryStartUpdate(source.key)) {
      Log.info("ComicSource", "Update already running: ${source.key}");
      return false;
    }
    final downloadUrl =
        candidateUrl ?? manager.updateUrlFor(source.key) ?? source.url;
    if (!isHttpSourceUrl(downloadUrl)) {
      if (showLoading) {
        App.rootContext.showMessage(message: "Invalid url config");
        manager.finishUpdate(source.key);
        return false;
      } else {
        manager.finishUpdate(source.key);
        throw Exception("Invalid url config");
      }
    }
    bool cancel = false;
    ComicSourceParser? parser;
    LoadingDialogController? controller;
    if (showLoading) {
      controller = showLoadingDialog(
        App.rootContext,
        onCancel: () {
          cancel = true;
          manager.cancelUpdate(source.key);
        },
        barrierDismissible: false,
      );
    }
    try {
      manager.setUpdateState(source.key, ComicSourceUpdateState.downloading);
      Log.info(
        "ComicSource",
        "Update start: ${source.key} v${source.version} ${MyLogInterceptor.safeUrl(source.url)}",
      );
      // jsDelivr aggressively caches @main files. A cache-busting query is
      // required here because the source URL itself intentionally stays
      // stable for future updates.
      final selectedUri = Uri.parse(downloadUrl);
      var sourceUrl = selectedUri
          .replace(
            queryParameters: {
              ...selectedUri.queryParameters,
              "venera_update": DateTime.now().millisecondsSinceEpoch.toString(),
            },
          )
          .toString();
      // jsDelivr may serve a stale @main snapshot even with query params.
      // GitHub Raw reflects the current branch immediately.
      if (sourceUrl.startsWith("https://cdn.jsdelivr.net/gh/")) {
        sourceUrl = sourceUrl
            .replaceFirst(
              "https://cdn.jsdelivr.net/gh/",
              "https://raw.githubusercontent.com/",
            )
            .replaceFirst("@", "/");
      }
      Log.info(
        "ComicSource",
        "Fetching source content: ${MyLogInterceptor.safeUrl(sourceUrl)}",
      );
      var res = await AppDio().get<String>(
        sourceUrl,
        options: Options(
          responseType: ResponseType.plain,
          headers: {"cache-time": "no"},
        ),
      );
      Log.info(
        "ComicSource",
        "Downloaded ${source.key}: status=${res.statusCode}, bytes=${res.data?.length ?? 0}",
      );
      if (res.statusCode == null ||
          res.statusCode! < 200 ||
          res.statusCode! >= 300 ||
          res.data == null ||
          res.data!.trim().isEmpty) {
        throw Exception('Source download failed with status ${res.statusCode}');
      }
      if (cancel || manager.isUpdateCancelled(source.key)) {
        manager.setUpdateState(source.key, ComicSourceUpdateState.canceled);
        return false;
      }
      final target = io.File(source.filePath);
      final temp = io.File('${target.path}.update.tmp');
      final backup = io.File('${target.path}.update.bak');
      Log.info("ComicSource", "Parsing ${source.key}");
      manager.setUpdateState(source.key, ComicSourceUpdateState.parsing);
      final currentParser = ComicSourceParser();
      parser = currentParser;
      final candidate = await currentParser.parse(
        res.data!,
        source.filePath,
        allowExistingKey: true,
        registerSource: false,
      );
      if (cancel || manager.isUpdateCancelled(source.key)) {
        manager.setUpdateState(source.key, ComicSourceUpdateState.canceled);
        return false;
      }
      if (candidate.key != source.key) {
        throw ComicSourceParseException(
          'Source key changed from ${source.key} to ${candidate.key}',
        );
      }
      Log.info("ComicSource", "Writing ${source.key}: ${source.filePath}");
      manager.setUpdateState(source.key, ComicSourceUpdateState.writing);
      await temp.writeAsString(res.data!, flush: true);
      if (cancel || manager.isUpdateCancelled(source.key)) {
        manager.setUpdateState(source.key, ComicSourceUpdateState.canceled);
        return false;
      }
      await atomicReplaceWithBackup(
        target: target,
        temporary: temp,
        backup: backup,
      );
      currentParser.registerParsedSource();
      manager.replace(candidate);
      manager.setUpdateUrl(source.key, downloadUrl);
      manager.removeAvailableUpdate(source.key);
      manager.setUpdateState(source.key, ComicSourceUpdateState.success);
      Log.info("ComicSource", "Update success: ${source.key}");
      return true;
    } catch (e) {
      Log.error("ComicSource", "Update failed: ${source.key}\n$e");
      if (cancel || manager.isUpdateCancelled(source.key)) {
        manager.setUpdateState(source.key, ComicSourceUpdateState.canceled);
        return false;
      }
      manager.setUpdateState(source.key, ComicSourceUpdateState.failed);
      if (showLoading) {
        App.rootContext.showMessage(message: e.toString());
      } else {
        rethrow;
      }
    } finally {
      controller?.close();
      parser?.discardParsedSource();
      await io.File('${source.filePath}.update.tmp').deleteIgnoreError();
      manager.finishUpdate(source.key);
    }
    if (showLoading) {
      App.forceRebuild();
    }
    return false;
  }

  static Future<int> checkComicSourceUpdate() async {
    ComicSourceManager().clearUpdateCandidates();
    if (ComicSource.all().isEmpty) {
      return 0;
    }
    ComicSourceLibraryManager.migrateLegacy();
    final libraries = ComicSourceLibraryManager.enabled();
    if (libraries.isEmpty) return 0;

    final catalogs = <String, Map<String, List<_CatalogSource>>>{};
    final offeredBy = <String, List<String>>{};
    final succeeded = <String>{};
    for (final library in libraries) {
      try {
        Log.info(
          "ComicSource",
          "Checking source library ${library.name}: "
              "${MyLogInterceptor.safeUrl(library.url)}",
        );
        final response = await AppDio().get<String>(
          library.url,
          options: Options(headers: {"cache-time": "no"}),
        );
        if (response.statusCode != 200 || response.data == null) continue;
        final raw = jsonDecode(response.data!);
        if (raw is! List) continue;
        final catalog = <String, List<_CatalogSource>>{};
        for (final entry in raw.whereType<Map>()) {
          final key = entry['key']?.toString();
          final version = entry['version']?.toString();
          if (key == null || version == null) continue;
          final downloadUrl = resolveSourceDownloadUrl(
            url: entry['url']?.toString(),
            fileName: entry['fileName']?.toString(),
            listUrl: library.url,
          );
          final resolvedFileName = downloadUrl == null
              ? entry['fileName']?.toString()
              : Uri.tryParse(downloadUrl)?.pathSegments.lastOrNull;
          (catalog[key] ??= <_CatalogSource>[]).add((
            version: version,
            url: downloadUrl,
            fileName: resolvedFileName,
          ));
          final providers = offeredBy[key] ??= <String>[];
          if (!providers.contains(library.id)) providers.add(library.id);
        }
        catalogs[library.id] = catalog;
        succeeded.add(library.id);
        ComicSourceLibraryManager.markChecked(library.id);
      } catch (e, s) {
        Log.error("ComicSource", "${library.name}: $e", s);
      }
    }
    if (succeeded.isEmpty) return -1;

    final manager = ComicSourceManager();
    final updates = <String, String>{};
    final provenanceUpdates = <String, SourceProvenance>{};
    for (final source in ComicSource.all()) {
      final provenance =
          manager.provenanceFor(source.key) ?? SourceProvenance();
      final origin = provenance.originId == null
          ? null
          : ComicSourceLibraryManager.find(provenance.originId!);
      String? updateLibraryId;
      if (origin != null &&
          succeeded.contains(origin.id) &&
          catalogs[origin.id]?.containsKey(source.key) == true) {
        updateLibraryId = origin.id;
      } else if (origin != null) {
        // Keep the source bound to its maintainer during a transient outage.
        updateLibraryId = null;
      } else {
        updateLibraryId = offeredBy[source.key]?.firstOrNull;
      }

      final offered = offeredBy[source.key];
      if (offered != null || succeeded.isNotEmpty) {
        final ids = <String>[];
        for (final id in provenance.libraryIds) {
          final library = ComicSourceLibraryManager.find(id);
          if (library != null && library.enabled && !ids.contains(id)) {
            ids.add(id);
          }
        }
        for (final id in offered ?? const <String>[]) {
          if (!ids.contains(id)) ids.add(id);
        }
        provenance.libraryIds = ids;
        provenance.updateLibraryId = updateLibraryId;
        provenanceUpdates[source.key] = provenance;
      }

      final candidates = updateLibraryId == null
          ? null
          : catalogs[updateLibraryId]?[source.key];
      final localFileName = io.File(source.filePath).uri.pathSegments.last;
      final preferredFileName = provenance.sourceFileName ?? localFileName;
      _CatalogSource? selected;
      if (candidates != null) {
        selected = candidates.firstWhereOrNull(
          (entry) => entry.fileName == preferredFileName,
        );
        if (selected == null &&
            provenance.sourceFileName == null &&
            candidates.isNotEmpty) {
          selected = candidates.first;
          for (final candidate in candidates.skip(1)) {
            try {
              if (compareSemVer(candidate.version, selected!.version)) {
                selected = candidate;
              }
            } catch (_) {
              // Keep the first valid catalog entry when versions are invalid.
            }
          }
        }
      }
      if (selected != null) {
        if (selected.fileName == preferredFileName &&
            provenance.sourceFileName == null) {
          provenance.sourceFileName = preferredFileName;
          provenanceUpdates[source.key] = provenance;
        }
        if (selected.url != null) {
          manager.setUpdateUrl(source.key, selected.url!);
        }
        try {
          if (compareSemVer(selected.version, source.version)) {
            updates[source.key] = selected.version;
          }
        } catch (e) {
          Log.warning("ComicSource", "Invalid version for ${source.key}: $e");
        }
      }
    }
    ComicSourceLibraryManager.setProvenanceBatch(provenanceUpdates);
    manager.setAvailableUpdates(updates);
    Log.info("ComicSource", "Source check complete: ${updates.length} updates");
    return updates.length;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(body: const _Body());
  }
}

class _Body extends StatefulWidget {
  const _Body();

  @override
  State<_Body> createState() => _BodyState();
}

class _BodyState extends State<_Body> {
  var url = "";

  void updateUI() {
    setState(() {});
  }

  @override
  void initState() {
    super.initState();
    ComicSourceManager().addListener(updateUI);
  }

  @override
  void dispose() {
    super.dispose();
    ComicSourceManager().removeListener(updateUI);
  }

  @override
  Widget build(BuildContext context) {
    return SmoothCustomScrollView(
      slivers: [
        SliverAppbar(
          title: Text('Comic Source'.tl),
          style: AppbarStyle.shadow,
          actions: [
            Tooltip(
              message: 'Reorder'.tl,
              child: IconButton(
                icon: const Icon(Icons.reorder),
                onPressed: () => _showReorderDialog(context),
              ),
            ),
            Tooltip(
              message: 'Sort by name'.tl,
              child: IconButton(
                icon: const Icon(Icons.sort_by_alpha),
                onPressed: () => ComicSourceManager().sortByName(),
              ),
            ),
          ],
        ),
        buildCard(context),
        for (var source in ComicSource.all())
          _SliverComicSource(
            key: ValueKey(source.key),
            source: source,
            edit: edit,
            update: update,
            delete: delete,
          ),
        SliverPadding(padding: EdgeInsets.only(bottom: context.padding.bottom)),
      ],
    );
  }

  void _showReorderDialog(BuildContext context) {
    var keys = ComicSourceManager().all().map((source) => source.key).toList();
    showDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text('Reorder comic sources'.tl),
          content: SizedBox(
            width: 420,
            height: 420,
            child: ReorderableListView.builder(
              itemCount: keys.length,
              onReorder: (oldIndex, newIndex) {
                if (newIndex > oldIndex) newIndex--;
                setState(() {
                  final key = keys.removeAt(oldIndex);
                  keys.insert(newIndex, key);
                });
              },
              itemBuilder: (context, index) {
                final source = ComicSource.find(keys[index]);
                return ListTile(
                  key: ValueKey(keys[index]),
                  leading: const Icon(Icons.drag_handle),
                  title: Text(source?.name ?? keys[index]),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text('Cancel'.tl),
            ),
            FilledButton(
              onPressed: () async {
                await ComicSourceManager().setOrder(keys);
                if (dialogContext.mounted) Navigator.pop(dialogContext);
              },
              child: Text('Confirm'.tl),
            ),
          ],
        ),
      ),
    );
  }

  void delete(ComicSource source) {
    showConfirmDialog(
      context: App.rootContext,
      title: "Delete".tl,
      content: "Delete comic source '@n' ?".tlParams({"n": source.name}),
      btnColor: context.colorScheme.error,
      onConfirm: () {
        var file = File(source.filePath);
        file.delete();
        ComicSourceManager().remove(source.key);
        _validatePages();
        App.forceRebuild();
      },
    );
  }

  void edit(ComicSource source) async {
    if (App.isDesktop) {
      try {
        await Process.run("code", [source.filePath], runInShell: true);
        await showDialog(
          context: App.rootContext,
          builder: (context) => AlertDialog(
            title: const Text("Reload Configs"),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text("cancel"),
              ),
              TextButton(
                onPressed: () async {
                  await ComicSourceManager().reload();
                  App.forceRebuild();
                },
                child: const Text("continue"),
              ),
            ],
          ),
        );
        return;
      } catch (e) {
        //
      }
    }
    context.to(
      () => _EditFilePage(source.filePath, () async {
        await ComicSourceManager().reload();
        setState(() {});
      }),
    );
  }

  void update(ComicSource source, [bool showLoading = true]) {
    ComicSourcePage.update(source, showLoading);
  }

  Widget buildCard(BuildContext context) {
    return SliverToBoxAdapter(
      child: SizedBox(
        width: double.infinity,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text("Add comic source".tl),
              leading: const Icon(Icons.dashboard_customize),
            ),
            TextField(
              decoration: InputDecoration(
                hintText: "URL",
                border: const UnderlineInputBorder(),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                suffix: IconButton(
                  onPressed: () => handleAddSource(url),
                  icon: const Icon(Icons.check),
                ),
              ),
              onChanged: (value) {
                url = value;
              },
              onSubmitted: handleAddSource,
            ).paddingHorizontal(16).paddingBottom(8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonalIcon(
                  icon: const Icon(Icons.library_books_outlined),
                  label: Text("Source libraries".tl),
                  onPressed: () =>
                      context.to(() => const SourceLibrariesPage()),
                ),
                FilledButton.tonalIcon(
                  icon: Icon(Icons.file_open_outlined),
                  label: Text("Use a config file".tl),
                  onPressed: _selectFile,
                ),
                FilledButton.tonalIcon(
                  icon: Icon(Icons.help_outline),
                  label: Text("Help".tl),
                  onPressed: help,
                ),
                _CheckUpdatesButton(),
                ListenableBuilder(
                  listenable: Listenable.merge([
                    appdata.settings,
                    ComicSourceManager(),
                  ]),
                  builder: (context, _) =>
                      ComicSource.all().any(
                        (source) =>
                            ComicSourceLibraryManager.isUnbound(source.key),
                      )
                      ? FilledButton.tonalIcon(
                          icon: const Icon(Icons.link),
                          label: Text('Manual binding'.tl),
                          onPressed: () =>
                              context.to(() => const SourceBindingPage()),
                        )
                      : const SizedBox.shrink(),
                ),
              ],
            ).paddingHorizontal(12).paddingVertical(8),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _selectFile() async {
    final file = await selectFile(ext: ["js"]);
    if (file == null) return;
    try {
      var fileName = file.name;
      var bytes = await file.readAsBytes();
      var content = utf8.decode(bytes);
      await addSource(content, fileName);
    } catch (e, s) {
      App.rootContext.showMessage(message: e.toString());
      Log.error("Add comic source", "$e\n$s");
    }
  }

  void help() {
    launchUrlString(
      "https://github.com/venera-app/venera/blob/master/doc/comic_source.md",
    );
  }

  Future<void> handleAddSource(String url, {String? originLibraryId}) async {
    if (url.isEmpty) {
      return;
    }
    var splits = url.split("/");
    splits.removeWhere((element) => element == "");
    var fileName = splits.last;
    bool cancel = false;
    var controller = showLoadingDialog(
      App.rootContext,
      onCancel: () => cancel = true,
      barrierDismissible: false,
    );
    try {
      var res = await AppDio().get<String>(
        url,
        options: Options(
          responseType: ResponseType.plain,
          headers: {"cache-time": "no"},
        ),
      );
      if (cancel) return;
      controller.close();
      await addSource(res.data!, fileName, originLibraryId: originLibraryId);
    } catch (e, s) {
      if (cancel) return;
      context.showMessage(message: e.toString());
      Log.error("Add comic source", "$e\n$s");
    }
  }

  Future<void> addSource(
    String js,
    String fileName, {
    String? originLibraryId,
  }) async {
    var comicSource = await ComicSourceParser().createAndParse(js, fileName);
    ComicSourceManager().add(
      comicSource,
      originLibraryId: originLibraryId,
      sourceFileName: fileName,
    );
    _addAllPagesWithComicSource(comicSource);
    appdata.saveData();
    App.forceRebuild();
  }
}

Future<void> _installSourceFromLibrary(String url, String libraryId) async {
  final controller = showLoadingDialog(
    App.rootContext,
    barrierDismissible: false,
  );
  try {
    final response = await AppDio().get<String>(
      url,
      options: Options(
        responseType: ResponseType.plain,
        headers: {"cache-time": "no"},
      ),
    );
    if (response.statusCode == null ||
        response.statusCode! < 200 ||
        response.statusCode! >= 300 ||
        response.data == null) {
      throw Exception(
        'Source download failed with status ${response.statusCode}',
      );
    }
    final fileName = Uri.parse(url).pathSegments.last;
    final source = await ComicSourceParser().createAndParse(
      response.data!,
      fileName,
    );
    ComicSourceManager().add(
      source,
      originLibraryId: libraryId,
      sourceFileName: fileName,
    );
    _addAllPagesWithComicSource(source);
    await appdata.saveData();
    App.forceRebuild();
  } catch (e, s) {
    Log.error("Install comic source", "$e\n$s");
    App.rootContext.showMessage(message: e.toString());
  } finally {
    controller.close();
  }
}

Future<void> _switchSourceLibrary({
  required ComicSource source,
  required ComicSourceLibrary library,
  required String url,
}) async {
  final confirmed = await showDialog<bool>(
    context: App.rootContext,
    builder: (context) => AlertDialog(
      title: Text("Switch source library".tl),
      content: Text(
        "Switch '@source' to the version provided by '@library'?".tlParams({
          "source": source.name,
          "library": library.name,
        }),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text("Cancel".tl),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text("Confirm".tl),
        ),
      ],
    ),
  );
  if (confirmed != true) return;

  final manager = ComicSourceManager();
  if (!await ComicSourcePage.update(source, true, url)) return;

  final provenance = manager.provenanceFor(source.key) ?? SourceProvenance();
  if (!provenance.libraryIds.contains(library.id)) {
    provenance.libraryIds.add(library.id);
  }
  provenance.originId = library.id;
  provenance.updateLibraryId = library.id;
  provenance.sourceFileName = Uri.parse(url).pathSegments.last;
  manager.updateProvenance(source.key, provenance);
  App.rootContext.showMessage(message: "Source library switched".tl);
}

class SourceLibrariesPage extends StatefulWidget {
  const SourceLibrariesPage({super.key});

  @override
  State<SourceLibrariesPage> createState() => _SourceLibrariesPageState();
}

class _SourceLibrariesPageState extends State<SourceLibrariesPage> {
  List<ComicSourceLibrary> get libraries => ComicSourceLibraryManager.all();

  void _addLibrary() {
    _editLibrary();
  }

  void _editLibrary([ComicSourceLibrary? library]) {
    var name = library?.name ?? '';
    var url = library?.url ?? '';
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(library == null ? "Add library".tl : "Edit library".tl),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              decoration: InputDecoration(labelText: "Library name".tl),
              initialValue: name,
              onChanged: (value) => name = value,
            ),
            TextFormField(
              decoration: const InputDecoration(
                labelText: "URL",
                hintText: "index.json",
              ),
              initialValue: url,
              onChanged: (value) => url = value,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text("Cancel".tl),
          ),
          FilledButton(
            onPressed: () {
              final existing = findLibraryByUrl(libraries, url);
              if (!isHttpSourceUrl(url) ||
                  (library != null &&
                      existing != null &&
                      existing.id != library.id)) {
                context.showMessage(message: "Invalid URL".tl);
                return;
              }
              if (library == null) {
                ComicSourceLibraryManager.add(name, url);
              } else {
                ComicSourceLibraryManager.edit(
                  library.id,
                  name: name,
                  url: url,
                );
              }
              Navigator.pop(dialogContext);
              setState(() {});
            },
            child: Text("Confirm".tl),
          ),
        ],
      ),
    );
  }

  void _removeLibrary(ComicSourceLibrary library) {
    showConfirmDialog(
      context: context,
      title: "Delete library".tl,
      content: "Delete library '@n'? Installed sources are kept.".tlParams({
        "n": library.name,
      }),
      onConfirm: () {
        ComicSourceLibraryManager.remove(library.id);
        setState(() {});
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final items = libraries;
    return Scaffold(
      appBar: AppBar(
        title: Text("Source libraries".tl),
        actions: [
          IconButton(
            tooltip: "Add library".tl,
            icon: const Icon(Icons.add),
            onPressed: _addLibrary,
          ),
        ],
      ),
      body: items.isEmpty
          ? Center(child: Text("No source libraries".tl))
          : ReorderableListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: items.length,
              onReorder: (oldIndex, newIndex) {
                if (newIndex > oldIndex) newIndex--;
                ComicSourceLibraryManager.reorder(oldIndex, newIndex);
                setState(() {});
              },
              itemBuilder: (context, index) {
                final library = items[index];
                return ListTile(
                  key: ValueKey(library.id),
                  leading: ReorderableDragStartListener(
                    index: index,
                    child: const Icon(Icons.drag_handle),
                  ),
                  title: Text(library.name),
                  subtitle: Text(library.url),
                  onTap: () =>
                      context.to(() => _LibraryCatalogPage(library: library)),
                  trailing: PopupMenuButton<String>(
                    onSelected: (value) {
                      if (value == 'toggle') {
                        ComicSourceLibraryManager.setEnabled(
                          library.id,
                          !library.enabled,
                        );
                        setState(() {});
                      } else if (value == 'edit') {
                        _editLibrary(library);
                      } else if (value == 'delete') {
                        _removeLibrary(library);
                      }
                    },
                    itemBuilder: (context) => [
                      PopupMenuItem(
                        value: 'toggle',
                        child: Text(
                          library.enabled ? "Disable".tl : "Enable".tl,
                        ),
                      ),
                      PopupMenuItem(value: 'edit', child: Text("Edit".tl)),
                      PopupMenuItem(value: 'delete', child: Text("Delete".tl)),
                    ],
                  ),
                );
              },
            ),
    );
  }
}

class _LibraryCatalogPage extends StatefulWidget {
  const _LibraryCatalogPage({required this.library});

  final ComicSourceLibrary library;

  @override
  State<_LibraryCatalogPage> createState() => _LibraryCatalogPageState();
}

class _LibraryCatalogPageState extends State<_LibraryCatalogPage> {
  List<Map<String, dynamic>>? entries;
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final response = await AppDio().get<String>(
        widget.library.url,
        options: Options(headers: {"cache-time": "no"}),
      );
      if (response.statusCode != 200 || response.data == null) {
        throw Exception('Network error');
      }
      final raw = jsonDecode(response.data!);
      if (raw is! List) throw Exception('Invalid source catalog');
      if (mounted) {
        setState(() {
          entries = raw
              .whereType<Map>()
              .map(Map<String, dynamic>.from)
              .toList();
          loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          entries = [];
          loading = false;
        });
        context.showMessage(message: e.toString());
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return Scaffold(body: const Center(child: CircularProgressIndicator()));
    }
    final installed = ComicSource.all().map((source) => source.key).toSet();
    return Scaffold(
      appBar: AppBar(title: Text(widget.library.name)),
      body: ListView.builder(
        itemCount: entries!.length,
        itemBuilder: (context, index) {
          final entry = entries![index];
          final key = entry['key']?.toString() ?? '';
          final source = ComicSource.find(key);
          final provenance = source == null
              ? null
              : ComicSourceManager().provenanceFor(key);
          final url = resolveSourceDownloadUrl(
            url: entry['url']?.toString(),
            fileName: entry['fileName']?.toString(),
            listUrl: widget.library.url,
          );
          final entryFileName = url == null
              ? null
              : Uri.tryParse(url)?.pathSegments.lastOrNull;
          final currentFileName = source == null
              ? null
              : provenance?.sourceFileName ??
                    io.File(source.filePath).uri.pathSegments.last;
          final isCurrentVariant =
              provenance?.originId == widget.library.id &&
              entryFileName == currentFileName;
          return ListTile(
            title: Text(entry['name']?.toString() ?? key),
            subtitle: Text(entry['version']?.toString() ?? ''),
            trailing: installed.contains(key)
                ? isCurrentVariant
                      ? const Icon(Icons.check)
                      : IconButton(
                          tooltip: "Switch source library".tl,
                          icon: const Icon(Icons.swap_horiz),
                          onPressed: source == null || url == null
                              ? null
                              : () async {
                                  await _switchSourceLibrary(
                                    source: source,
                                    library: widget.library,
                                    url: url,
                                  );
                                  if (mounted) setState(() {});
                                },
                        )
                : IconButton(
                    tooltip: "Add".tl,
                    icon: const Icon(Icons.add),
                    onPressed: url == null
                        ? null
                        : () async {
                            await _installSourceFromLibrary(
                              url,
                              widget.library.id,
                            );
                            if (mounted) setState(() {});
                          },
                  ),
          );
        },
      ),
    );
  }
}

void _validatePages() {
  List explorePages = appdata.settings['explore_pages'];
  List categoryPages = appdata.settings['categories'];
  List networkFavorites = appdata.settings['favorites'];

  var totalExplorePages = ComicSource.all()
      .map((e) => e.explorePages.map((e) => e.title))
      .expand((element) => element)
      .toList();
  var totalCategoryPages = ComicSource.all()
      .map((e) => e.categoryData?.key)
      .where((element) => element != null)
      .map((e) => e!)
      .toList();
  var totalNetworkFavorites = ComicSource.all()
      .map((e) => e.favoriteData?.key)
      .where((element) => element != null)
      .map((e) => e!)
      .toList();

  for (var page in List.from(explorePages)) {
    if (!totalExplorePages.contains(page)) {
      explorePages.remove(page);
    }
  }
  for (var page in List.from(categoryPages)) {
    if (!totalCategoryPages.contains(page)) {
      categoryPages.remove(page);
    }
  }
  for (var page in List.from(networkFavorites)) {
    if (!totalNetworkFavorites.contains(page)) {
      networkFavorites.remove(page);
    }
  }

  appdata.settings['explore_pages'] = explorePages.toSet().toList();
  appdata.settings['categories'] = categoryPages.toSet().toList();
  appdata.settings['favorites'] = networkFavorites.toSet().toList();

  appdata.saveData();
}

void _addAllPagesWithComicSource(ComicSource source) {
  var explorePages = appdata.settings['explore_pages'];
  var categoryPages = appdata.settings['categories'];
  var networkFavorites = appdata.settings['favorites'];
  var searchPages = appdata.settings['searchSources'];

  if (source.explorePages.isNotEmpty) {
    for (var page in source.explorePages) {
      if (!explorePages.contains(page.title)) {
        explorePages.add(page.title);
      }
    }
  }
  if (source.categoryData != null &&
      !categoryPages.contains(source.categoryData!.key)) {
    categoryPages.add(source.categoryData!.key);
  }
  if (source.favoriteData != null &&
      !networkFavorites.contains(source.favoriteData!.key)) {
    networkFavorites.add(source.favoriteData!.key);
  }
  if (source.searchPageData != null && !searchPages.contains(source.key)) {
    searchPages.add(source.key);
  }

  appdata.settings['explore_pages'] = explorePages.toSet().toList();
  appdata.settings['categories'] = categoryPages.toSet().toList();
  appdata.settings['favorites'] = networkFavorites.toSet().toList();
  appdata.settings['searchSources'] = searchPages.toSet().toList();

  appdata.saveData();
}

class _EditFilePage extends StatefulWidget {
  const _EditFilePage(this.path, this.onExit);

  final String path;

  final void Function() onExit;

  @override
  State<_EditFilePage> createState() => __EditFilePageState();
}

class __EditFilePageState extends State<_EditFilePage> {
  var current = '';

  @override
  void initState() {
    super.initState();
    current = File(widget.path).readAsStringSync();
  }

  @override
  void dispose() {
    File(widget.path).writeAsStringSync(current);
    widget.onExit();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: Appbar(title: Text("Edit".tl)),
      body: Column(
        children: [
          Container(height: 0.6, color: context.colorScheme.outlineVariant),
          Expanded(
            child: CodeEditor(
              initialValue: current,
              onChanged: (value) => current = value,
            ),
          ),
        ],
      ),
    );
  }
}

class _CheckUpdatesButton extends StatefulWidget {
  const _CheckUpdatesButton();

  @override
  State<_CheckUpdatesButton> createState() => _CheckUpdatesButtonState();
}

class _CheckUpdatesButtonState extends State<_CheckUpdatesButton> {
  bool isLoading = false;

  void check() async {
    setState(() {
      isLoading = true;
    });
    try {
      var count = await ComicSourcePage.checkComicSourceUpdate();
      if (count == -1) {
        context.showMessage(message: "Network error".tl);
      } else if (count == 0) {
        context.showMessage(message: "No updates".tl);
      } else {
        showUpdateDialog();
      }
    } catch (e) {
      Log.error("ComicSource", "Source check failed\n$e");
      context.showMessage(message: e.toString());
    } finally {
      if (mounted) {
        setState(() {
          isLoading = false;
        });
      }
    }
  }

  void showUpdateDialog() async {
    var text = ComicSourceManager().availableUpdates.entries
        .map((e) {
          return "${ComicSource.find(e.key)!.name}: ${e.value}";
        })
        .join("\n");
    bool doUpdate = false;
    await showDialog(
      context: App.rootContext,
      builder: (context) {
        return ContentDialog(
          title: "Updates".tl,
          content: Text(text).paddingHorizontal(16),
          actions: [
            FilledButton(
              onPressed: () {
                doUpdate = true;
                context.pop();
              },
              child: Text("Update".tl),
            ),
          ],
        );
      },
    );
    if (doUpdate) {
      bool canceled = false;
      String? activeKey;
      var loadingController = showLoadingDialog(
        context,
        message: "Updating".tl,
        withProgress: true,
        onCancel: () {
          canceled = true;
          final key = activeKey;
          if (key != null) {
            ComicSourceManager().cancelUpdate(key);
          }
        },
      );
      int current = 0;
      int total = ComicSourceManager().availableUpdates.length;
      var failures = <String>[];
      int successCount = 0;
      try {
        var shouldUpdate = ComicSourceManager().availableUpdates.keys.toList();
        for (var key in shouldUpdate) {
          if (canceled) break;
          activeKey = key;
          var source = ComicSource.find(key);
          if (source == null) {
            failures.add('$key: source is no longer available');
            ComicSourceManager().clearUpdateState(key);
          } else {
            try {
              if (await ComicSourcePage.update(source, false)) {
                successCount++;
              }
            } catch (e) {
              failures.add('$key: $e');
            }
          }
          activeKey = null;
          current++;
          loadingController.setProgress(current / total);
        }
      } finally {
        loadingController.close();
        final history = appdata.implicitData['comicSourceUpdateHistory'] is List
            ? List<dynamic>.from(
                appdata.implicitData['comicSourceUpdateHistory'],
              )
            : <dynamic>[];
        history.insert(0, {
          'time': DateTime.now().millisecondsSinceEpoch,
          'total': total,
          'success': successCount,
          'failed': failures.length,
          'canceled': canceled,
          'errors': failures,
        });
        if (history.length > 20) history.removeRange(20, history.length);
        appdata.implicitData['comicSourceUpdateHistory'] = history;
        appdata.writeImplicitData();
        App.forceRebuild();
      }
      if (failures.isNotEmpty) {
        context.showMessage(message: failures.join('\n'));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return FilledButton.tonalIcon(
      icon: isLoading
          ? SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(Icons.update),
      label: Text("Check updates".tl),
      onPressed: check,
    );
  }
}

class _CallbackSetting extends StatefulWidget {
  const _CallbackSetting({required this.setting, required this.sourceKey});

  final MapEntry<String, Map<String, dynamic>> setting;

  final String sourceKey;

  @override
  State<_CallbackSetting> createState() => _CallbackSettingState();
}

class _CallbackSettingState extends State<_CallbackSetting> {
  String get key => widget.setting.key;

  String get buttonText => widget.setting.value['buttonText'] ?? "Click";

  String get title => widget.setting.value['title'] ?? key;

  bool isLoading = false;

  Future<void> onClick() async {
    var func = widget.setting.value['callback'];
    var result = func([]);
    if (result is Future) {
      setState(() {
        isLoading = true;
      });
      try {
        await result;
      } finally {
        setState(() {
          isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(title.ts(widget.sourceKey)),
      trailing: Button.normal(
        onPressed: onClick,
        isLoading: isLoading,
        child: Text(buttonText.ts(widget.sourceKey)),
      ).fixHeight(32),
    );
  }
}

class _SliverComicSource extends StatefulWidget {
  const _SliverComicSource({
    super.key,
    required this.source,
    required this.edit,
    required this.update,
    required this.delete,
  });

  final ComicSource source;

  final void Function(ComicSource source) edit;
  final void Function(ComicSource source) update;
  final void Function(ComicSource source) delete;

  @override
  State<_SliverComicSource> createState() => _SliverComicSourceState();
}

class _SliverComicSourceState extends State<_SliverComicSource> {
  ComicSource get source => widget.source;

  String? _provenanceText() {
    final provenance = ComicSourceManager().provenanceFor(source.key);
    if (provenance == null) return null;
    if (provenance.originId != null) {
      final origin = ComicSourceLibraryManager.find(provenance.originId!);
      if (origin == null) return "Source library removed".tl;
      final others = provenance.libraryIds
          .where((id) => id != provenance.originId)
          .length;
      return others == 0
          ? "From @lib".tlParams({"lib": origin.name})
          : "From @lib and @n more".tlParams({"lib": origin.name, "n": others});
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    var newVersion = ComicSourceManager().availableUpdates[source.key];
    bool hasUpdate =
        newVersion != null && compareSemVer(newVersion, source.version);
    final updateState = ComicSourceManager().updateStates[source.key];
    final stateLabel = switch (updateState) {
      ComicSourceUpdateState.downloading => 'Downloading'.tl,
      ComicSourceUpdateState.parsing => 'Parsing'.tl,
      ComicSourceUpdateState.writing => 'Writing'.tl,
      ComicSourceUpdateState.success => 'Updated'.tl,
      ComicSourceUpdateState.failed => 'Update failed'.tl,
      ComicSourceUpdateState.canceled => 'Canceled'.tl,
      ComicSourceUpdateState.waiting => 'Waiting'.tl,
      null => null,
    };

    return SliverMainAxisGroup(
      slivers: [
        SliverPadding(padding: const EdgeInsets.only(top: 16)),
        SliverToBoxAdapter(
          child: ListTile(
            title: LayoutBuilder(
              builder: (context, constraints) {
                return Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: constraints.maxWidth,
                      ),
                      child: Text(
                        source.name,
                        style: ts.s18,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: context.colorScheme.surfaceContainer,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        source.version,
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                    if (hasUpdate)
                      Tooltip(
                        message: newVersion,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: context.colorScheme.primaryContainer,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            "New Version".tl,
                            style: const TextStyle(fontSize: 13),
                          ),
                        ),
                      ),
                    if (stateLabel != null)
                      Text(
                        stateLabel,
                        style: TextStyle(
                          fontSize: 12,
                          color: updateState == ComicSourceUpdateState.failed
                              ? context.colorScheme.error
                              : context.colorScheme.primary,
                        ),
                      ),
                  ],
                );
              },
            ),
            subtitle: _provenanceText() == null
                ? null
                : Text(
                    _provenanceText()!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Tooltip(
                  message: "Edit".tl,
                  child: IconButton(
                    onPressed: () => widget.edit(source),
                    icon: const Icon(Icons.edit_note),
                  ),
                ),
                Tooltip(
                  message: "Update".tl,
                  child: IconButton(
                    onPressed: () => widget.update(source),
                    icon: const Icon(Icons.update),
                  ),
                ),
                Tooltip(
                  message: "Delete".tl,
                  child: IconButton(
                    onPressed: () => widget.delete(source),
                    icon: const Icon(Icons.delete),
                  ),
                ),
              ],
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: context.colorScheme.outlineVariant,
                  width: 0.6,
                ),
              ),
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Column(children: buildSourceSettings().toList()),
        ),
        SliverToBoxAdapter(child: Column(children: _buildAccount().toList())),
      ],
    );
  }

  Iterable<Widget> buildSourceSettings() sync* {
    // Try to get dynamic settings first (for getters), fall back to cached settings
    var settingsMap = source.getSettingsDynamic() ?? source.settings;

    if (settingsMap == null) {
      return;
    } else if (source.data['settings'] == null) {
      source.data['settings'] = {};
    }
    for (var item in settingsMap.entries) {
      var key = item.key;
      String type = item.value['type'];
      try {
        if (type == "select") {
          var current = source.data['settings'][key];
          if (current == null) {
            var d = item.value['default'];
            for (var option in item.value['options']) {
              if (option['value'] == d) {
                current = option['text'] ?? option['value'];
                break;
              }
            }
          } else {
            current =
                item.value['options'].firstWhere(
                  (e) => e['value'] == current,
                  orElse: () => <String, dynamic>{},
                )['text'] ??
                current;
          }
          yield ListTile(
            title: Text((item.value['title'] as String).ts(source.key)),
            trailing: Select(
              current: current?.toString().ts(source.key),
              values: (item.value['options'] as List)
                  .map<String>(
                    (e) => ((e['text'] ?? e['value']) as String).ts(source.key),
                  )
                  .toList(),
              onTap: (i) {
                source.data['settings'][key] =
                    item.value['options'][i]['value'];
                source.saveData();
                setState(() {});
              },
            ),
          );
        } else if (type == "switch") {
          var current = source.data['settings'][key] ?? item.value['default'];
          yield ListTile(
            title: Text((item.value['title'] as String).ts(source.key)),
            trailing: Switch(
              value: current,
              onChanged: (v) {
                source.data['settings'][key] = v;
                source.saveData();
                setState(() {});
              },
            ),
          );
        } else if (type == "input") {
          var current =
              source.data['settings'][key] ?? item.value['default'] ?? '';
          yield ListTile(
            title: Text((item.value['title'] as String).ts(source.key)),
            subtitle: Text(
              current,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: IconButton(
              icon: const Icon(Icons.edit),
              onPressed: () {
                showInputDialog(
                  context: context,
                  title: (item.value['title'] as String).ts(source.key),
                  initialValue: current,
                  inputValidator: item.value['validator'] == null
                      ? null
                      : RegExp(item.value['validator']),
                  onConfirm: (value) {
                    source.data['settings'][key] = value;
                    source.saveData();
                    setState(() {});
                    return null;
                  },
                );
              },
            ),
          );
        } else if (type == "callback") {
          yield _CallbackSetting(setting: item, sourceKey: source.key);
        }
      } catch (e, s) {
        Log.error("ComicSourcePage", "Failed to build a setting\n$e\n$s");
      }
    }
  }

  final _reLogin = <String, bool>{};

  Iterable<Widget> _buildAccount() sync* {
    if (source.account == null) return;
    final bool logged = source.isLogged;
    if (!logged) {
      yield ListTile(
        title: Text("Log in".tl),
        trailing: const Icon(Icons.arrow_right),
        onTap: () async {
          await context.to(
            () => _LoginPage(config: source.account!, source: source),
          );
          source.saveData();
          setState(() {});
        },
      );
    }
    if (logged) {
      for (var item in source.account!.infoItems) {
        if (item.builder != null) {
          yield item.builder!(context);
        } else {
          yield ListTile(
            title: Text(item.title.tl),
            subtitle: item.data == null ? null : Text(item.data!()),
            onTap: item.onTap,
          );
        }
      }
      if (source.data["account"] is List) {
        bool loading = _reLogin[source.key] == true;
        yield ListTile(
          title: Text("Re-login".tl),
          subtitle: Text("Click if login expired".tl),
          onTap: () async {
            if (source.data["account"] == null) {
              context.showMessage(message: "No data".tl);
              return;
            }
            setState(() {
              _reLogin[source.key] = true;
            });
            final List account = source.data["account"];
            var res = await source.account!.login!(account[0], account[1]);
            if (res.error) {
              context.showMessage(message: res.errorMessage!);
            } else {
              context.showMessage(message: "Success".tl);
            }
            setState(() {
              _reLogin[source.key] = false;
            });
          },
          trailing: loading
              ? const SizedBox.square(
                  dimension: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.refresh),
        );
      }
      yield ListTile(
        title: Text("Log out".tl),
        onTap: () {
          source.data["account"] = null;
          source.account?.logout();
          source.saveData();
          ComicSourceManager().notifyStateChange();
          setState(() {});
        },
        trailing: const Icon(Icons.logout),
      );
    }
  }
}

class _LoginPage extends StatefulWidget {
  const _LoginPage({required this.config, required this.source});

  final AccountConfig config;

  final ComicSource source;

  @override
  State<_LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<_LoginPage> {
  String username = "";
  String password = "";
  bool loading = false;

  final Map<String, String> _cookies = {};

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const Appbar(title: Text('')),
      body: Center(
        child: Container(
          padding: const EdgeInsets.all(16),
          constraints: const BoxConstraints(maxWidth: 400),
          child: AutofillGroup(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text("Login".tl, style: const TextStyle(fontSize: 24)),
                const SizedBox(height: 32),
                if (widget.config.cookieFields == null)
                  TextField(
                    decoration: InputDecoration(
                      labelText: "Username".tl,
                      border: const OutlineInputBorder(),
                    ),
                    enabled: widget.config.login != null,
                    onChanged: (s) {
                      username = s;
                    },
                    autofillHints: const [AutofillHints.username],
                  ).paddingBottom(16),
                if (widget.config.cookieFields == null)
                  TextField(
                    decoration: InputDecoration(
                      labelText: "Password".tl,
                      border: const OutlineInputBorder(),
                    ),
                    obscureText: true,
                    enabled: widget.config.login != null,
                    onChanged: (s) {
                      password = s;
                    },
                    onSubmitted: (s) => login(),
                    autofillHints: const [AutofillHints.password],
                  ).paddingBottom(16),
                for (var field in widget.config.cookieFields ?? <String>[])
                  TextField(
                    decoration: InputDecoration(
                      labelText: field,
                      border: const OutlineInputBorder(),
                    ),
                    obscureText: true,
                    enabled: widget.config.validateCookies != null,
                    onChanged: (s) {
                      _cookies[field] = s;
                    },
                  ).paddingBottom(16),
                if (widget.config.login == null &&
                    widget.config.cookieFields == null)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.error_outline),
                      const SizedBox(width: 8),
                      Text("Login with password is disabled".tl),
                    ],
                  )
                else
                  Button.filled(
                    isLoading: loading,
                    onPressed: login,
                    child: Text("Continue".tl),
                  ),
                const SizedBox(height: 24),
                if (widget.config.loginWebsite != null)
                  TextButton(
                    onPressed: () {
                      if (App.isLinux) {
                        loginWithWebview2();
                      } else {
                        loginWithWebview();
                      }
                    },
                    child: Text("Login with webview".tl),
                  ),
                const SizedBox(height: 8),
                if (widget.config.registerWebsite != null)
                  TextButton(
                    onPressed: () =>
                        launchUrlString(widget.config.registerWebsite!),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.link),
                        const SizedBox(width: 8),
                        Text("Create Account".tl),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void login() {
    if (widget.config.login != null) {
      if (username.isEmpty || password.isEmpty) {
        showToast(
          message: "Cannot be empty".tl,
          icon: const Icon(Icons.error_outline),
          context: context,
        );
        return;
      }
      setState(() {
        loading = true;
      });
      widget.config.login!(username, password).then((value) {
        if (value.error) {
          context.showMessage(message: value.errorMessage!);
          setState(() {
            loading = false;
          });
        } else {
          if (mounted) {
            context.pop();
          }
        }
      });
    } else if (widget.config.validateCookies != null) {
      setState(() {
        loading = true;
      });
      var cookies = widget.config.cookieFields!
          .map((e) => _cookies[e] ?? '')
          .toList();
      widget.config.validateCookies!(cookies).then((value) {
        if (value) {
          widget.source.data['account'] = 'ok';
          widget.source.saveData();
          context.pop();
        } else {
          context.showMessage(message: "Invalid cookies".tl);
          setState(() {
            loading = false;
          });
        }
      });
    }
  }

  void loginWithWebview() async {
    var url = widget.config.loginWebsite!;
    var title = '';
    bool success = false;

    void validate(InAppWebViewController c) async {
      if (widget.config.checkLoginStatus != null &&
          widget.config.checkLoginStatus!(url, title)) {
        var cookies = (await c.getCookies(url)) ?? [];
        var localStorageItems = await c.webStorage.localStorage.getItems();
        var mappedLocalStorage = <String, dynamic>{};
        for (var item in localStorageItems) {
          if (item.key != null) {
            mappedLocalStorage[item.key!] = item.value;
          }
        }
        widget.source.data['_localStorage'] = mappedLocalStorage;
        await widget.source.saveData();
        SingleInstanceCookieJar.instance?.saveFromResponse(
          Uri.parse(url),
          cookies,
        );
        success = true;
        widget.config.onLoginWithWebviewSuccess?.call();
        App.mainNavigatorKey?.currentContext?.pop();
      }
    }

    await context.to(
      () => AppWebview(
        initialUrl: widget.config.loginWebsite!,
        onNavigation: (u, c) {
          url = u;
          validate(c);
          return false;
        },
        onTitleChange: (t, c) {
          title = t;
          validate(c);
        },
      ),
    );
    if (success) {
      widget.source.data['account'] = 'ok';
      widget.source.saveData();
      context.pop();
    }
  }

  // for linux
  void loginWithWebview2() async {
    if (!await DesktopWebview.isAvailable()) {
      context.showMessage(message: "Webview is not available".tl);
    }

    var url = widget.config.loginWebsite!;
    var title = '';
    bool success = false;

    void onClose() {
      if (success) {
        widget.source.data['account'] = 'ok';
        widget.source.saveData();
        context.pop();
      }
    }

    void validate(DesktopWebview webview) async {
      if (widget.config.checkLoginStatus != null &&
          widget.config.checkLoginStatus!(url, title)) {
        var cookiesMap = await webview.getCookies(url);
        var cookies = <io.Cookie>[];
        cookiesMap.forEach((key, value) {
          cookies.add(io.Cookie(key, value));
        });
        SingleInstanceCookieJar.instance?.saveFromResponse(
          Uri.parse(url),
          cookies,
        );
        var localStorageJson = await webview.evaluateJavascript(
          "JSON.stringify(window.localStorage);",
        );
        var localStorage = <String, dynamic>{};
        try {
          var decoded = jsonDecode(localStorageJson ?? '');
          if (decoded is Map<String, dynamic>) {
            localStorage = decoded;
          }
        } catch (e) {
          Log.error("ComicSourcePage", "Failed to parse localStorage JSON\n$e");
        }
        widget.source.data['_localStorage'] = localStorage;
        await widget.source.saveData();
        success = true;
        widget.config.onLoginWithWebviewSuccess?.call();
        webview.close();
        onClose();
      }
    }

    var webview = DesktopWebview(
      initialUrl: widget.config.loginWebsite!,
      onTitleChange: (t, webview) {
        title = t;
        validate(webview);
      },
      onNavigation: (u, webview) {
        url = u;
        validate(webview);
      },
      onClose: onClose,
    );

    webview.open();
  }
}
