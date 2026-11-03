import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/utils/translations.dart';

/// Search-specific paging keeps restoration isolated from other comic lists.
class SearchResultsList extends StatefulWidget {
  const SearchResultsList({
    super.key,
    required this.header,
    required this.onVisiblePage,
    this.loadPage,
    this.loadNext,
    this.initialPage = 1,
  });
  final Widget header;
  final Future<Res<List<Comic>>> Function(int)? loadPage;
  final Future<Res<List<Comic>>> Function(String?)? loadNext;
  final int initialPage;
  final ValueChanged<int> onVisiblePage;
  @override
  State<SearchResultsList> createState() => _SearchResultsListState();
}

class _SearchResultsListState extends State<SearchResultsList> {
  final _scroll = ScrollController();
  final _data = <int, List<Comic>>{};
  final _grids = <int, GlobalKey>{};
  late int _page = math.max(1, widget.initialPage);
  late int _firstPage = _page;
  int? _maxPage;
  String? _next;
  final _seenCursors = <String>{};
  String? _error;
  String? _notice;
  bool _loading = false;
  int _generation = 0;
  int? _reported;
  bool _reportScheduled = false;
  bool get _continuous => appdata.settings['comicListDisplayMode'] != 'paging';
  int get _lastPage => _data.isEmpty ? 0 : _data.keys.reduce(math.max);

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_scheduleReport);
    unawaited(_load(_page));
  }

  @override
  void dispose() {
    _generation++;
    _scroll.dispose();
    super.dispose();
  }

  void _scheduleReport() {
    if (_reportScheduled) return;
    _reportScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _reportScheduled = false;
      if (!mounted) return;
      int? visible;
      if (!_continuous) {
        if (_data.containsKey(_page)) visible = _page;
      } else {
        final pages = _grids.keys.toList()..sort();
        for (final page in pages) {
          final grid = _grids[page]!.currentContext?.findRenderObject();
          if (grid is RenderSliverGrid &&
              (grid.geometry?.paintExtent ?? 0) > 0) {
            visible = page;
            break;
          }
        }
      }
      if (visible != null && visible != _reported) {
        _reported = visible;
        widget.onVisiblePage(visible);
      }
    });
  }

  Future<void> _load(int requested) async {
    if (_loading || !mounted || _data.containsKey(requested)) return;
    final generation = _generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (widget.loadPage != null) {
        var target = requested;
        var result = await widget.loadPage!(target);
        if (!mounted || generation != _generation) return;
        if (result.error) throw result.errorMessage ?? 'Unknown error'.tl;
        final max = result.subData;
        if (max is int && max > 0) _maxPage = max;
        if (_maxPage != null && target > _maxPage!) {
          target = _maxPage!;
          result = await widget.loadPage!(target);
          if (!mounted || generation != _generation) return;
          if (result.error) throw result.errorMessage ?? 'Unknown error'.tl;
          _notice =
              'The saved page is no longer available. Showing the last page.'
                  .tl;
          _page = _firstPage = target;
        }
        _data[target] = result.data;
        if (result.data.isEmpty) {
          _maxPage = target;
          if (requested > 1) {
            _notice ??= 'No results on this page. Try an earlier page.'.tl;
          }
        }
      } else if (widget.loadNext != null) {
        while (_data[requested] == null &&
            (_maxPage == null || _lastPage < _maxPage!)) {
          final previous = _next;
          final result = await widget.loadNext!(previous);
          if (!mounted || generation != _generation) return;
          if (result.error) throw result.errorMessage ?? 'Unknown error'.tl;
          final next = result.subData;
          if (next != null && next is! String) {
            throw StateError('Invalid search cursor');
          }
          if (next != null && _seenCursors.contains(next)) {
            throw StateError('Search cursor did not advance');
          }
          _data[_lastPage + 1] = result.data;
          _next = next as String?;
          if (_next != null) _seenCursors.add(_next!);
          if (next == null) _maxPage = _lastPage;
          setState(() {});
        }
        if (!_data.containsKey(requested)) {
          _page = _firstPage = math.max(1, _lastPage);
          _notice =
              'The saved page is no longer available. Showing the last page.'
                  .tl;
        }
      } else {
        throw StateError('Search is unavailable');
      }
    } catch (error) {
      if (!mounted || generation != _generation) return;
      _error = error.toString();
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
        _scheduleReport();
      }
    }
  }

  void _go(int page) {
    if (_loading || page < 1 || (_maxPage != null && page > _maxPage!)) return;
    setState(() {
      _page = page;
      _error = null;
      _notice = null;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    unawaited(_load(page));
    _scheduleReport();
  }

  Future<void> _jump() async {
    final controller = TextEditingController(text: '$_page');
    final page = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Jump to page'.tl),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Cancel'.tl),
          ),
          FilledButton(
            onPressed: () {
              final page = int.tryParse(controller.text);
              if (page != null && page > 0 && page <= (_maxPage ?? 1000000)) {
                Navigator.pop(context, page);
              }
            },
            child: Text('Jump'.tl),
          ),
        ],
      ),
    );
    // The route may still be animating out with its text field mounted.
    WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose());
    if (mounted && page != null) _go(page);
  }

  Widget _selector() => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    child: Row(
      children: [
        OutlinedButton(
          onPressed: !_loading && _page > 1 ? () => _go(_page - 1) : null,
          child: Text('Back'.tl),
        ),
        Expanded(
          child: TextButton(
            onPressed: _loading ? null : _jump,
            child: Text('P$_page / ${_maxPage ?? '?'}'),
          ),
        ),
        OutlinedButton(
          onPressed: !_loading && (_maxPage == null || _page < _maxPage!)
              ? () => _go(_page + 1)
              : null,
          child: Text('Next'.tl),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    _scheduleReport();
    final ready = _data.containsKey(_continuous ? _firstPage : _page);
    final pages = _data.keys.where((p) => p >= _firstPage).toList()..sort();
    return Column(
      children: [
        widget.header,
        if (!_continuous) _selector(),
        if (_notice != null)
          Padding(padding: const EdgeInsets.all(12), child: Text(_notice!)),
        if (!ready)
          Expanded(
            child: Center(
              child: _error != null
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_error!),
                        TextButton(
                          onPressed: () =>
                              _load(_continuous ? _firstPage : _page),
                          child: Text('Retry'.tl),
                        ),
                        if (_page > 1)
                          TextButton(
                            onPressed: () {
                              _firstPage = 1;
                              _go(1);
                            },
                            child: Text('Start from first page'.tl),
                          ),
                      ],
                    )
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircularProgressIndicator(),
                        const SizedBox(height: 16),
                        if (widget.loadPage == null && _page > 1)
                          Text(
                            'Restoring page @page (@loaded loaded)'.tlParams({
                              'page': _page,
                              'loaded': _lastPage,
                            }),
                          ),
                        TextButton(
                          onPressed: () {
                            _generation++;
                            setState(() {
                              _loading = false;
                              _error = 'Restoration cancelled'.tl;
                            });
                            Navigator.of(context).maybePop();
                          },
                          child: Text('Cancel'.tl),
                        ),
                      ],
                    ),
            ),
          )
        else
          Expanded(
            child: NotificationListener<ScrollNotification>(
              onNotification: (_) {
                _scheduleReport();
                return false;
              },
              child: SmoothCustomScrollView(
                controller: _scroll,
                slivers: [
                  if (_continuous && _firstPage > 1)
                    SliverToBoxAdapter(
                      child: TextButton(
                        onPressed: _loading
                            ? null
                            : () {
                                setState(() {
                                  _firstPage--;
                                  _page = _firstPage;
                                });
                                if (_scroll.hasClients) _scroll.jumpTo(0);
                                unawaited(_load(_firstPage));
                              },
                        child: Text('Load previous page'.tl),
                      ),
                    ),
                  for (final page in _continuous ? pages : [_page]) ...[
                    if (_continuous)
                      SliverToBoxAdapter(child: _SearchPageDivider(page: page)),
                    SliverGridComics(
                      key: _grids.putIfAbsent(page, GlobalKey.new),
                      comics: _data[page]!,
                      onLastItemBuild: !_continuous || page != _lastPage
                          ? null
                          : () {
                              if (!_loading &&
                                  _error == null &&
                                  (_maxPage == null || page < _maxPage!)) {
                                WidgetsBinding.instance.addPostFrameCallback((
                                  _,
                                ) {
                                  if (mounted) unawaited(_load(page + 1));
                                });
                              }
                            },
                    ),
                  ],
                  if (!_continuous && (_data[_page]?.length ?? 0) > 6)
                    SliverToBoxAdapter(child: _selector()),
                  if (_error != null)
                    SliverToBoxAdapter(
                      child: Column(
                        children: [
                          Text(_error!),
                          TextButton(
                            onPressed: () =>
                                _load(_continuous ? _lastPage + 1 : _page),
                            child: Text('Retry'.tl),
                          ),
                        ],
                      ),
                    ),
                  if (_loading)
                    const SliverToBoxAdapter(
                      child: Center(child: CircularProgressIndicator()),
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// A quiet boundary between source pages in continuous search results.
class _SearchPageDivider extends StatelessWidget {
  const _SearchPageDivider({required this.page});

  final int page;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    Widget line() => Expanded(
      child: SizedBox(
        height: 1,
        child: CustomPaint(painter: _DashedLinePainter(colors.outlineVariant)),
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      child: Row(
        children: [
          line(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Text(
              'P$page',
              style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant),
            ),
          ),
          line(),
        ],
      ),
    );
  }
}

class _DashedLinePainter extends CustomPainter {
  const _DashedLinePainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    for (double x = 0; x < size.width; x += 7) {
      canvas.drawLine(
        Offset(x, size.height / 2),
        Offset(math.min(x + 4, size.width), size.height / 2),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_DashedLinePainter oldDelegate) =>
      color != oldDelegate.color;
}
