enum FavoriteFolderTitleAction {
  openSidebar,
  returnToOverview;

  static FavoriteFolderTitleAction fromStorage(Object? value) {
    return FavoriteFolderTitleAction.values.firstWhere(
      (action) => action.name == value,
      orElse: () => openSidebar,
    );
  }
}
