import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:venera/components/components.dart';
import 'package:venera/components/background_tasks.dart';
import 'package:venera/foundation/background_tasks.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/utils/translations.dart';

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  @override
  void initState() {
    HistoryManager().addListener(onUpdate);
    super.initState();
  }

  @override
  void dispose() {
    HistoryManager().removeListener(onUpdate);
    scrollController.dispose();
    super.dispose();
  }

  void onUpdate() {
    setState(() {
      comics = _filteredHistory();
      if (multiSelectMode) {
        selectedComics.removeWhere((comic, _) => !comics.contains(comic));
        if (selectedComics.isEmpty) {
          multiSelectMode = false;
        }
      }
    });
  }

  final scrollController = ScrollController();
  final gridKey = GlobalKey();

  String? _dragDate() {
    final grid = gridKey.currentContext?.findRenderObject();
    final visible = comics.where((comic) => isBlocked(comic) == null).toList();
    if (grid is! RenderSliverGrid || visible.isEmpty) return null;
    final layout = grid.gridDelegate.getLayout(grid.constraints);
    final offset = grid.constraints.scrollOffset + grid.constraints.overlap;
    final index = layout.getMinChildIndexForScrollOffset(
      offset.clamp(0.0, double.infinity),
    );
    return visible[index.clamp(0, visible.length - 1)].lastReadTime
        .split(' ')
        .first;
  }

  var comics = HistoryManager().getAll();
  var controller = FlyoutController();
  final searchController = SearchBarController();
  String query = '';

  List<History> _filteredHistory() => HistoryManager()
      .getAll()
      .where((comic) => comic.matchesQuery(query))
      .toList();

  void _search(String value) {
    setState(() {
      query = value;
      comics = _filteredHistory();
      selectedComics.clear();
      multiSelectMode = false;
    });
  }

  bool multiSelectMode = false;
  Map<History, bool> selectedComics = {};

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

  void _removeHistory(History comic) {
    if (comic.sourceKey.startsWith("Unknown")) {
      HistoryManager().remove(
        comic.id,
        ComicType(int.parse(comic.sourceKey.split(':')[1])),
      );
    } else if (comic.sourceKey == 'local') {
      HistoryManager().remove(comic.id, ComicType.local);
    } else {
      HistoryManager().remove(comic.id, ComicType(comic.sourceKey.hashCode));
    }
  }

  void _refreshHistory(History comic) {
    final key = 'history-refresh:${comic.type.value}:${comic.id}';
    final result = BackgroundTasks.instance.run<void>(key, 'Refresh Info'.tl, (
      task,
    ) async {
      task.update(completed: 0, total: 1, message: comic.title);
      if (comic.type == ComicType.local) {
        task.update(
          completed: 1,
          message: 'Local comics do not need refreshing'.tl,
        );
        return;
      }
      await HistoryManager().refreshHistoryInfo(
        comic,
        isCancelled: () => task.cancelRequested,
        onError: (reason) => task.addError('${comic.title}: $reason'),
      );
      if (!task.cancelRequested) task.update(completed: 1);
    }, cancellable: true);
    showBackgroundTask(context, BackgroundTasks.instance.latest(key)!);
    unawaited(
      result.catchError((Object error, StackTrace stack) {
        Log.error('History refresh', error, stack);
      }),
    );
  }

  void _refreshAllHistories() {
    const key = 'history-refresh:all';
    final result = BackgroundTasks.instance.run<void>(
      key,
      'Refreshing Histories'.tl,
      (task) async {
        await for (final progress in HistoryManager().refreshAllHistoriesStream(
          isCancelled: () => task.cancelRequested,
          onError: (history, reason) =>
              task.addError('${history.title}: $reason'),
        )) {
          task.update(
            completed: progress.current,
            total: progress.total,
            message:
                'Refresh Completed: Success @success, Failed @failed, Skipped @skipped'
                    .tlParams({
                      'success': progress.success,
                      'failed': progress.failed,
                      'skipped': progress.skipped,
                    }),
          );
        }
      },
      cancellable: true,
    );
    showBackgroundTask(context, BackgroundTasks.instance.latest(key)!);
    unawaited(
      result.catchError((Object error, StackTrace stack) {
        Log.error('History refresh', error, stack);
      }),
    );
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
      IconButton(
        icon: const Icon(Icons.delete),
        tooltip: "Delete".tl,
        onPressed: selectedComics.isEmpty
            ? null
            : () {
                final comicsToDelete = List<History>.from(selectedComics.keys);
                setState(() {
                  multiSelectMode = false;
                  selectedComics.clear();
                });

                HistoryManager().batchDeleteHistories(
                  comicsToDelete
                      .map((comic) => ComicID(comic.type, comic.id))
                      .toList(),
                );
              },
      ),
    ];

    List<Widget> normalActions = [
      IconButton(
        icon: const Icon(Icons.refresh),
        tooltip: 'Refresh All Histories'.tl,
        onPressed: _refreshAllHistories,
      ),
      IconButton(
        icon: const Icon(Icons.checklist),
        tooltip: multiSelectMode ? "Exit Multi-Select".tl : "Multi-Select".tl,
        onPressed: () {
          setState(() {
            multiSelectMode = !multiSelectMode;
          });
        },
      ),
      Tooltip(
        message: 'Clear History'.tl,
        child: Flyout(
          controller: controller,
          flyoutBuilder: (context) {
            return FlyoutContent(
              title: 'Clear History'.tl,
              content: Text('Are you sure you want to clear your history?'.tl),
              actions: [
                Button.outlined(
                  onPressed: () {
                    HistoryManager().clearUnfavoritedHistory();
                    context.pop();
                  },
                  child: Text('Clear Unfavorited'.tl),
                ),
                const SizedBox(width: 4),
                Button.filled(
                  color: context.colorScheme.error,
                  onPressed: () {
                    HistoryManager().clearHistory();
                    context.pop();
                  },
                  child: Text('Clear'.tl),
                ),
              ],
            );
          },
          child: IconButton(
            icon: const Icon(Icons.clear_all),
            onPressed: () {
              controller.show();
            },
          ),
        ),
      ),
    ];

    return PopScope(
      canPop: !multiSelectMode,
      onPopInvokedWithResult: (didPop, result) {
        if (multiSelectMode) {
          setState(() {
            multiSelectMode = false;
            selectedComics.clear();
          });
        }
      },
      child: Scaffold(
        body: AppScrollBar(
          controller: scrollController,
          topPadding: MediaQuery.paddingOf(context).top + 104,
          dragLabelBuilder: _dragDate,
          child: SmoothCustomScrollView(
            controller: scrollController,
            slivers: [
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
                    : Text('History'.tl),
                actions: multiSelectMode ? selectActions : normalActions,
              ),
              SliverSearchBar(
                controller: searchController,
                onChanged: _search,
                embedded: true,
              ),
              SliverGridComics(
                key: gridKey,
                comics: comics,
                selections: selectedComics,
                onLongPressed: null,
                onTap: multiSelectMode
                    ? (c, heroID) {
                        setState(() {
                          if (selectedComics.containsKey(c as History)) {
                            selectedComics.remove(c);
                          } else {
                            selectedComics[c] = true;
                          }
                          if (selectedComics.isEmpty) {
                            multiSelectMode = false;
                          }
                        });
                      }
                    : null,
                badgeBuilder: (c) {
                  return ComicSource.find(c.sourceKey)?.name;
                },
                menuBuilder: (c) {
                  return [
                    MenuEntry(
                      icon: Icons.refresh,
                      text: 'Refresh Info'.tl,
                      onClick: () {
                        _refreshHistory(c as History);
                      },
                    ),
                    MenuEntry(
                      icon: Icons.remove,
                      text: 'Remove'.tl,
                      color: context.colorScheme.error,
                      onClick: () {
                        _removeHistory(c as History);
                      },
                    ),
                  ];
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  String getDescription(History h) {
    var res = "";
    if (h.ep >= 1) {
      res += "Chapter @ep".tlParams({"ep": h.ep});
    }
    if (h.page >= 1) {
      if (h.ep >= 1) {
        res += " - ";
      }
      res += "Page @page".tlParams({"page": h.page});
    }
    return res;
  }
}
