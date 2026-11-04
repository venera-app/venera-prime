class HomeLayout {
  static const titles = <String, String>{
    'search': 'Search',
    'sync': 'Data Sync',
    'random': 'Random comic',
    'history': 'History',
    'readLater': 'Read later',
    'statistics': 'Reading statistics',
    'local': 'Local',
    'updates': 'Follow Updates',
    'sources': 'Comic Source',
    'images': 'Image Favorites',
  };

  final List<String> order;
  final Set<String> hidden;
  final Map<String, String> folders = {};
  bool compact = false;

  String title(String id) => folders[id] ?? titles[id] ?? id;

  void addFolder(String name) {
    final id = 'folder:$name';
    folders[id] = name;
    if (!order.contains(id)) order.add(id);
    hidden.remove(id);
  }

  void removeFolder(String id) {
    folders.remove(id);
    order.remove(id);
    hidden.remove(id);
  }

  HomeLayout.fromJson(Object? value) : order = [], hidden = {} {
    final data = value is Map ? value : const {};
    compact = data['compact'] == true;
    final savedFolders = data['folders'];
    if (savedFolders is Map) {
      for (final entry in savedFolders.entries) {
        if (entry.key is String &&
            entry.value is String &&
            entry.key == 'folder:${entry.value}' &&
            (entry.value as String).isNotEmpty) {
          folders[entry.key] = entry.value;
        }
      }
    }
    bool valid(String id) => titles.containsKey(id) || folders.containsKey(id);
    final savedOrder = data['order'];
    if (savedOrder is List) {
      for (final id in savedOrder) {
        if (id is String && valid(id) && !order.contains(id)) {
          order.add(id);
        }
      }
    }
    order.addAll(titles.keys.where((id) => !order.contains(id)));
    order.addAll(folders.keys.where((id) => !order.contains(id)));
    final savedHidden = data['hidden'];
    if (savedHidden is List) {
      hidden.addAll(savedHidden.whereType<String>().where(valid));
    }
  }

  Map<String, dynamic> toJson() => {
    'compact': compact,
    'folders': Map.of(folders),
    'order': List.of(order),
    'hidden': hidden.toList(),
  };
}
