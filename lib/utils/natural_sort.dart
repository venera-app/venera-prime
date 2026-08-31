/// Compares names the way people usually expect numbered files to sort.
///
/// The comparison is case-insensitive and treats each run of digits as a
/// number, so `page2` comes before `page10`.
int naturalCompare(String left, String right) {
  final leftParts = RegExp(r'(\d+|\D+)').allMatches(left);
  final rightParts = RegExp(r'(\d+|\D+)').allMatches(right);
  final leftList = leftParts.map((m) => m.group(0)!).toList();
  final rightList = rightParts.map((m) => m.group(0)!).toList();
  final length = leftList.length < rightList.length
      ? leftList.length
      : rightList.length;
  for (var i = 0; i < length; i++) {
    final a = leftList[i];
    final b = rightList[i];
    final aNumber = int.tryParse(a);
    final bNumber = int.tryParse(b);
    final result = aNumber != null && bNumber != null
        ? aNumber.compareTo(bNumber)
        : a.toLowerCase().compareTo(b.toLowerCase());
    if (result != 0) return result;
  }
  return left.length.compareTo(right.length);
}
