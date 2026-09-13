import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/favorite_folder_title_action.dart';

void main() {
  test('folder title action defaults to opening the sidebar', () {
    expect(
      FavoriteFolderTitleAction.fromStorage(null),
      FavoriteFolderTitleAction.openSidebar,
    );
    expect(
      FavoriteFolderTitleAction.fromStorage('unknown'),
      FavoriteFolderTitleAction.openSidebar,
    );
  });

  test('folder title action restores the overview preference', () {
    expect(
      FavoriteFolderTitleAction.fromStorage('returnToOverview'),
      FavoriteFolderTitleAction.returnToOverview,
    );
  });
}
