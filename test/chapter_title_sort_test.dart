import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/chapter_title_sort.dart';

void main() {
  test('compares chapter numbers across bare, Chinese and English titles', () {
    final titles = ['第10话', '2', 'Chapter 11', '第1话', '3', '第20話'];
    titles.sort(compareChapterTitles);
    expect(titles, ['第1话', '2', '3', '第10话', 'Chapter 11', '第20話']);
  });

  test(
    'spaces, padding, full-width and Chinese numerals do not change order',
    () {
      final titles = ['第１００话', '第十话', '第 １ 話', '第02话', '第十一话', '三'];
      titles.sort(compareChapterTitles);
      expect(titles, ['第 １ 話', '第02话', '三', '第十话', '第十一话', '第１００话']);
      expect(compareChapterTitles('第001话', '1'), 0);
      expect(compareChapterTitles('Chapter 1', '第一话'), 0);
      expect(compareChapterTitles('第一百零二话', '102'), 0);
      expect(compareChapterTitles('第二千零一十话', '2010'), 0);
      expect(compareChapterTitles('第二〇二话', '202'), 0);
    },
  );

  test('subtitles and ranges do not replace the primary chapter number', () {
    final titles = ['第10话：回到1年前', '第1话 开始', '第2话：100年前', '第1-3话 合集'];
    expect(compareChapterTitles(titles[0], titles[1]), greaterThan(0));
    expect(compareChapterTitles(titles[2], titles[0]), lessThan(0));
    expect(compareChapterTitles(titles[3], titles[1]), 0);
    expect(compareChapterTitles('作品2024版 第2话', '第10话'), lessThan(0));
  });

  test('volume and chapter numbers form a hierarchical key', () {
    final titles = ['第2卷 第1话', '第1卷 第10话', '第1卷 第2话', '第10卷 第1话'];
    titles.sort(compareChapterTitles);
    expect(titles, ['第1卷 第2话', '第1卷 第10话', '第2卷 第1话', '第10卷 第1话']);
    expect(compareChapterTitles('Vol. 2 Chapter 1', '第2卷 第1话'), 0);
  });

  test(
    'fractional chapters and large chapter numbers compare without rounding',
    () {
      final titles = ['第2话', '1.5', '第1话', 'Chapter 1.05'];
      titles.sort(compareChapterTitles);
      expect(titles, ['第1话', 'Chapter 1.05', '1.5', '第2话']);
      expect(compareChapterTitles('第1.50话', '1.5'), 0);
      expect(
        compareChapterTitles(
          '999999999999999999999',
          '第1000000000000000000000话',
        ),
        lessThan(0),
      );
    },
  );

  test('extra and unnumbered titles retain natural title comparison', () {
    final titles = ['番外第10话', '第10话', '番外第2话', '2', '序章'];
    titles.sort(compareChapterTitles);
    expect(titles.take(2), ['2', '第10话']);
    expect(titles.indexOf('番外第2话'), lessThan(titles.indexOf('番外第10话')));
    expect(compareChapterTitles('', ''), 0);
  });

  test('mixed title comparison remains transitive', () {
    const titles = [
      '第10话',
      '1',
      'Chapter 2',
      '第０１話',
      '第一话',
      '第1.5话',
      '第2卷 第1话',
      '番外1',
      '序章',
      '后记',
      '',
    ];
    for (final a in titles) {
      for (final b in titles) {
        expect(
          compareChapterTitles(a, b).sign,
          -compareChapterTitles(b, a).sign,
        );
        for (final c in titles) {
          if (compareChapterTitles(a, b) <= 0 &&
              compareChapterTitles(b, c) <= 0) {
            expect(compareChapterTitles(a, c), lessThanOrEqualTo(0));
          }
        }
      }
    }
  });
}
