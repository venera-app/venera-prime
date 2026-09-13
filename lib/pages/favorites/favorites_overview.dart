part of 'favorites_page.dart';

class _FavoritesOverview extends StatefulWidget {
  const _FavoritesOverview({
    required this.onShowFolders,
    required this.onOpenLocalSearch,
  });

  final VoidCallback onShowFolders;
  final VoidCallback onOpenLocalSearch;

  @override
  State<_FavoritesOverview> createState() => _FavoritesOverviewState();
}

class _FavoritesOverviewState extends State<_FavoritesOverview> {
  late int _columns;

  @override
  void initState() {
    _columns = (int.tryParse(
              appdata.implicitData['favoritesOverviewColumns'].toString(),
            ) ??
            2)
        .clamp(1, 4);
    appdata.settings.addListener(_update);
    LocalFavoritesManager().addListener(_update);
    super.initState();
  }

  @override
  void dispose() {
    appdata.settings.removeListener(_update);
    LocalFavoritesManager().removeListener(_update);
    super.dispose();
  }

  void _update() {
    if (mounted) {
      setState(() {});
    }
  }

  List<FavoriteData> get _networkFavorites {
    final available = ComicSource.all()
        .where((source) => source.favoriteData != null)
        .map((source) => source.favoriteData!)
        .toList();
    final order = (appdata.settings['favorites'] as List).cast<String>();
    return order
        .map((key) => available.where((data) => data.key == key).firstOrNull)
        .whereType<FavoriteData>()
        .toList();
  }

  void _setColumns(int columns) {
    setState(() {
      _columns = columns;
    });
    appdata.implicitData['favoritesOverviewColumns'] = columns;
    appdata.writeImplicitData();
  }

  IconData _columnIcon(int columns) {
    return switch (columns) {
      1 => Icons.view_agenda_outlined,
      2 => Icons.view_column_outlined,
      3 => Icons.grid_view_outlined,
      _ => Icons.apps,
    };
  }

  @override
  Widget build(BuildContext context) {
    final favoritesPage = context
        .findAncestorStateOfType<_FavoritesPageState>()!;
    final networkFavorites = _networkFavorites;
    final localFolders = LocalFavoritesManager().folderNames;
    final columns = _columns;

    return SmoothCustomScrollView(
      slivers: [
        SliverAppbar(
          style: context.width < changePoint
              ? AppbarStyle.shadow
              : AppbarStyle.blur,
          leading: context.width <= _kTwoPanelChangeWidth
              ? IconButton(
                  tooltip: "Folders".tl,
                  icon: const Icon(Icons.menu),
                  color: context.colorScheme.primary,
                  onPressed: widget.onShowFolders,
                )
              : const SizedBox(),
          title: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: context.width <= _kTwoPanelChangeWidth
                ? widget.onShowFolders
                : null,
            child: Text("Overview".tl),
          ),
          actions: [
            PopupMenuButton<int>(
              icon: Icon(_columnIcon(columns)),
              tooltip: "Layout".tl,
              initialValue: columns,
              onSelected: _setColumns,
              itemBuilder: (context) => List.generate(4, (index) {
                final value = index + 1;
                return PopupMenuItem(
                  value: value,
                  child: Row(
                    children: [
                      Icon(_columnIcon(value), size: 20),
                      const SizedBox(width: 12),
                      Text("@c columns".tlParams({'c': value})),
                      const Spacer(),
                      if (value == columns)
                        Icon(
                          Icons.check,
                          size: 18,
                          color: context.colorScheme.primary,
                        ),
                    ],
                  ),
                );
              }),
            ),
          ],
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          sliver: SliverToBoxAdapter(
            child: Text("Local".tl, style: ts.s18.bold),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          sliver: SliverToBoxAdapter(
            child: Row(
              children: [
                _OverviewAction(
                  icon: Icons.create_new_folder_outlined,
                  label: "Create".tl,
                  onTap: () async {
                    await newFolder();
                    _update();
                  },
                ),
                _OverviewAction(
                  icon: Icons.search,
                  label: "Search".tl,
                  onTap: widget.onOpenLocalSearch,
                ),
                _OverviewAction(
                  icon: Icons.reorder,
                  label: "Sort".tl,
                  onTap: () async {
                    await sortFolders();
                    _update();
                  },
                ),
              ],
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
          sliver: SliverGrid.builder(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              mainAxisExtent: columns >= 3 ? 64 : 42,
              crossAxisSpacing: 6,
              mainAxisSpacing: 4,
            ),
            itemCount: localFolders.length + 1,
            itemBuilder: (context, index) {
              if (index == 0) {
                return _OverviewFolderTile(
                  icon: Icons.folder,
                  title: "Favorite Folders".tl,
                  count: LocalFavoritesManager().totalComics,
                  columns: columns,
                  onTap: () =>
                      favoritesPage.setFolder(false, _localAllFolderLabel),
                );
              }
              final folder = localFolders[index - 1];
              return _OverviewFolderTile(
                icon: Icons.folder,
                title: getFavoriteDataOrNull(folder)?.title ?? folder,
                count: LocalFavoritesManager().folderComics(folder),
                columns: columns,
                onTap: () => favoritesPage.setFolder(false, folder),
              );
            },
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
          sliver: SliverToBoxAdapter(
            child: Divider(color: context.colorScheme.outlineVariant),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          sliver: SliverToBoxAdapter(
            child: Text("Network".tl, style: ts.s18.bold),
          ),
        ),
        if (networkFavorites.isEmpty)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
            sliver: SliverToBoxAdapter(
              child: Text(
                "No folders available".tl,
                style: TextStyle(color: context.colorScheme.outline),
              ),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
            sliver: SliverGrid.builder(
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                mainAxisExtent: columns >= 3 ? 64 : 42,
                crossAxisSpacing: 6,
                mainAxisSpacing: 4,
              ),
              itemCount: networkFavorites.length,
              itemBuilder: (context, index) {
                final data = networkFavorites[index];
                return _OverviewFolderTile(
                  icon: Icons.folder_special,
                  title: data.title,
                  columns: columns,
                  onTap: () => favoritesPage.setFolder(true, data.key),
                );
              },
            ),
          ),
      ],
    );
  }
}

class _OverviewAction extends StatelessWidget {
  const _OverviewAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 24, color: context.colorScheme.primary),
              const SizedBox(height: 2),
              Text(label, style: ts.s12),
            ],
          ),
        ),
      ),
    );
  }
}

class _OverviewFolderTile extends StatelessWidget {
  const _OverviewFolderTile({
    required this.icon,
    required this.title,
    required this.onTap,
    required this.columns,
    this.count,
  });

  final IconData icon;
  final String title;
  final int? count;
  final VoidCallback onTap;
  final int columns;

  @override
  Widget build(BuildContext context) {
    final compact = columns >= 3;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: compact
          ? Stack(
              children: [
                Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          icon,
                          size: 22,
                          color: context.colorScheme.secondary,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: ts.s12,
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                ),
                if (count != null)
                  Positioned(
                    top: 2,
                    right: 2,
                    child: _OverviewCount(count: count!),
                  ),
              ],
            )
          : Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(
                children: [
                  Icon(icon, size: 24, color: context.colorScheme.secondary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: ts.s14,
                    ),
                  ),
                  if (count != null) ...[
                    const SizedBox(width: 4),
                    _OverviewCount(count: count!),
                  ],
                ],
              ),
            ),
    );
  }
}

class _OverviewCount extends StatelessWidget {
  const _OverviewCount({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: context.colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(count.toString(), style: ts.s12),
    );
  }
}
