import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';

void main() {
  test('source update state is exclusive and cleaned up on finish', () {
    final manager = ComicSourceManager();
    const key = 'comic-source-update-test';

    manager.finishUpdate(key);
    expect(manager.tryStartUpdate(key), isTrue);
    expect(manager.tryStartUpdate(key), isFalse);

    manager.setUpdateState(key, ComicSourceUpdateState.parsing);
    manager.cancelUpdate(key);
    expect(manager.isUpdateCancelled(key), isTrue);
    expect(manager.updateStates[key], ComicSourceUpdateState.parsing);

    manager.finishUpdate(key);
    expect(manager.isUpdateCancelled(key), isFalse);
    expect(manager.updateStates.containsKey(key), isFalse);
    expect(manager.tryStartUpdate(key), isTrue);
    manager.finishUpdate(key);
  });
}
