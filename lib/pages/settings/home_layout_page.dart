import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/home_layout.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/utils/translations.dart';

class HomeLayoutPage extends StatefulWidget {
  const HomeLayoutPage({super.key});

  @override
  State<HomeLayoutPage> createState() => _HomeLayoutPageState();
}

class _HomeLayoutPageState extends State<HomeLayoutPage> {
  Future<void> _save(HomeLayout layout) async {
    appdata.settings['homeLayout'] = layout.toJson();
    await appdata.saveData();
  }

  Future<void> _addFolder() async {
    final folders = LocalFavoritesManager().folderNames;
    final name = await showPopUpWidget<String?>(
      context,
      PopUpWidgetScaffold(
        title: 'Add favorite folder'.tl,
        body: folders.isEmpty
            ? Center(child: Text('No favorite folders'.tl))
            : ListView.separated(
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: folders.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final name = folders[index];
                  return ListTile(
                    leading: const Icon(Icons.folder_outlined),
                    title: Text(name),
                    trailing: const Icon(Icons.add),
                    onTap: () =>
                        Navigator.of(context, rootNavigator: true).pop(name),
                  );
                },
              ),
      ),
    );
    if (name == null || !mounted) return;
    final layout = HomeLayout.fromJson(appdata.settings['homeLayout']);
    layout.addFolder(name);
    await _save(layout);
  }

  void _settings() {
    showDialog<void>(
      context: context,
      builder: (context) => ContentDialog(
        title: 'Home settings'.tl,
        content: ListenableBuilder(
          listenable: appdata.settings,
          builder: (context, _) {
            final layout = HomeLayout.fromJson(appdata.settings['homeLayout']);
            return SwitchListTile(
              title: Text('Compact home'.tl),
              subtitle: Text('Reduce control height and spacing'.tl),
              value: layout.compact,
              onChanged: (value) {
                layout.compact = value;
                _save(layout);
              },
            );
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('OK'.tl),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: appdata.settings,
    builder: (context, _) {
      final layout = HomeLayout.fromJson(appdata.settings['homeLayout']);
      return Scaffold(
        appBar: Appbar(
          title: Text('Customize home'.tl),
          actions: [
            IconButton(
              tooltip: 'Add favorite folder'.tl,
              icon: const Icon(Icons.add),
              onPressed: _addFolder,
            ),
            IconButton(
              tooltip: 'Home settings'.tl,
              icon: const Icon(Icons.settings_outlined),
              onPressed: _settings,
            ),
            IconButton(
              tooltip: 'Restore defaults'.tl,
              icon: const Icon(Icons.restore),
              onPressed: () => _save(HomeLayout.fromJson(null)),
            ),
          ],
        ),
        body: SafeArea(
          child: ReorderableListView.builder(
            buildDefaultDragHandles: false,
            itemCount: layout.order.length,
            onReorder: (oldIndex, newIndex) {
              if (newIndex > oldIndex) newIndex--;
              layout.order.insert(newIndex, layout.order.removeAt(oldIndex));
              _save(layout);
            },
            itemBuilder: (context, index) {
              final id = layout.order[index];
              return ListTile(
                key: ValueKey(id),
                leading: ReorderableDragStartListener(
                  index: index,
                  child: Tooltip(
                    message: 'Reorder'.tl,
                    child: const SizedBox(
                      width: 48,
                      height: 48,
                      child: Icon(Icons.drag_handle),
                    ),
                  ),
                ),
                title: Text(
                  layout.folders.containsKey(id)
                      ? layout.title(id)
                      : layout.title(id).tl,
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (layout.folders.containsKey(id))
                      IconButton(
                        tooltip: 'Delete'.tl,
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () {
                          layout.removeFolder(id);
                          _save(layout);
                        },
                      ),
                    Switch(
                      key: ValueKey('toggle-$id'),
                      value: !layout.hidden.contains(id),
                      onChanged: (enabled) {
                        if (enabled) {
                          layout.hidden.remove(id);
                        } else {
                          layout.hidden.add(id);
                        }
                        _save(layout);
                      },
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      );
    },
  );
}
