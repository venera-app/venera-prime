enum ReaderOrientationBehavior {
  keepAfterExit('keepAfterExit'),
  sessionOnly('sessionOnly'),
  rememberGlobally('rememberGlobally'),
  rememberPerComic('rememberPerComic');

  const ReaderOrientationBehavior(this.storageValue);

  static const settingKey = 'readerOrientationBehavior';

  final String storageValue;

  bool get restoresOnExit => this != keepAfterExit;

  bool get remembersOrientation =>
      this == rememberGlobally || this == rememberPerComic;

  bool get remembersPerComic => this == rememberPerComic;

  static ReaderOrientationBehavior fromStorage(Object? value) {
    return ReaderOrientationBehavior.values.firstWhere(
      (behavior) => behavior.storageValue == value,
      orElse: () => keepAfterExit,
    );
  }

  static ReaderOrientationBehavior fromLegacySettings({
    required bool rememberOrientation,
    required bool rememberPerComic,
  }) {
    if (!rememberOrientation) return keepAfterExit;
    return rememberPerComic
        ? ReaderOrientationBehavior.rememberPerComic
        : ReaderOrientationBehavior.rememberGlobally;
  }
}
