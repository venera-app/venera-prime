/// Maps 1-based image numbers to screens. Ranges use 0-based, exclusive ends.
class ReaderPageLayout {
  ReaderPageLayout({
    required this.imageCount,
    required this.imagesPerPage,
    required this.singleCover,
    this.offset = 0,
    this.standaloneImages = const {},
    this.joinedPairs = const {},
    this.anchor,
  });

  final int imageCount;
  final int imagesPerPage;
  final bool singleCover;
  final int offset;

  /// Wide images occupy a complete spread. Explicit pairs take precedence.
  final Set<int> standaloneImages;
  final Set<int> joinedPairs;

  /// A manually shifted image must start a screen even after a wide image.
  final int? anchor;

  bool get _hasSpreads =>
      imagesPerPage == 2 &&
      (standaloneImages.isNotEmpty || joinedPairs.isNotEmpty || anchor != null);

  late final List<(int, int)> _spreads = _buildSpreads();

  List<(int, int)> _buildSpreads() {
    final result = <(int, int)>[];
    for (var start = 0; start < imageCount;) {
      var count = 1;
      if (start + 1 < imageCount) {
        final explicitPair = joinedPairs.contains(start);
        final nextStartsGroup =
            standaloneImages.contains(start + 1) ||
            joinedPairs.contains(start + 1) ||
            anchor == start + 1;
        if (explicitPair ||
            (!standaloneImages.contains(start) &&
                !(start == 0 && firstPageCount == 1) &&
                !nextStartsGroup)) {
          count = 2;
        }
      }
      result.add((start, start + count));
      start += count;
    }
    return result;
  }

  int get firstPageCount => imagesPerPage == 1
      ? 1
      : ((singleCover ? 0 : imagesPerPage - 1) + offset) % imagesPerPage + 1;

  int get pageCount => _hasSpreads
      ? (_spreads.isEmpty ? 1 : _spreads.length)
      : 1 +
            ((imageCount - firstPageCount).clamp(0, imageCount) / imagesPerPage)
                .ceil();

  (int, int) range(int page) {
    if (_hasSpreads) {
      if (_spreads.isEmpty) return (0, 0);
      return _spreads[(page - 1).clamp(0, _spreads.length - 1)];
    }
    final start = page <= 1 ? 0 : firstPageCount + (page - 2) * imagesPerPage;
    return (
      start,
      (page <= 1 ? firstPageCount : start + imagesPerPage).clamp(0, imageCount),
    );
  }

  int pageForImage(int image) {
    if (!_hasSpreads) {
      return image <= firstPageCount
          ? 1
          : 2 + (image - firstPageCount - 1) ~/ imagesPerPage;
    }
    // Binary search keeps slider/history lookups cheap in long chapters.
    var low = 0;
    var high = _spreads.length;
    while (low < high) {
      final middle = (low + high) ~/ 2;
      if (_spreads[middle].$2 < image) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    return _spreads.isEmpty ? 1 : (low + 1).clamp(1, _spreads.length);
  }

  int offsetForStart(int start) => start == 0
      ? 0
      : (start - (singleCover ? 1 : imagesPerPage)) % imagesPerPage;
}
