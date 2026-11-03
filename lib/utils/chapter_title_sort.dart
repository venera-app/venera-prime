import 'natural_sort.dart';

/// Chapter numbering is independent of its spelling: `2`, `第2话` and
/// `Chapter 2` belong to the same numeric sequence. This comparator is only
/// for chapter titles; image filenames continue to use [naturalCompare].
int compareChapterTitles(String left, String right) =>
    ChapterTitleSortKey(left).compareTo(ChapterTitleSortKey(right));

class ChapterTitleSortKey implements Comparable<ChapterTitleSortKey> {
  ChapterTitleSortKey(String title) : text = _normalize(title) {
    final markers = <({int start, bool volume, _ChapterNumber number})>[];
    for (final match in _chineseMarker.allMatches(text)) {
      markers.add((
        start: match.start,
        volume: _volumeUnits.contains(match.group(2)),
        number: _ChapterNumber.parse(match.group(1)!),
      ));
    }
    for (final match in _englishMarker.allMatches(text)) {
      markers.add((
        start: match.start,
        volume: match.group(1)!.startsWith('vol'),
        number: _ChapterNumber.parse(match.group(2)!),
      ));
    }
    markers.sort((a, b) => a.start.compareTo(b.start));
    // Extra chapters keep their own title ordering after numbered chapters.
    if (_extra.hasMatch(text)) return;
    if (markers.isNotEmpty) {
      final first = markers.first;
      numbers.add(first.number);
      if (first.volume) {
        for (final marker in markers.skip(1)) {
          if (!marker.volume) {
            numbers.add(marker.number);
            break;
          }
        }
      }
    } else {
      final leading = _leadingNumber.firstMatch(text);
      if (leading != null) {
        numbers.add(_ChapterNumber.parse(leading.group(1)!));
      }
    }
  }

  final String text;
  final numbers = <_ChapterNumber>[];

  @override
  int compareTo(ChapterTitleSortKey other) {
    if (numbers.isEmpty || other.numbers.isEmpty) {
      if (numbers.isEmpty != other.numbers.isEmpty) {
        return numbers.isEmpty ? 1 : -1;
      }
      return naturalCompare(text, other.text);
    }
    for (var i = 0; i < numbers.length && i < other.numbers.length; i++) {
      final result = numbers[i].compareTo(other.numbers[i]);
      if (result != 0) return result;
    }
    // Equivalent chapter numbers retain source order in ChapterOrder.apply.
    return numbers.length.compareTo(other.numbers.length);
  }
}

const _chineseDigits = '零〇一二三四五六七八九两兩十百千万萬';
const _number = r'(?:[0-9]+(?:\.[0-9]+)?|[' + _chineseDigits + r']+)';
const _volumeUnits = {'卷', '巻', '部'};
final _chineseMarker = RegExp(
  '第?\\s*($_number)(?:\\s*[-~～〜至]\\s*$_number)?\\s*([卷巻部话話章回集篇])',
);
final _englishMarker = RegExp(
  r'\b(volume|vol\.?|chapter|chap\.?|ch\.?|episode|ep\.?)\s*#?\s*(' +
      _number +
      r')',
);
final _leadingNumber = RegExp('^($_number)(?=\\s|[.、:：_\\-—(（]|\$)');
final _extra = RegExp(r'^(?:番外|外传|外傳|特别篇|特別篇|特典|extra\b|special\b|omake\b)');

String _normalize(String title) => title
    .replaceAllMapped(
      RegExp(r'[０-９]'),
      (m) => String.fromCharCode(m.group(0)!.codeUnitAt(0) - 0xff10 + 0x30),
    )
    .replaceAll('．', '.')
    .trim()
    .toLowerCase();

class _ChapterNumber implements Comparable<_ChapterNumber> {
  const _ChapterNumber(this.whole, [this.fraction = '']);
  final BigInt whole;
  final String fraction;

  factory _ChapterNumber.parse(String value) {
    final parts = value.split('.');
    final arabic = BigInt.tryParse(parts.first);
    if (arabic != null) {
      return _ChapterNumber(arabic, parts.length == 1 ? '' : parts[1]);
    }
    const digits = {
      '零': 0,
      '〇': 0,
      '一': 1,
      '二': 2,
      '两': 2,
      '兩': 2,
      '三': 3,
      '四': 4,
      '五': 5,
      '六': 6,
      '七': 7,
      '八': 8,
      '九': 9,
    };
    const units = {'十': 10, '百': 100, '千': 1000, '万': 10000, '萬': 10000};
    if (!value.split('').any(units.containsKey)) {
      return _ChapterNumber(
        BigInt.parse(value.split('').map((c) => digits[c]!).join()),
      );
    }
    var total = 0;
    var section = 0;
    var digit = 0;
    for (final char in value.split('')) {
      final unit = units[char];
      if (unit == null) {
        digit = digits[char]!;
      } else if (unit == 10000) {
        total += (section + digit) * unit;
        section = 0;
        digit = 0;
      } else {
        section += (digit == 0 ? 1 : digit) * unit;
        digit = 0;
      }
    }
    return _ChapterNumber(BigInt.from(total + section + digit));
  }

  @override
  int compareTo(_ChapterNumber other) {
    final result = whole.compareTo(other.whole);
    if (result != 0) return result;
    final length = fraction.length > other.fraction.length
        ? fraction.length
        : other.fraction.length;
    return fraction
        .padRight(length, '0')
        .compareTo(other.fraction.padRight(length, '0'));
  }
}
