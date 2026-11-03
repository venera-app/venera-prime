import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/pages/comic_details_page/comic_page.dart';
import 'package:venera/pages/downloading_page.dart';
import 'package:venera/pages/favorites/favorites_page.dart';
import 'package:venera/utils/cbz.dart';
import 'package:venera/utils/epub.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/pdf.dart';
import 'package:venera/utils/translations.dart';
import 'package:zip_flutter/zip_flutter.dart';
import 'package:url_launcher/url_launcher_string.dart';

class LocalComicsPage extends StatefulWidget {
  const LocalComicsPage({super.key});

  @override
  State<LocalComicsPage> createState() => _LocalComicsPageState();
}

class _LocalComicsPageState extends State<LocalComicsPage> {
  late List<LocalComic> comics;

  late LocalSortType sortType;

  int? folder;
  bool uncategorized = false;
  bool customOrder = false;
  final _sizes = <String, Future<int>>{};

  String keyword = "";

  bool searchMode = false;

  bool multiSelectMode = false;

  Map<LocalComic, bool> selectedComics = {};

  void update() {
    if (!mounted) return;
    final placements = LocalManager().library.placements;
    final items = keyword.isEmpty
        ? LocalManager().getComics(sortType)
        : LocalManager().search(keyword);
    items.removeWhere((c) {
      final assigned = placements[(c.id, c.comicType.value)]?.folder;
      return uncategorized
          ? assigned != null
          : folder != null && assigned != folder;
    });
    if (customOrder) {
      final original = {for (var i = 0; i < items.length; i++) items[i]: i};
      items.sort((a, b) {
        final x = placements[(a.id, a.comicType.value)]?.position ?? 0x7fffffff;
        final y = placements[(b.id, b.comicType.value)]?.position ?? 0x7fffffff;
        return x == y ? original[a]!.compareTo(original[b]!) : x.compareTo(y);
      });
    }
    setState(() {
      comics = items;
      selectedComics.removeWhere(
        (c, _) => !items.any((v) => v.id == c.id && v.comicType == c.comicType),
      );
      _sizes.clear();
    });
  }

  Future<int> _size(LocalComic comic) async {
    var bytes = 0;
    await for (final entity in Directory(
      comic.baseDir,
    ).list(recursive: true, followLinks: false)) {
      if (entity is File) bytes += await entity.length();
    }
    return bytes;
  }

  Future<void> _openComic(LocalComic comic) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: Text(comic.title),
        children: [
          SimpleDialogOption(
            child: Text('Read'.tl),
            onPressed: () {
              Navigator.pop(dialogContext);
              comic.read();
            },
          ),
          SimpleDialogOption(
            child: Text('View Detail'.tl),
            onPressed: () {
              Navigator.pop(dialogContext);
              if (comic.comicType == ComicType.local) {
                showDialog<void>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: Text(comic.title),
                    content: SingleChildScrollView(
                      child: Text(
                        [
                          comic.subtitle,
                          comic.description,
                          comic.tags.join(', '),
                          comic.baseDir,
                        ].where((s) => s.isNotEmpty).join('\n\n'),
                      ),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: Text('Close'.tl),
                      ),
                    ],
                  ),
                );
              } else {
                context.to(
                  () => ComicPage(id: comic.id, sourceKey: comic.sourceKey),
                );
              }
            },
          ),
          for (final entry
              in comic.chapters?.allChapters.entries ??
                  <MapEntry<String, String>>[])
            if (comic.downloadedChapters.contains(entry.key))
              SimpleDialogOption(
                child: Text(entry.value),
                onPressed: () {
                  Navigator.pop(dialogContext);
                  comic.read(chapterId: entry.key);
                },
              ),
        ],
      ),
    );
  }

  Future<void> _moveComics(List<LocalComic> items) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: Text('Move to folder'.tl),
        children: [
          for (final target in [
            (id: null, name: 'Uncategorized'.tl),
            ...LocalManager().library.folders,
          ])
            SimpleDialogOption(
              child: Text(target.name),
              onPressed: () {
                LocalManager().library.move(
                  items.map((c) => (c.id, c.comicType.value)).toList(),
                  target.id,
                );
                Navigator.pop(dialogContext);
                update();
              },
            ),
        ],
      ),
    );
  }

  Future<void> _folderName({int? id, String name = ''}) async {
    final controller = TextEditingController(text: name);
    String? error;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, refresh) => AlertDialog(
          title: Text((id == null ? 'New folder' : 'Rename folder').tl),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(errorText: error),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text('Cancel'.tl),
            ),
            FilledButton(
              onPressed: () {
                try {
                  if (id == null) {
                    LocalManager().library.createFolder(controller.text);
                  } else {
                    LocalManager().library.renameFolder(id, controller.text);
                  }
                  Navigator.pop(dialogContext);
                  update();
                } catch (_) {
                  refresh(
                    () => error = 'Use a unique, non-empty folder name'.tl,
                  );
                }
              },
              child: Text('Save'.tl),
            ),
          ],
        ),
      ),
    );
    // Dialog transition may still hold its text field until the next frame.
    WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose());
  }

  Future<void> _reorder({bool folders = false}) async {
    final entries = folders
        ? LocalManager().library.folders
              .map((f) => (key: f.id as Object, label: f.name))
              .toList()
        : comics
              .map(
                (c) =>
                    (key: (c.id, c.comicType.value) as Object, label: c.title),
              )
              .toList();
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, refresh) => AlertDialog(
          title: Text((folders ? 'Sort folders' : 'Custom order').tl),
          content: SizedBox(
            width: 480,
            height: 400,
            child: ReorderableListView.builder(
              itemCount: entries.length,
              onReorder: (oldIndex, newIndex) => refresh(() {
                if (newIndex > oldIndex) newIndex--;
                entries.insert(newIndex, entries.removeAt(oldIndex));
              }),
              itemBuilder: (context, index) => ListTile(
                key: ValueKey(entries[index].key),
                title: Text(entries[index].label),
                contentPadding: const EdgeInsets.only(left: 12, right: 48),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text('Cancel'.tl),
            ),
            FilledButton(
              onPressed: () {
                if (folders) {
                  LocalManager().library.reorderFolders(
                    entries.map((e) => e.key as int).toList(),
                  );
                } else {
                  LocalManager().library.reorderComics(
                    entries.map((e) => e.key as (String, int)).toList(),
                  );
                  customOrder = true;
                  appdata.implicitData['local_custom_order'] = true;
                  appdata.writeImplicitData();
                }
                Navigator.pop(dialogContext);
                update();
              },
              child: Text('Save'.tl),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void initState() {
    var sort = appdata.implicitData["local_sort"] ?? "name";
    sortType = LocalSortType.fromString(sort);
    customOrder = appdata.implicitData['local_custom_order'] == true;
    comics = LocalManager().getComics(sortType);
    update();
    LocalManager().addListener(update);
    super.initState();
  }

  @override
  void dispose() {
    LocalManager().removeListener(update);
    super.dispose();
  }

  void sort() {
    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return ContentDialog(
              title: "Sort".tl,
              content: RadioGroup<LocalSortType>(
                groupValue: sortType,
                onChanged: (v) {
                  setState(() {
                    sortType = v ?? sortType;
                  });
                },
                child: Column(
                  children: [
                    RadioListTile<LocalSortType>(
                      title: Text("Name".tl),
                      value: LocalSortType.name,
                    ),
                    RadioListTile<LocalSortType>(
                      title: Text("Date".tl),
                      value: LocalSortType.timeAsc,
                    ),
                    RadioListTile<LocalSortType>(
                      title: Text("Date Desc".tl),
                      value: LocalSortType.timeDesc,
                    ),
                  ],
                ),
              ),
              actions: [
                FilledButton(
                  onPressed: () {
                    customOrder = false;
                    appdata.implicitData['local_custom_order'] = false;
                    appdata.implicitData["local_sort"] = sortType.value;
                    appdata.writeImplicitData();
                    Navigator.pop(context);
                    update();
                  },
                  child: Text("Confirm".tl),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget buildMultiSelectMenu() {
    return MenuButton(
      entries: [
        MenuEntry(
          icon: Icons.drive_file_move_outline,
          text: 'Move to folder'.tl,
          onClick: () => _moveComics(selectedComics.keys.toList()),
        ),
        MenuEntry(
          icon: Icons.delete_outline,
          text: "Delete".tl,
          onClick: () {
            deleteComics(selectedComics.keys.toList()).then((value) {
              if (value) {
                setState(() {
                  multiSelectMode = false;
                  selectedComics.clear();
                });
              }
            });
          },
        ),
        MenuEntry(
          icon: Icons.favorite_border,
          text: "Add to favorites".tl,
          onClick: () {
            addFavorite(selectedComics.keys.toList());
          },
        ),
        if (selectedComics.length == 1)
          MenuEntry(
            icon: Icons.folder_open,
            text: "Open Folder".tl,
            onClick: () {
              openComicFolder(selectedComics.keys.first);
            },
          ),
        if (selectedComics.length == 1)
          MenuEntry(
            icon: Icons.chrome_reader_mode_outlined,
            text: "View Detail".tl,
            onClick: () {
              context.to(
                () => ComicPage(
                  id: selectedComics.keys.first.id,
                  sourceKey: selectedComics.keys.first.sourceKey,
                ),
              );
            },
          ),
        if (selectedComics.isNotEmpty)
          ...exportActions(selectedComics.keys.toList()),
      ],
    );
  }

  void selectAll() {
    setState(() {
      selectedComics = comics.asMap().map((k, v) => MapEntry(v, true));
    });
  }

  void deSelect() {
    setState(() {
      selectedComics.clear();
    });
  }

  void invertSelection() {
    setState(() {
      comics.asMap().forEach((k, v) {
        selectedComics[v] = !selectedComics.putIfAbsent(v, () => false);
      });
      selectedComics.removeWhere((k, v) => !v);
    });
  }

  @override
  Widget build(BuildContext context) {
    List<Widget> selectActions = [
      IconButton(
        icon: const Icon(Icons.select_all),
        tooltip: "Select All".tl,
        onPressed: selectAll,
      ),
      IconButton(
        icon: const Icon(Icons.deselect),
        tooltip: "Deselect".tl,
        onPressed: deSelect,
      ),
      IconButton(
        icon: const Icon(Icons.flip),
        tooltip: "Invert Selection".tl,
        onPressed: invertSelection,
      ),
      buildMultiSelectMenu(),
    ];

    List<Widget> normalActions = [
      MenuButton(
        entries: [
          MenuEntry(
            icon: Icons.create_new_folder_outlined,
            text: 'New folder'.tl,
            onClick: () => _folderName(),
          ),
          MenuEntry(
            icon: Icons.swap_vert,
            text: 'Custom order'.tl,
            onClick: () => _reorder(),
          ),
          MenuEntry(
            icon: Icons.folder_copy_outlined,
            text: 'Sort folders'.tl,
            onClick: () => _reorder(folders: true),
          ),
          if (folder != null) ...[
            MenuEntry(
              icon: Icons.edit_outlined,
              text: 'Rename folder'.tl,
              onClick: () => _folderName(
                id: folder,
                name: LocalManager().library.folders
                    .firstWhere((f) => f.id == folder)
                    .name,
              ),
            ),
            MenuEntry(
              icon: Icons.folder_delete_outlined,
              text: 'Remove category (keep files)'.tl,
              onClick: () {
                LocalManager().library.deleteFolder(folder!);
                folder = null;
                update();
              },
            ),
          ],
        ],
      ),
      Tooltip(
        message: "Search".tl,
        child: IconButton(
          icon: const Icon(Icons.search),
          onPressed: () {
            setState(() {
              searchMode = true;
            });
          },
        ),
      ),
      Tooltip(
        message: "Sort".tl,
        child: IconButton(icon: const Icon(Icons.sort), onPressed: sort),
      ),
      Tooltip(
        message: "Downloading".tl,
        child: IconButton(
          icon: const Icon(Icons.download),
          onPressed: () {
            showPopUpWidget(context, const DownloadingPage());
          },
        ),
      ),
    ];

    var body = Scaffold(
      body: SmoothCustomScrollView(
        slivers: [
          if (!searchMode)
            SliverAppbar(
              leading: Tooltip(
                message: multiSelectMode ? "Cancel".tl : "Back".tl,
                child: IconButton(
                  onPressed: () {
                    if (multiSelectMode) {
                      setState(() {
                        multiSelectMode = false;
                        selectedComics.clear();
                      });
                    } else {
                      context.pop();
                    }
                  },
                  icon: multiSelectMode
                      ? const Icon(Icons.close)
                      : const Icon(Icons.arrow_back),
                ),
              ),
              title: multiSelectMode
                  ? Text(selectedComics.length.toString())
                  : Text("Local".tl),
              actions: multiSelectMode ? selectActions : normalActions,
            )
          else if (searchMode)
            SliverAppbar(
              leading: Tooltip(
                message: multiSelectMode ? "Cancel".tl : "Cancel".tl,
                child: IconButton(
                  icon: multiSelectMode
                      ? const Icon(Icons.close)
                      : const Icon(Icons.close),
                  onPressed: () {
                    if (multiSelectMode) {
                      setState(() {
                        multiSelectMode = false;
                        selectedComics.clear();
                      });
                    } else {
                      setState(() {
                        searchMode = false;
                        keyword = "";
                        update();
                      });
                    }
                  },
                ),
              ),
              title: multiSelectMode
                  ? Text(selectedComics.length.toString())
                  : TextField(
                      autofocus: true,
                      decoration: InputDecoration(
                        hintText: "Search".tl,
                        border: InputBorder.none,
                      ),
                      onChanged: (v) {
                        keyword = v;
                        update();
                      },
                    ),
              actions: multiSelectMode ? selectActions : null,
            ),
          SliverToBoxAdapter(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Row(
                  spacing: 8,
                  children: [
                    ChoiceChip(
                      label: Text('All'.tl),
                      selected: folder == null && !uncategorized,
                      onSelected: (_) {
                        folder = null;
                        uncategorized = false;
                        update();
                      },
                    ),
                    ChoiceChip(
                      label: Text('Uncategorized'.tl),
                      selected: uncategorized,
                      onSelected: (_) {
                        folder = null;
                        uncategorized = true;
                        update();
                      },
                    ),
                    for (final f in LocalManager().library.folders)
                      ChoiceChip(
                        label: Text(f.name),
                        selected: folder == f.id,
                        onSelected: (_) {
                          folder = f.id;
                          uncategorized = false;
                          update();
                        },
                      ),
                  ],
                ),
              ),
            ),
          ),
          SliverGridComics(
            itemWrapper: (c, child) {
              final comic = c as LocalComic;
              final source =
                  comic.comicType.comicSource?.name ??
                  (comic.comicType == ComicType.local
                      ? 'Local'.tl
                      : comic.sourceKey);
              return Column(
                children: [
                  Expanded(child: child),
                  FutureBuilder<int>(
                    future: _sizes.putIfAbsent(
                      comic.baseDir,
                      () => _size(comic),
                    ),
                    builder: (context, snapshot) => Text(
                      '$source · ${snapshot.hasData
                          ? bytesToReadableString(snapshot.data!)
                          : snapshot.hasError
                          ? "Unavailable".tl
                          : "…"}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ),
                ],
              );
            },
            comics: comics,
            selections: selectedComics,
            onLongPressed: (c, heroID) {
              setState(() {
                multiSelectMode = true;
                selectedComics[c as LocalComic] = true;
              });
            },
            onTap: (c, heroID) {
              if (multiSelectMode) {
                setState(() {
                  if (selectedComics.containsKey(c as LocalComic)) {
                    selectedComics.remove(c);
                  } else {
                    selectedComics[c] = true;
                  }
                  if (selectedComics.isEmpty) {
                    multiSelectMode = false;
                  }
                });
              } else {
                // prevent dirty data
                var comic = LocalManager().find(
                  c.id,
                  (c as LocalComic).comicType,
                );
                if (comic != null) _openComic(comic);
              }
            },
            menuBuilder: (c) {
              return [
                MenuEntry(
                  icon: Icons.drive_file_move_outline,
                  text: 'Move to folder'.tl,
                  onClick: () => _moveComics([c as LocalComic]),
                ),
                MenuEntry(
                  icon: Icons.folder_open,
                  text: "Open Folder".tl,
                  onClick: () {
                    openComicFolder(c as LocalComic);
                  },
                ),
                MenuEntry(
                  icon: Icons.delete,
                  text: "Delete".tl,
                  onClick: () {
                    deleteComics([c as LocalComic]).then((value) {
                      if (value && multiSelectMode) {
                        setState(() {
                          multiSelectMode = false;
                          selectedComics.clear();
                        });
                      }
                    });
                  },
                ),
                ...exportActions([c as LocalComic]),
              ];
            },
          ),
        ],
      ),
    );

    return PopScope(
      canPop: !multiSelectMode && !searchMode,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (multiSelectMode) {
          setState(() {
            multiSelectMode = false;
            selectedComics.clear();
          });
        } else if (searchMode) {
          setState(() {
            searchMode = false;
            keyword = "";
            update();
          });
        }
      },
      child: body,
    );
  }

  Future<bool> deleteComics(List<LocalComic> comics) async {
    bool isDeleted = false;
    await showDialog(
      context: App.rootContext,
      builder: (context) {
        bool removeComicFile = true;
        bool removeFavoriteAndHistory = true;
        return StatefulBuilder(
          builder: (context, state) {
            return ContentDialog(
              title: "Delete".tl,
              content: Column(
                children: [
                  CheckboxListTile(
                    title: Text("Remove local favorite and history".tl),
                    value: removeFavoriteAndHistory,
                    onChanged: (v) {
                      state(() {
                        removeFavoriteAndHistory = !removeFavoriteAndHistory;
                      });
                    },
                  ),
                  CheckboxListTile(
                    title: Text("Also remove files on disk".tl),
                    value: removeComicFile,
                    onChanged: (v) {
                      state(() {
                        removeComicFile = !removeComicFile;
                      });
                    },
                  ),
                ],
              ),
              actions: [
                if (comics.length == 1 && comics.first.hasChapters)
                  TextButton(
                    child: Text("Delete Chapters".tl),
                    onPressed: () {
                      context.pop();
                      showDeleteChaptersPopWindow(context, comics.first);
                    },
                  ),
                FilledButton(
                  onPressed: () {
                    context.pop();
                    LocalManager().batchDeleteComics(
                      comics,
                      removeComicFile,
                      removeFavoriteAndHistory,
                    );
                    isDeleted = true;
                  },
                  child: Text("Confirm".tl),
                ),
              ],
            );
          },
        );
      },
    );
    return isDeleted;
  }

  List<MenuEntry> exportActions(List<LocalComic> comics) {
    return [
      MenuEntry(
        icon: Icons.outbox_outlined,
        text: "Export as cbz".tl,
        onClick: () {
          exportComics(comics, CBZ.export, ".cbz");
        },
      ),
      MenuEntry(
        icon: Icons.picture_as_pdf_outlined,
        text: "Export as pdf".tl,
        onClick: () async {
          exportComics(comics, createPdfFromComicIsolate, ".pdf");
        },
      ),
      MenuEntry(
        icon: Icons.import_contacts_outlined,
        text: "Export as epub".tl,
        onClick: () async {
          exportComics(comics, createEpubWithLocalComic, ".epub");
        },
      ),
    ];
  }

  /// Export using a private staging directory so minimized exports cannot
  /// delete each other's work when a second export is started.
  void exportComics(
    List<LocalComic> comics,
    ExportComicFunc export,
    String ext,
  ) async {
    comics = List.of(comics);
    if (comics.isEmpty) return;
    var current = 0;
    var cancelled = false;
    Directory? staging;
    final controller = showLoadingDialog(
      context,
      allowBackground: true,
      message: "${"Exporting".tl} 0/${comics.length}",
      withProgress: comics.length > 1,
      onCancel: () => cancelled = true,
    );
    try {
      staging = await Directory(App.cachePath).createTemp('comics-export-');
      final output = await Directory('${staging.path}/items').create();
      var fileName = '';
      for (final comic in comics) {
        if (cancelled) return;
        fileName = FilePath.join(
          output.path,
          sanitizeFileName(comic.title, maxLength: 100) + ext,
        );
        await export(comic, fileName);
        current++;
        controller.setMessage("${"Exporting".tl} $current/${comics.length}");
        controller.setProgress(current / comics.length);
      }
      if (cancelled) return;
      if (comics.length == 1) {
        await saveFile(file: File(fileName), filename: File(fileName).name);
      } else {
        controller.setProgress(null);
        controller.setMessage('Compressing'.tl);
        final archive = File('${staging.path}/comics_export.zip');
        await ZipFile.compressFolderAsync(output.path, archive.path);
        if (cancelled) return;
        await saveFile(file: archive, filename: 'comics_export.zip');
      }
    } catch (error, stack) {
      controller.fail(error);
      Log.error('Export Comics', error, stack);
      if (mounted) context.showMessage(message: error.toString());
    } finally {
      await staging?.deleteIgnoreError(recursive: true);
      controller.close();
    }
  }
}

typedef ExportComicFunc =
    Future<File> Function(LocalComic comic, String outFilePath);

/// Opens the folder containing the comic in the system file explorer
Future<void> openComicFolder(LocalComic comic) async {
  try {
    final folderPath = comic.baseDir;

    if (App.isWindows) {
      await Process.run('explorer', [folderPath]);
    } else if (App.isMacOS) {
      await Process.run('open', [folderPath]);
    } else if (App.isLinux) {
      // Try different file managers commonly found on Linux
      try {
        await Process.run('xdg-open', [folderPath]);
      } catch (e) {
        // Fallback to other common file managers
        try {
          await Process.run('nautilus', [folderPath]);
        } catch (e) {
          try {
            await Process.run('dolphin', [folderPath]);
          } catch (e) {
            try {
              await Process.run('thunar', [folderPath]);
            } catch (e) {
              // Last resort: use the URL launcher with file:// protocol
              await launchUrlString('file://$folderPath');
            }
          }
        }
      }
    } else {
      // For mobile platforms, use the URL launcher with file:// protocol
      await launchUrlString('file://$folderPath');
    }
  } catch (e, s) {
    Log.error("Open Folder", "Failed to open comic folder: $e", s);
    // Show error message to user
    if (App.rootContext.mounted) {
      App.rootContext.showMessage(message: "Failed to open folder: $e");
    }
  }
}

void showDeleteChaptersPopWindow(BuildContext context, LocalComic comic) {
  var chapters = <String>[];

  showPopUpWidget(
    context,
    PopUpWidgetScaffold(
      title: "Delete Chapters".tl,
      body: StatefulBuilder(
        builder: (context, setState) {
          return Column(
            children: [
              Expanded(
                child: ListView.builder(
                  itemCount: comic.downloadedChapters.length,
                  itemBuilder: (context, index) {
                    var id = comic.downloadedChapters[index];
                    var chapter = comic.chapters![id] ?? "Unknown Chapter";
                    return CheckboxListTile(
                      title: Text(chapter),
                      value: chapters.contains(id),
                      onChanged: (v) {
                        setState(() {
                          if (v == true) {
                            chapters.add(id);
                          } else {
                            chapters.remove(id);
                          }
                        });
                      },
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(8.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    FilledButton(
                      onPressed: () {
                        Future.delayed(const Duration(milliseconds: 200), () {
                          LocalManager().deleteComicChapters(comic, chapters);
                        });
                        App.rootContext.pop();
                      },
                      child: Text("Submit".tl),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    ),
  );
}
