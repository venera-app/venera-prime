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

  HomeLayout.fromJson(Object? value) : order = [], hidden = {} {
    final data = value is Map ? value : const {};
    final savedOrder = data['order'];
    if (savedOrder is List) {
      for (final id in savedOrder) {
        if (id is String && titles.containsKey(id) && !order.contains(id)) {
          order.add(id);
        }
      }
    }
    order.addAll(titles.keys.where((id) => !order.contains(id)));
    final savedHidden = data['hidden'];
    if (savedHidden is List) {
      hidden.addAll(savedHidden.whereType<String>().where(titles.containsKey));
    }
  }

  Map<String, dynamic> toJson() => {
    'order': List.of(order),
    'hidden': hidden.toList(),
  };
}
