import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/reading_statistics.dart';
import 'package:venera/utils/translations.dart';

enum _StatisticsSort { recent, duration, name }

class ReadingStatisticsPage extends StatefulWidget {
  const ReadingStatisticsPage({super.key});

  @override
  State<ReadingStatisticsPage> createState() => _ReadingStatisticsPageState();
}

class _ReadingStatisticsPageState extends State<ReadingStatisticsPage> {
  final manager = ReadingStatisticsManager();
  _StatisticsSort _sort = _StatisticsSort.recent;

  @override
  void initState() {
    super.initState();
    manager.addListener(_update);
  }

  @override
  void dispose() {
    manager.removeListener(_update);
    super.dispose();
  }

  void _update() {
    if (mounted) setState(() {});
  }

  List<int> _week(DateTime now) => [
    for (var i = 6; i >= 0; i--)
      manager.durationForDay(DateTime(now.year, now.month, now.day - i)),
  ];

  List<ReadingStatistic> _aggregateRecent() {
    final byComic = <String, ReadingStatistic>{};
    for (final item in manager.recent()) {
      final key = '${item.comicType.value}:${item.comicId}';
      final old = byComic[key];
      if (old == null) {
        byComic[key] = item;
        continue;
      }
      final latest = item.lastReadAt.isAfter(old.lastReadAt) ? item : old;
      byComic[key] = ReadingStatistic(
        day: latest.day,
        comicId: latest.comicId,
        comicType: latest.comicType,
        title: latest.title,
        author: latest.author,
        cover: latest.cover,
        durationSeconds: old.durationSeconds + item.durationSeconds,
        lastReadAt: latest.lastReadAt,
      );
    }
    final comics = byComic.values.toList();
    comics.sort(
      (a, b) => switch (_sort) {
        _StatisticsSort.duration => b.durationSeconds.compareTo(
          a.durationSeconds,
        ),
        _StatisticsSort.name => a.title.compareTo(b.title),
        _StatisticsSort.recent => b.lastReadAt.compareTo(a.lastReadAt),
      },
    );
    return comics;
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final dates = [
      for (var i = 6; i >= 0; i--) DateTime(now.year, now.month, now.day - i),
    ];
    final week = _week(now);
    final weekTotal = week.fold(0, (sum, value) => sum + value);
    final maximum = week.fold(0, (max, value) => value > max ? value : max);
    final comics = _aggregateRecent();

    return Scaffold(
      body: SmoothCustomScrollView(
        slivers: [
          SliverAppbar(title: Text('Reading statistics'.tl)),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            sliver: SliverToBoxAdapter(
              child: Row(
                children: [
                  Expanded(
                    child: _SummaryMetric(
                      icon: Icons.today_outlined,
                      label: 'Today'.tl,
                      value: formatReadingDuration(week.last),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _SummaryMetric(
                      icon: Icons.date_range_outlined,
                      label: 'Last 7 days'.tl,
                      value: formatReadingDuration(weekTotal),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _SummaryMetric(
                      icon: Icons.auto_graph_outlined,
                      label: 'Total'.tl,
                      value: formatReadingDuration(manager.totalDuration()),
                    ),
                  ),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Container(
              margin: const EdgeInsets.fromLTRB(12, 4, 12, 8),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              decoration: BoxDecoration(
                border: Border.all(
                  color: Theme.of(context).colorScheme.outlineVariant,
                  width: .6,
                ),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Last 7 days'.tl, style: ts.s16),
                  const SizedBox(height: 4),
                  Text('Reading trend'.tl, style: ts.s12),
                  const SizedBox(height: 14),
                  SizedBox(
                    height: 142,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (var i = 0; i < dates.length; i++)
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 3,
                              ),
                              child: Column(
                                children: [
                                  Expanded(
                                    child: Align(
                                      alignment: Alignment.bottomCenter,
                                      child: FractionallySizedBox(
                                        widthFactor: .72,
                                        heightFactor: maximum == 0
                                            ? .03
                                            : (week[i] / maximum).clamp(
                                                .03,
                                                1.0,
                                              ),
                                        child: DecoratedBox(
                                          decoration: BoxDecoration(
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.primary,
                                            borderRadius: BorderRadius.circular(
                                              4,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    '${dates[i].month}/${dates[i].day}',
                                    style: ts.s10,
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
            sliver: SliverToBoxAdapter(
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('Recent comics'.tl),
                subtitle: Text(
                  '${comics.length} ${'items'.tl}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: PopupMenuButton<_StatisticsSort>(
                  icon: const Icon(Icons.sort),
                  tooltip: 'Sort'.tl,
                  onSelected: (value) => setState(() => _sort = value),
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      value: _StatisticsSort.recent,
                      child: Text('Recent'.tl),
                    ),
                    PopupMenuItem(
                      value: _StatisticsSort.duration,
                      child: Text('Duration'.tl),
                    ),
                    PopupMenuItem(
                      value: _StatisticsSort.name,
                      child: Text('Name'.tl),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (comics.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: Text('No reading data'.tl)),
            )
          else
            SliverList.builder(
              itemCount: comics.length,
              itemBuilder: (context, index) {
                final item = comics[index];
                return ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                  leading: CircleAvatar(
                    backgroundColor: Theme.of(
                      context,
                    ).colorScheme.secondaryContainer,
                    child: Icon(
                      Icons.menu_book_outlined,
                      color: Theme.of(context).colorScheme.onSecondaryContainer,
                    ),
                  ),
                  title: Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    item.author.isEmpty ? item.day : item.author,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Text(
                    formatReadingDuration(item.durationSeconds),
                    style: ts.s12,
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}

class _SummaryMetric extends StatelessWidget {
  const _SummaryMetric({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Container(
    constraints: const BoxConstraints(minHeight: 92),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20),
        const SizedBox(height: 14),
        Text(
          label,
          style: ts.s12,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 3),
        Text(
          value,
          style: ts.s16,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    ),
  );
}
