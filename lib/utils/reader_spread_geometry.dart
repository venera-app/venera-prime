import 'dart:math' as math;
import 'dart:ui';

/// Wide artwork benefits from the full viewport regardless of its semantics.
bool isWideReaderImage(Size size) =>
    size.width.isFinite &&
    size.height.isFinite &&
    size.height > 0 &&
    size.width / size.height >= 1.2;

/// A spread has one page height. Images retain their own aspect ratios.
/// Null slots reserve a matching paper-sized blank for the cover or last page.
List<Rect> readerSpreadRects(Size viewport, List<Size?> pages) {
  if (pages.isEmpty ||
      viewport.isEmpty ||
      !viewport.width.isFinite ||
      !viewport.height.isFinite) {
    return [];
  }
  final known = pages
      .whereType<Size>()
      .where(
        (size) =>
            size.width > 0 &&
            size.height > 0 &&
            size.width.isFinite &&
            size.height.isFinite,
      )
      .toList();
  final fallback = known.isEmpty ? const Size(2, 3) : known.first;
  final ratios = pages.map((size) {
    final valid =
        size != null &&
        size.width > 0 &&
        size.height > 0 &&
        size.width.isFinite &&
        size.height.isFinite;
    return valid ? size.width / size.height : fallback.width / fallback.height;
  }).toList();
  final totalRatio = ratios.fold<double>(0, (sum, ratio) => sum + ratio);
  final height = math.min(viewport.height, viewport.width / totalRatio);
  final top = (viewport.height - height) / 2;
  var left = (viewport.width - totalRatio * height) / 2;
  final result = <Rect>[];
  for (final ratio in ratios) {
    final rect = Rect.fromLTWH(left, top, height * ratio, height);
    left = rect.right;
    result.add(rect);
  }
  return result;
}
