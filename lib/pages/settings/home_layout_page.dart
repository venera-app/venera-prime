import 'package:flutter/material.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/home_layout.dart';
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

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: appdata.settings,
    builder: (context, _) {
      final layout = HomeLayout.fromJson(appdata.settings['homeLayout']);
      return Scaffold(
        appBar: AppBar(
          title: Text('Customize home'.tl),
          actions: [
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
                title: Text(HomeLayout.titles[id]!.tl),
                trailing: Switch(
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
              );
            },
          ),
        ),
      );
    },
  );
}
