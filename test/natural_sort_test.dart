import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/natural_sort.dart';

void main() {
  test('sorts numbered pages naturally and ignores case', () {
    final names = ['10.JPG', '2.jpg', '1.jpg', 'notes.txt'];
    names.sort(naturalCompare);
    expect(names, ['1.jpg', '2.jpg', '10.JPG', 'notes.txt']);
  });

  test('sorts chapter names by numeric parts', () {
    final names = ['Chapter 10', 'Chapter 2', 'Chapter 1'];
    names.sort(naturalCompare);
    expect(names, ['Chapter 1', 'Chapter 2', 'Chapter 10']);
  });
}
