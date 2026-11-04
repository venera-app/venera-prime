part of 'reader.dart';

class _WaterfallMode extends _ContinuousMode {
  const _WaterfallMode();

  @override
  State<_ContinuousMode> createState() => _WaterfallModeState();
}

class _WaterfallChapter {
  const _WaterfallChapter(this.number, this.images);
  final int number;
  final List<String> images;
}

/// Retains chapter metadata while image widgets remain lazily built by the list.
class _WaterfallModeState extends _ContinuousModeState {
  final chapters = <_WaterfallChapter>[];
  final loading = <bool>{};
  final errors = <bool, String>{};
  bool restoring = false;
  bool positionScheduled = false;

  @override
  void initState() {
    super.initState();
    chapters.add(_WaterfallChapter(reader.chapter, List.of(reader.images!)));
  }

  @override
  int get itemCount =>
      2 + chapters.fold<int>(0, (n, c) => n + c.images.length + 1);

  (_WaterfallChapter, int)? row(int index) {
    var offset = index - 1;
    for (final chapter in chapters) {
      if (offset < 0) return null;
      if (offset <= chapter.images.length) return (chapter, offset);
      offset -= chapter.images.length + 1;
    }
    return null;
  }

  @override
  int listIndex(int page) {
    var index = 1;
    for (final chapter in chapters) {
      if (chapter.number == reader.chapter) return index + page;
      index += chapter.images.length + 1;
    }
    return 1;
  }

  int? adjacent(bool forward) {
    final number = forward ? chapters.last.number : chapters.first.number;
    final navigation =
        reader.chapterReadingOrder == ChapterReadingOrder.automatic
        ? ChapterNavigation.fromCache(reader.widget.chapters, number)
        : null;
    final target = navigation != null
        ? (forward ? navigation.next : navigation.previous)
        : reader.chapterSequence.adjacent(
            reader.widget.chapters,
            number,
            forward: forward,
          );
    return chapters.any((c) => c.number == target) ? null : target;
  }

  Future<void> loadAdjacent(bool forward) async {
    final number = adjacent(forward);
    if (number == null || loading.isNotEmpty || errors.containsKey(forward)) {
      return;
    }
    setState(() => loading.add(forward));
    try {
      final List<String> images;
      if (reader.type == ComicType.local ||
          LocalManager().isDownloaded(
            reader.cid,
            reader.type,
            number,
            reader.widget.chapters,
          )) {
        images = await LocalManager().getImages(
          reader.cid,
          reader.type,
          number,
        );
      } else {
        final result = await reader.type.comicSource!.loadComicPages!(
          reader.cid,
          reader.widget.chapters?.ids.elementAtOrNull(number - 1),
        );
        if (result.error) throw result.errorMessage ?? 'Error';
        images = result.data;
      }
      if (!mounted) return;
      if (images.isEmpty) throw 'No pages in this chapter'.tl;
      final visible =
          itemPositionsListener.itemPositions.value
              .where((p) => p.itemTrailingEdge > 0 && p.itemLeadingEdge < 1)
              .toList()
            ..sort((a, b) => a.index.compareTo(b.index));
      final anchor = visible
          .where((p) => p.index > 0 && p.index < itemCount - 1)
          .firstOrNull;
      restoring = true;
      setState(() {
        final chapter = _WaterfallChapter(number, images);
        if (forward) {
          chapters.add(chapter);
        } else {
          chapters.insert(0, chapter);
        }
        loading.remove(forward);
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (!forward && anchor != null && itemScrollController.isAttached) {
          itemScrollController.jumpTo(
            index: anchor.index + images.length + 1,
            alignment: anchor.itemLeadingEdge,
          );
        }
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          restoring = false;
          onPositionChanged();
        });
        WidgetsBinding.instance.ensureVisualUpdate();
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        loading.remove(forward);
        errors[forward] = error.toString();
      });
    }
  }

  @override
  Widget? boundaryItem(int index) {
    if (index == 0 || index == itemCount - 1) {
      final forward = index != 0;
      if (adjacent(forward) == null) return const SizedBox(height: 16);
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Center(
          child: errors.containsKey(forward)
              ? TextButton(
                  onPressed: () {
                    errors.remove(forward);
                    loadAdjacent(forward);
                  },
                  child: Text('${errors[forward]}\n${'Retry'.tl}'),
                )
              : const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(),
                ),
        ),
      );
    }
    final entry = row(index)!;
    if (entry.$2 != 0) return null;
    final title =
        reader.widget.chapters?.titles
            .elementAtOrNull(entry.$1.number - 1)
            ?.displayText ??
        '${'Chapter'.tl} ${entry.$1.number}';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
      child: Row(
        children: [
          const Expanded(child: Divider()),
          const SizedBox(width: 12),
          Flexible(flex: 3, child: Text(title, textAlign: TextAlign.center)),
          const SizedBox(width: 12),
          const Expanded(child: Divider()),
        ],
      ),
    );
  }

  @override
  ImageProvider imageAt(int index) {
    final (chapter, page) = row(index)!;
    return ReaderImageProvider(
      chapter.images[page - 1],
      reader.type.comicSource?.key,
      reader.cid,
      reader.widget.chapters?.ids.elementAtOrNull(chapter.number - 1) ?? '0',
      page,
      enableResize: true,
    );
  }

  @override
  void onPositionChanged() {
    if (!mounted || restoring || positionScheduled) return;
    positionScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      positionScheduled = false;
      if (!mounted || restoring) return;
      final visible =
          itemPositionsListener.itemPositions.value
              .where(
                (p) => p.itemTrailingEdge > .000001 && p.itemLeadingEdge < 1,
              )
              .toList()
            ..sort((a, b) => a.index.compareTo(b.index));
      if (visible.isEmpty) return;
      // Ignore a small tail above the chapter divider when choosing progress.
      final images = visible
          .where((p) => p.itemTrailingEdge > .2)
          .map((p) => row(p.index))
          .whereType<(_WaterfallChapter, int)>()
          .where((r) => r.$2 > 0);
      if (images.isNotEmpty) {
        final (chapter, page) = images.first;
        if (reader.chapter != chapter.number || reader.page != page) {
          if (reader.chapter != chapter.number) {
            reader.chapter = chapter.number;
            reader.images = chapter.images;
            reader.prepareSpreadLayout();
            reader.resolveChapterNavigation();
          }
          reader.setPage(page);
          context.readerScaffold.update();
        }
      }
      if (!_openingAtChapterEnd &&
          _visibleImagesReady &&
          visible.first.index <= 2) {
        loadAdjacent(false);
      }
      if (!_openingAtChapterEnd &&
          _visibleImagesReady &&
          visible.last.index >= itemCount - 3) {
        loadAdjacent(true);
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void _alignChapterEnd() {
    super._alignChapterEnd();
    onPositionChanged();
  }

  // The entire loaded stream is scrollable; crossing chapters never replaces it.
  @override
  bool get isAtChapterStart => false;
  @override
  bool get isAtChapterEnd => false;
  @override
  void cacheImages(int current) {}

  @override
  Future<Uint8List?> getImageByOffset(Offset offset) async {
    for (final state in imageStates) {
      if (state is _ComicImageState && state.containsPoint(offset)) {
        final image = state.widget.image as ReaderImageProvider;
        if (image.imageKey.startsWith('file://')) {
          return File(image.imageKey.substring(7)).readAsBytes();
        }
        return CacheManager().readCache(
          '${image.imageKey}@${image.sourceKey}@${image.cid}@${image.eid}',
        );
      }
    }
    return null;
  }
}
