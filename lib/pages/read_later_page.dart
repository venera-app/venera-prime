import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/read_later.dart';
import 'package:venera/pages/comic_details_page/comic_page.dart';
import 'package:venera/pages/favorites/favorites_page.dart';
import 'package:venera/utils/translations.dart';

class ReadLaterPage extends StatefulWidget {
  const ReadLaterPage({super.key});
  @override
  State<ReadLaterPage> createState() => _ReadLaterPageState();
}

class _ReadLaterPageState extends State<ReadLaterPage> {
  var comics = ReadLaterManager().getAll();
  var selected = <ReadLaterComic, bool>{};
  var keyword = '';
  var selecting = false;

  @override
  void initState() {
    super.initState();
    ReadLaterManager().addListener(_update);
  }

  @override
  void dispose() {
    ReadLaterManager().removeListener(_update);
    super.dispose();
  }

  void _update() {
    if (!mounted) return;
    setState(() {
      comics = ReadLaterManager().getAll(keyword: keyword);
      selected.removeWhere((comic, _) => !comics.contains(comic));
      if (selected.isEmpty) selecting = false;
    });
  }

  void _open(ReadLaterComic comic) {
    if (comic.type == ComicType.local) {
      final local = LocalManager().find(comic.id, ComicType.local);
      if (local != null) {
        local.read();
        return;
      }
    }
    if (ComicSource.find(comic.sourceKey) == null) {
      context.showMessage(message: 'Comic source not found'.tl);
      return;
    }
    context.to(
      () => ComicPage(
        id: comic.id,
        sourceKey: comic.sourceKey,
        cover: comic.cover,
        title: comic.title,
      ),
    );
  }

  void _deleteSelected() {
    final deleted = List<ReadLaterComic>.from(selected.keys);
    ReadLaterManager().removeMany(deleted);
    if (deleted.isEmpty || !mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Removed @count items'.tlParams({'count': deleted.length}),
        ),
        action: SnackBarAction(
          label: 'Undo'.tl,
          onPressed: () => ReadLaterManager().restore(deleted),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && selecting) setState(() => selecting = false);
      },
      child: Scaffold(
        body: SmoothCustomScrollView(
          slivers: [
            SliverAppbar(
              leading: IconButton(
                icon: Icon(selecting ? Icons.close : Icons.arrow_back),
                tooltip: (selecting ? 'Cancel' : 'Back').tl,
                onPressed: () => selecting
                    ? setState(() {
                        selecting = false;
                        selected.clear();
                      })
                    : context.pop(),
              ),
              title: selecting
                  ? Text(selected.length.toString())
                  : Text('Read later'.tl),
              actions: selecting
                  ? [
                      IconButton(
                        icon: const Icon(Icons.select_all),
                        tooltip: 'Select All'.tl,
                        onPressed: () => setState(
                          () => selected = {for (final c in comics) c: true},
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.favorite_border),
                        tooltip: 'Add to favorites'.tl,
                        onPressed: selected.isEmpty
                            ? null
                            : () => addFavorite(selected.keys.toList()),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline),
                        tooltip: 'Delete'.tl,
                        onPressed: selected.isEmpty ? null : _deleteSelected,
                      ),
                    ]
                  : [
                      IconButton(
                        icon: const Icon(Icons.search),
                        tooltip: 'Search'.tl,
                        onPressed: () async {
                          final value = await showDialog<String>(
                            context: context,
                            builder: (context) =>
                                _SearchDialog(initial: keyword),
                          );
                          if (value != null) {
                            setState(() {
                              keyword = value;
                              comics = ReadLaterManager().getAll(
                                keyword: keyword,
                              );
                            });
                          }
                        },
                      ),
                      IconButton(
                        icon: const Icon(Icons.checklist),
                        tooltip: 'Multi-Select'.tl,
                        onPressed: () => setState(() => selecting = true),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_sweep_outlined),
                        tooltip: 'Clear'.tl,
                        onPressed: comics.isEmpty
                            ? null
                            : ReadLaterManager().clear,
                      ),
                    ],
            ),
            SliverGridComics(
              comics: comics,
              selections: selected,
              onLongPressed: (comic, _) => setState(() {
                selecting = true;
                selected[comic as ReadLaterComic] = true;
              }),
              onTap: (comic, _) {
                if (selecting) {
                  final item = comic as ReadLaterComic;
                  setState(() {
                    if (selected.remove(item) == null) selected[item] = true;
                    if (selected.isEmpty) selecting = false;
                  });
                } else {
                  _open(comic as ReadLaterComic);
                }
              },
              badgeBuilder: (comic) =>
                  ComicSource.find(comic.sourceKey)?.name ?? 'Unavailable'.tl,
              menuBuilder: (comic) => [
                MenuEntry(
                  icon: Icons.delete_outline,
                  text: 'Remove'.tl,
                  onClick: () => ReadLaterManager().removeComic(comic),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SearchDialog extends StatefulWidget {
  const _SearchDialog({required this.initial});
  final String initial;
  @override
  State<_SearchDialog> createState() => _SearchDialogState();
}

class _SearchDialogState extends State<_SearchDialog> {
  late final controller = TextEditingController(text: widget.initial);
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Search'.tl),
    content: TextField(controller: controller, autofocus: true),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text('Cancel'.tl),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, controller.text),
        child: Text('Confirm'.tl),
      ),
    ],
  );
}
