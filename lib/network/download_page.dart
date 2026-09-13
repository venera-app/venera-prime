import 'dart:io';

import 'package:path/path.dart' as p;

/// Clear failure markers only after the replacement image is fully written.
Future<void> writeDownloadedPage(
  File target,
  int index,
  List<int> bytes,
) async {
  // Completion of the asynchronous write is sufficient here. Forcing a
  // physical flush for every page causes storage contention with rendering.
  await target.writeAsBytes(bytes);
  final marker = File(p.join(target.parent.path, '.$index.error.txt'));
  if (await marker.exists()) {
    final placeholder = File(p.join(target.parent.path, '$index.png'));
    if (placeholder.path != target.path && await placeholder.exists()) {
      await placeholder.delete();
    }
    await marker.delete();
  }
}
