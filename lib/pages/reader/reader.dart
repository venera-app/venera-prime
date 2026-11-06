library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_memory_info/flutter_memory_info.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:venera/components/components.dart';
import 'package:venera/components/custom_slider.dart';
import 'package:venera/components/rich_comment_content.dart';
import 'package:venera/components/window_frame.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/consts.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/global_state.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/image_provider/cached_image.dart';
import 'package:venera/foundation/image_provider/reader_image.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/read_later.dart';
import 'package:venera/foundation/reading_statistics.dart';
import 'package:venera/foundation/reader_orientation.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/network/images.dart';
import 'package:venera/pages/settings/settings_page.dart';
import 'package:venera/utils/clipboard_image.dart';
import 'package:venera/utils/data_sync.dart';
import 'package:venera/utils/ext.dart';
import 'package:venera/utils/file_type.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/opencc.dart';
import 'package:venera/utils/tags_translation.dart';
import 'package:venera/utils/translations.dart';
import 'package:venera/utils/chapter_visibility.dart';
import 'package:venera/utils/chapter_order.dart';
import 'package:venera/utils/chapter_navigation.dart';
import 'package:venera/components/chapter_order_button.dart';
import 'package:venera/utils/reader_appearance.dart';
import 'package:venera/utils/reader_page_layout.dart';
import 'package:venera/utils/reader_spread_geometry.dart';
import 'package:venera/utils/volume.dart';
import 'package:window_manager/window_manager.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

part 'scaffold.dart';

part 'images.dart';

part 'waterfall.dart';

part 'gesture.dart';

part 'comic_image.dart';

part 'loading.dart';

part 'chapters.dart';

part 'chapter_comments.dart';

extension _ReaderContext on BuildContext {
  _ReaderState get reader => findAncestorStateOfType<_ReaderState>()!;

  _ReaderScaffoldState get readerScaffold =>
      findAncestorStateOfType<_ReaderScaffoldState>()!;
}

class Reader extends StatefulWidget {
  const Reader({
    super.key,
    required this.type,
    required this.cid,
    required this.name,
    required this.chapters,
    required this.history,
    this.initialPage,
    this.initialChapter,
    this.initialChapterGroup,
    required this.author,
    required this.tags,
  });

  final ComicType type;

  final String author;

  final List<String> tags;

  final String cid;

  final String name;

  final ComicChapters? chapters;

  /// Starts from 1, invalid values equal to 1
  final int? initialPage;

  /// Starts from 1, invalid values equal to 1
  final int? initialChapter;

  /// Starts from 1, invalid values equal to 1
  final int? initialChapterGroup;

  final History history;

  @override
  State<Reader> createState() => _ReaderState();
}

class _ReaderState extends State<Reader>
    with
        _ReaderLocation,
        _ReaderWindow,
        _VolumeListener,
        _ImagePerPageHandler,
        WidgetsBindingObserver {
  @override
  void update() {
    if (mounted) setState(() {});
  }

  bool get waterfallEnabled =>
      mode == ReaderMode.continuousTopToBottom &&
      appdata.settings.getReaderSetting(
            cid,
            type.sourceKey,
            'readerWaterfall',
          ) ==
          true;

  /// Map input to reading order before resolving page and chapter boundaries.
  @override
  bool turnPage({required bool forward}) {
    if (isLoading) return false;
    final controller = _imageViewController;
    if (controller is _WaterfallModeState) {
      return controller.scrollWithinPage(forward: forward);
    }
    if (controller is _ContinuousModeState) {
      // Several short images can remain visible at the end. The first visible
      // image number alone does not identify the actual chapter boundary.
      if (forward && controller.isAtChapterEnd) {
        return !isLastChapterOfGroup && toNextChapter();
      }
      if (!forward && controller.isAtChapterStart) {
        return !isFirstChapterOfGroup && toPrevChapter(toLastPage: true);
      }
      // Step through long images by viewport, regardless of their page number.
      return controller.scrollWithinPage(forward: forward);
    }
    if (forward) {
      return toNextPage() || (!isLastChapterOfGroup && toNextChapter());
    }
    return toPrevPage() ||
        (!isFirstChapterOfGroup && toPrevChapter(toLastPage: true));
  }

  /// The maximum page number for images only (excluding chapter comments page).
  /// This is used for display purposes and history recording.
  @override
  int get maxPage {
    return imageLayout.pageCount;
  }

  bool get canShiftImages =>
      !isLoading &&
      !isPageAnimating &&
      !isOnChapterCommentsPage &&
      imagesPerPage > 1 &&
      images?.isNotEmpty == true;

  Future<void> reloadVisibleImages() async {
    final states = switch (_imageViewController) {
      _GalleryModeState controller => controller.imageStates,
      _ContinuousModeState controller => controller.imageStates,
      _ => <State<ComicImage>>{},
    };
    final box = context.findRenderObject() as RenderBox;
    final viewport = box.localToGlobal(Offset.zero) & box.size;
    for (final state in states.toList()) {
      if (!state.mounted) continue;
      final imageBox = state.context.findRenderObject() as RenderBox;
      if (!viewport.overlaps(
        imageBox.localToGlobal(Offset.zero) & imageBox.size,
      )) {
        continue;
      }
      try {
        await (state as _ComicImageState).reload();
      } catch (error, stack) {
        Log.error('Reload Image', error, stack);
        if (mounted) context.showMessage(message: error.toString());
      }
    }
  }

  void shiftImage(int delta) {
    if (!canShiftImages) return;
    final start = imageLayout.range(page).$1;
    final target = (start + delta).clamp(0, images!.length - 1);
    if (target == start) return;
    final previousOffset = imageGroupingOffset;
    if (start == 0 && delta > 0 && imageLayout.firstPageCount < imagesPerPage) {
      imageGroupingOffset++;
      page = 1;
      update();
      return;
    }
    imageGroupingOffset = imageLayout.offsetForStart(target);
    if (target == 0 && imageLayout.singleCover) {
      imageGroupingOffset = previousOffset + 1;
    }
    if (twoPageSpread) imageGroupingAnchor = target;
    if (previousOffset == imageGroupingOffset && !twoPageSpread) {
      toPage(imageLayout.pageForImage(target + 1), animate: false);
      return;
    }
    page = imageLayout.pageForImage(target + 1);
    update();
  }

  /// Total pages including chapter comments page (used for internal page control).
  @override
  int get totalPages {
    var pages = maxPage;
    if (_shouldShowChapterCommentsAtEnd) pages++;
    return pages;
  }

  /// Whether the current page is the chapter comments page.
  @override
  bool get isOnChapterCommentsPage {
    return _shouldShowChapterCommentsAtEnd && _page > maxPage;
  }

  bool get _shouldShowChapterCommentsAtEnd {
    if (mode != ReaderMode.galleryLeftToRight &&
        mode != ReaderMode.galleryRightToLeft) {
      return false;
    }
    if (widget.chapters == null) return false;
    var source = ComicSource.find(type.sourceKey);
    if (source?.chapterCommentsLoader == null) return false;
    return appdata.settings.getReaderSetting(
              cid,
              type.sourceKey,
              'showChapterComments',
            ) ==
            true &&
        appdata.settings.getReaderSetting(
              cid,
              type.sourceKey,
              'showChapterCommentsAtEnd',
            ) ==
            true;
  }

  @override
  ComicType get type => widget.type;

  @override
  String get cid => widget.cid;

  String get eid => widget.chapters?.ids.elementAtOrNull(chapter - 1) ?? '0';

  @override
  List<String>? images;

  final spreadImageSizes = <int, Size>{};
  final _spreadOverrides = <int, String>{};

  @override
  int spreadLayoutRevision = 0;

  int? _initialSpreadImage;

  String get _spreadSettingsKey => jsonEncode([type.sourceKey, cid, eid]);

  @override
  Set<int> get standaloneSpreadImages {
    final result = <int>{
      for (final entry in spreadImageSizes.entries)
        if (isWideReaderImage(entry.value)) entry.key,
    };
    for (final entry in _spreadOverrides.entries) {
      if (entry.value == 'spread') result.add(entry.key);
      if (entry.value == 'page') result.remove(entry.key);
    }
    return result;
  }

  @override
  Set<int> get joinedSpreadPairs => {
    for (final entry in _spreadOverrides.entries)
      if (entry.value == 'pair') entry.key,
  };

  /// Called once for a freshly loaded chapter, before constructing its gallery.
  void prepareSpreadLayout() {
    spreadImageSizes.clear();
    _spreadOverrides.clear();
    final saved = appdata.settings['readerSpreadOverrides'];
    final chapterSettings = saved is Map ? saved[_spreadSettingsKey] : null;
    if (chapterSettings is Map) {
      for (final entry in chapterSettings.entries) {
        final index = int.tryParse(entry.key.toString());
        final kind = entry.value;
        if (index != null &&
            index >= 0 &&
            index < images!.length &&
            (kind == 'pair' || kind == 'spread' || kind == 'page')) {
          _spreadOverrides[index] = kind as String;
        }
      }
    }
    spreadLayoutRevision++;
    _page = imageLayout.pageForImage(_initialSpreadImage ?? 1);
    _initialSpreadImage = null;
  }

  /// Decoding supplies dimensions without downloading the image a second time.
  /// Preserve the source image, including when the comments screen is open.
  bool applySpreadImageSizes(Map<int, Size> sizes) {
    final oldStandalone = standaloneSpreadImages;
    final wasComments = isOnChapterCommentsPage;
    final image = imageLayout.range(page).$1 + 1;
    spreadImageSizes.addAll(sizes);
    if (setEquals(oldStandalone, standaloneSpreadImages)) return false;
    spreadLayoutRevision++;
    _page = wasComments ? maxPage + 1 : imageLayout.pageForImage(image);
    // Invalidate an animation whose screen numbers belonged to the old layout.
    _navigationId++;
    _animationCount = 0;
    _pendingPage = null;
    update();
    return true;
  }

  /// Overrides are per comic/chapter, independent of reader setting scopes.
  void setSpreadOverride(String? kind, {int? imageIndex}) {
    if (!twoPageSpread || !canShiftImages) return;
    final (start, end) = imageLayout.range(page);
    if (kind == 'pair' && end - start != 2) return;
    final target = imageIndex ?? start;
    if (target < start || target >= end) return;
    if (kind != null && kind != 'pair' && kind != 'page' && kind != 'spread') {
      return;
    }
    if (kind == null) {
      // A forced single-page override may now be the second image of a pair.
      for (var index = start; index < end; index++) {
        _spreadOverrides.remove(index);
      }
    } else {
      _spreadOverrides.remove(target);
      if (_spreadOverrides[target - 1] == 'pair') {
        _spreadOverrides.remove(target - 1);
      }
    }
    if (kind == 'pair') {
      if (_spreadOverrides[start - 1] == 'pair') {
        _spreadOverrides.remove(start - 1);
      }
      _spreadOverrides.remove(start + 1);
    }
    if (kind != null) _spreadOverrides[kind == 'pair' ? start : target] = kind;
    final saved = appdata.settings['readerSpreadOverrides'];
    final all = saved is Map
        ? Map<String, dynamic>.from(saved)
        : <String, dynamic>{};
    if (_spreadOverrides.isEmpty) {
      all.remove(_spreadSettingsKey);
    } else {
      all[_spreadSettingsKey] = {
        for (final entry in _spreadOverrides.entries)
          entry.key.toString(): entry.value,
      };
    }
    appdata.settings['readerSpreadOverrides'] = all;
    unawaited(appdata.saveData());
    spreadLayoutRevision++;
    _page = imageLayout.pageForImage(start + 1);
    updateHistory();
    update();
  }

  @override
  late ReaderMode mode;

  @override
  bool get isPortrait =>
      MediaQuery.of(context).orientation == Orientation.portrait;

  History? history;

  @override
  bool isLoading = false;

  bool _showWhiteRefreshOverlay = false;
  Timer? _whiteRefreshOverlayTimer;
  bool _whiteRefreshOverlayReady = false;
  DateTime? _readingSessionStarted;
  bool _markedComplete = false;

  var focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _readingSessionStarted = ReadingStatisticsManager().isRecordingEnabled
        ? DateTime.now()
        : null;
    mode = ReaderMode.fromKey(
      appdata.settings.getReaderSetting(cid, type.sourceKey, 'readerMode'),
    );
    page = widget.initialPage ?? 1;
    if (page < 1) {
      page = 1;
    }
    chapter = widget.initialChapter ?? 1;
    if (chapter < 1) {
      chapter = 1;
    }
    if (widget.initialChapterGroup != null) {
      for (int i = 0; i < (widget.initialChapterGroup! - 1); i++) {
        chapter += widget.chapters!.getGroupByIndex(i).length;
      }
    }
    if (widget.initialPage != null) {
      page = widget.initialPage!;
      if (page < 1) {
        page = 1;
      }
    }
    history = widget.history;
    _initialSpreadImage = widget.initialPage ?? 1;
    if (!appdata.settings.getReaderSetting(
      cid,
      type.sourceKey,
      'showSystemStatusBar',
    )) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersive);
    }
    if (appdata.settings.getReaderSetting(
      cid,
      type.sourceKey,
      'enableTurnPageByVolumeKey',
    )) {
      handleVolumeEvent();
    }
    setImageCacheSize();
    Future.delayed(const Duration(milliseconds: 200), () {
      LocalFavoritesManager().onRead(cid, type);
    });
  }

  bool _isInitialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_isInitialized) {
      initImagesPerPage(widget.initialPage ?? 1);
      _isInitialized = true;
    } else {
      // For orientation changed
      _checkImagesPerPageChange();
    }
    initReaderWindow();
    if (!_whiteRefreshOverlayReady) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        _whiteRefreshOverlayReady = true;
      });
    }
  }

  void setImageCacheSize() async {
    var availableRAM = await MemoryInfo.getFreePhysicalMemorySize();
    if (availableRAM == null) return;
    int maxImageCacheSize;
    if (availableRAM < 1 << 30) {
      maxImageCacheSize = 100 << 20;
    } else if (availableRAM < 2 << 30) {
      maxImageCacheSize = 200 << 20;
    } else if (availableRAM < 4 << 30) {
      maxImageCacheSize = 300 << 20;
    } else {
      maxImageCacheSize = 500 << 20;
    }
    Log.info(
      "Reader",
      "Detect available RAM: $availableRAM, set image cache size to $maxImageCacheSize",
    );
    PaintingBinding.instance.imageCache.maximumSizeBytes = maxImageCacheSize;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _commitReadingSession();
    if (isFullscreen) {
      fullscreen();
    }
    autoPageTurningTimer?.cancel();
    _whiteRefreshOverlayTimer?.cancel();
    focusNode.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    stopVolumeEvent();
    Future.microtask(() {
      DataSync().onDataChanged();
    });
    PaintingBinding.instance.imageCache.maximumSizeBytes = 100 << 20;
    disposeReaderWindow();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden) {
      _commitReadingSession();
    } else if (state == AppLifecycleState.resumed &&
        _readingSessionStarted == null &&
        ReadingStatisticsManager().isRecordingEnabled) {
      _readingSessionStarted = DateTime.now();
    }
  }

  void _commitReadingSession() {
    final started = _readingSessionStarted;
    _readingSessionStarted = null;
    if (started == null || images == null || images!.isEmpty) return;
    ReadingStatisticsManager().recordSession(
      comic: widget.history,
      startedAt: started,
      endedAt: DateTime.now(),
    );
  }

  void _markReadLaterComplete() {
    if (_markedComplete ||
        appdata.settings.getReaderSetting(
              cid,
              type.sourceKey,
              'removeReadLaterOnComplete',
            ) !=
            true ||
        isOnChapterCommentsPage ||
        images == null ||
        images!.isEmpty ||
        page < maxPage ||
        chapter != chapterSequence.lastChapter(widget.chapters)) {
      return;
    }
    _markedComplete = true;
    ReadLaterManager().remove(cid, type);
  }

  @override
  Widget build(BuildContext context) {
    _checkImagesPerPageChange();
    return KeyboardListener(
      focusNode: focusNode,
      autofocus: true,
      onKeyEvent: onKeyEvent,
      child: Overlay(
        initialEntries: [
          OverlayEntry(
            builder: (context) {
              return Stack(
                children: [
                  _ReaderScaffold(
                    child: _ReaderGestureDetector(
                      child: _ReaderImages(
                        key: Key(
                          waterfallEnabled
                              ? 'waterfall-$_chapterSession'
                              : chapter.toString(),
                        ),
                      ),
                    ),
                  ),
                  Positioned.fill(
                    child: IgnorePointer(
                      child: AnimatedOpacity(
                        opacity: _showWhiteRefreshOverlay ? 1 : 0,
                        duration: const Duration(milliseconds: 40),
                        curve: Curves.linear,
                        child: const ColoredBox(color: Colors.white),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  void onKeyEvent(KeyEvent event) {
    if (event.logicalKey == LogicalKeyboardKey.f12 && event is KeyUpEvent) {
      fullscreen();
    }
    _imageViewController?.handleKeyEvent(event);
  }

  @override
  int get maxChapter => widget.chapters?.length ?? 1;

  @override
  void onPageChanged() {
    flashWhiteScreenOnPageTurn();
    updateHistory();
    _markReadLaterComplete();
  }

  void flashWhiteScreenOnPageTurn() {
    if (!_whiteRefreshOverlayReady) {
      return;
    }
    if (mode.isContinuous) {
      return;
    }
    if (appdata.settings.getReaderSetting(
          cid,
          type.sourceKey,
          'flashWhiteScreenOnPageTurn',
        ) !=
        true) {
      return;
    }
    _whiteRefreshOverlayTimer?.cancel();
    if (!_showWhiteRefreshOverlay) {
      setState(() {
        _showWhiteRefreshOverlay = true;
      });
    }
    _whiteRefreshOverlayTimer = Timer(const Duration(milliseconds: 90), () {
      if (!mounted) {
        return;
      }
      setState(() {
        _showWhiteRefreshOverlay = false;
      });
    });
  }

  /// Prevent multiple history updates in a short time.
  /// `HistoryManager().addHistoryAsync` is a high-cost operation because it creates a new isolate.
  Timer? _updateHistoryTimer;

  void updateHistory() {
    if (history != null) {
      // page >= maxPage handles both last image page and chapter comments page
      if (page >= maxPage) {
        /// Record the last image of chapter
        history!.page = images?.length ?? 1;
      } else {
        /// Record the first image of the page
        history!.page = imageLayout.range(page).$1 + 1;
      }
      history!.maxPage = images?.length ?? 1;
      if (widget.chapters?.isGrouped ?? false) {
        int g = 0;
        int c = chapter;
        while (c > widget.chapters!.getGroupByIndex(g).length) {
          c -= widget.chapters!.getGroupByIndex(g).length;
          g++;
        }
        history!.readEpisode.add('${g + 1}-$c');
        history!.ep = c;
        history!.group = g + 1;
      } else {
        history!.readEpisode.add(chapter.toString());
        history!.ep = chapter;
      }
      history!.time = DateTime.now();
      _updateHistoryTimer?.cancel();
      _updateHistoryTimer = Timer(const Duration(seconds: 1), () {
        HistoryManager().addHistoryAsync(history!);
        _updateHistoryTimer = null;
      });
    }
  }

  ChapterOrder get chapterOrder => ChapterOrder.forComic(cid, type.sourceKey);

  ChapterNavigation? _chapterNavigation;
  int? _chapterNavigationIndex;

  ChapterReadingOrder get chapterReadingOrder =>
      ChapterReadingOrder.forComic(cid, type.sourceKey);

  String get _chapterGroupKey {
    final chapters = widget.chapters;
    final first = chapters == null
        ? 1
        : ChapterNavigation.groupRange(chapters, chapter).$1;
    return '$cid@${type.sourceKey}@$first';
  }

  ChapterSequence get chapterSequence {
    final order = chapterReadingOrder;
    final learned = appdata.settings['detectedChapterReadingOrder'];
    return ChapterSequence(
      descending:
          order == ChapterReadingOrder.reverse ||
          order == ChapterReadingOrder.automatic &&
              learned is Map &&
              learned[_chapterGroupKey] == true,
    );
  }

  void resolveChapterNavigation() {
    _chapterNavigationIndex = chapter;
    _chapterNavigation = ChapterNavigation.fromCache(widget.chapters, chapter);
    final descending = _chapterNavigation?.descendingFrom(chapter);
    if (descending == null) return;
    final saved = appdata.settings['detectedChapterReadingOrder'];
    if (saved is Map && saved[_chapterGroupKey] == descending) return;
    appdata.settings['detectedChapterReadingOrder'] = <String, dynamic>{
      if (saved is Map) ...Map<String, dynamic>.from(saved),
      _chapterGroupKey: descending,
    };
    appdata.saveData();
  }

  int? adjacentChapter({required bool forward}) {
    if (chapterReadingOrder == ChapterReadingOrder.automatic &&
        _chapterNavigationIndex == chapter &&
        _chapterNavigation != null) {
      return forward ? _chapterNavigation!.next : _chapterNavigation!.previous;
    }
    return chapterSequence.adjacent(widget.chapters, chapter, forward: forward);
  }

  bool get isFirstChapterOfGroup => adjacentChapter(forward: false) == null;
  bool get isLastChapterOfGroup => adjacentChapter(forward: true) == null;

  @override
  bool toNextChapter() {
    final target = adjacentChapter(forward: true);
    return target != null && toChapter(target);
  }

  @override
  bool toPrevChapter({bool toLastPage = false}) {
    final target = adjacentChapter(forward: false);
    return target != null && toChapter(target, toLastPage: toLastPage);
  }

  /// Get the size of the reader.
  /// The size is not always the same as the size of the screen.
  Size get size {
    var renderBox = context.findRenderObject() as RenderBox;
    return renderBox.size;
  }
}

abstract mixin class _ImagePerPageHandler {
  int imageGroupingOffset = 0;
  int? imageGroupingAnchor;

  Set<int> get standaloneSpreadImages;
  Set<int> get joinedSpreadPairs;
  int get spreadLayoutRevision;

  void resetImageGrouping() {
    imageGroupingOffset = 0;
    imageGroupingAnchor = null;
  }

  Object? _imageLayoutKey;
  ReaderPageLayout? _cachedImageLayout;

  ReaderPageLayout _layoutFor(int count, bool cover, bool spread) =>
      ReaderPageLayout(
        imageCount: images?.length ?? 0,
        imagesPerPage: count,
        singleCover: cover,
        offset: imageGroupingOffset,
        standaloneImages: spread ? standaloneSpreadImages : const {},
        joinedPairs: spread ? joinedSpreadPairs : const {},
        anchor: spread ? imageGroupingAnchor : null,
      );

  ReaderPageLayout get imageLayout {
    final key = (
      images,
      imagesPerPage,
      showSingleImageOnFirstPage(),
      imageGroupingOffset,
      imageGroupingAnchor,
      twoPageSpread,
      spreadLayoutRevision,
    );
    if (key != _imageLayoutKey) {
      _imageLayoutKey = key;
      _cachedImageLayout = _layoutFor(
        imagesPerPage,
        showSingleImageOnFirstPage(),
        twoPageSpread,
      );
    }
    return _cachedImageLayout!;
  }

  late int _lastImagesPerPage;

  late bool _lastOrientation;

  late bool _lastSingleImageOnFirstPage;
  late bool _lastTwoPageSpread;

  /// Track if we were on the chapter comments page before orientation change
  bool _wasOnCommentsPage = false;

  bool get isPortrait;

  int get page;

  set page(int value);

  ReaderMode get mode;

  String get cid;

  ComicType get type;

  /// Whether the current page is the chapter comments page
  bool get isOnChapterCommentsPage;

  /// Get the max page (excluding comments page)
  int get maxPage;

  /// Get images list for calculating maxPage
  List<String>? get images;

  void initImagesPerPage(int initialPage) {
    _lastImagesPerPage = imagesPerPage;
    _lastSingleImageOnFirstPage = showSingleImageOnFirstPage();
    _lastTwoPageSpread = twoPageSpread;
    _lastOrientation = isPortrait;
    _wasOnCommentsPage = false;
    if (imagesPerPage != 1) {
      if (showSingleImageOnFirstPage()) {
        page = ((initialPage - 1) / imagesPerPage).ceil() + 1;
      } else {
        page = (initialPage / imagesPerPage).ceil();
      }
    }
  }

  bool showSingleImageOnFirstPage() => appdata.settings.getReaderSetting(
    cid,
    type.sourceKey,
    'showSingleImageOnFirstPage',
  );

  bool get twoPageSpread =>
      (mode == ReaderMode.galleryLeftToRight ||
          mode == ReaderMode.galleryRightToLeft) &&
      appdata.settings.getReaderSetting(
            cid,
            type.sourceKey,
            'readerTwoPageSpread',
          ) ==
          true;

  /// The number of images displayed on one screen
  int get imagesPerPage {
    if (mode.isContinuous) return 1;
    if (twoPageSpread) return 2;
    if (isPortrait) {
      return appdata.settings.getReaderSetting(
            cid,
            type.sourceKey,
            'readerScreenPicNumberForPortrait',
          ) ??
          1;
    } else {
      return appdata.settings.getReaderSetting(
            cid,
            type.sourceKey,
            'readerScreenPicNumberForLandscape',
          ) ??
          1;
    }
  }

  /// Calculate maxPage with a specific imagesPerPage value
  int _calcMaxPage(int imagesPerPageValue, bool singleImageOnFirstPage) {
    return _layoutFor(
      imagesPerPageValue,
      singleImageOnFirstPage,
      _lastTwoPageSpread,
    ).pageCount;
  }

  /// Check if the number of images per page has changed
  void _checkImagesPerPageChange() {
    int currentImagesPerPage = imagesPerPage;
    bool currentOrientation = isPortrait;

    if (_lastImagesPerPage != currentImagesPerPage ||
        _lastTwoPageSpread != twoPageSpread ||
        _lastOrientation != currentOrientation ||
        _lastSingleImageOnFirstPage != showSingleImageOnFirstPage()) {
      // Calculate old maxPage using old imagesPerPage to correctly determine
      // if we were on the comments page before the orientation change
      int oldMaxPage = _calcMaxPage(
        _lastImagesPerPage,
        _lastSingleImageOnFirstPage,
      );
      _wasOnCommentsPage = page > oldMaxPage;

      _adjustPageForImagesPerPageChange(
        _lastImagesPerPage,
        currentImagesPerPage,
      );
      _lastImagesPerPage = currentImagesPerPage;
      _lastOrientation = currentOrientation;
      _lastSingleImageOnFirstPage = showSingleImageOnFirstPage();
      _lastTwoPageSpread = twoPageSpread;
    }
  }

  /// Adjust the page number when the number of images per page changes
  void _adjustPageForImagesPerPageChange(
    int oldImagesPerPage,
    int newImagesPerPage,
  ) {
    final previousImageIndex =
        _layoutFor(
          oldImagesPerPage,
          _lastSingleImageOnFirstPage,
          _lastTwoPageSpread,
        ).range(page).$1 +
        1;
    if (oldImagesPerPage != newImagesPerPage ||
        _lastTwoPageSpread != twoPageSpread ||
        _lastSingleImageOnFirstPage != showSingleImageOnFirstPage()) {
      resetImageGrouping();
    }
    int newPage = imageLayout.pageForImage(previousImageIndex);

    // Clamp to valid range (1 to maxPage)
    newPage = newPage.clamp(1, maxPage);

    // If we were on the comments page, stay on the comments page
    if (_wasOnCommentsPage) {
      page = maxPage + 1;
    } else {
      page = newPage;
    }
  }
}

abstract mixin class _VolumeListener {
  bool turnPage({required bool forward});

  VolumeListener? volumeListener;

  void onDown() {
    turnPage(forward: true);
  }

  void onUp() {
    turnPage(forward: false);
  }

  void handleVolumeEvent() {
    if (!App.isAndroid) {
      // Currently only support Android
      return;
    }
    if (volumeListener != null) {
      volumeListener?.cancel();
    }
    volumeListener = VolumeListener(onDown: onDown, onUp: onUp)..listen();
  }

  void stopVolumeEvent() {
    if (volumeListener != null) {
      volumeListener?.cancel();
      volumeListener = null;
    }
  }
}

abstract mixin class _ReaderLocation {
  void resetImageGrouping();
  int _page = 1;
  int? _pendingPage;

  /// Flag to indicate that the page should jump to the last page after images are loaded.
  bool _jumpToLastPageOnLoad = false;
  bool _alignContinuousChapterEnd = false;

  int get page => _page;

  set page(int value) {
    _page = value;
    onPageChanged();
  }

  int chapter = 1;
  int _chapterSession = 0;

  int get maxPage;

  /// Total pages including chapter comments page (for internal page control).
  int get totalPages;

  int get maxChapter;

  bool get isLoading;

  String get cid;

  ComicType get type;

  void update();

  bool enablePageAnimation(String cid, ComicType type) => appdata.settings
      .getReaderSetting(cid, type.sourceKey, 'enablePageAnimation');

  _ImageViewController? _imageViewController;

  void onPageChanged();

  void setPage(int page) {
    // Prevent page change during animation
    if (_animationCount > 0 && _pendingPage != null && page != _pendingPage) {
      return;
    }
    this.page = page;
  }

  bool _validatePage(int page) {
    return page >= 1 && page <= totalPages;
  }

  /// Returns true if the page is changed
  bool toNextPage() {
    return toPage((_pendingPage ?? page) + 1);
  }

  /// Returns true if the page is changed
  bool toPrevPage() {
    return toPage((_pendingPage ?? page) - 1);
  }

  int _animationCount = 0;
  int _navigationId = 0;

  bool toPage(int page, {bool animate = true}) {
    if (_validatePage(page)) {
      if (page == (_pendingPage ?? this.page) &&
          page != 1 &&
          page != totalPages) {
        return false;
      }
      final navigationId = ++_navigationId;
      // Interrupt an earlier transition with a jump instead of overlapping it.
      final hasAnimation =
          animate && _animationCount == 0 && enablePageAnimation(cid, type);
      if (hasAnimation) {
        _pendingPage = page;
        _animationCount = 1;
        update();
        void finishAnimation() {
          if (navigationId != _navigationId) return;
          _animationCount = 0;
          _pendingPage = null;
          update();
        }

        _imageViewController!
            .animateToPage(page)
            .then(
              (_) {
                finishAnimation();
              },
              onError: (Object error, StackTrace stack) {
                finishAnimation();
                Log.error('Reader navigation', error, stack);
              },
            );
      } else {
        _animationCount = 0;
        _pendingPage = null;
        this.page = page;
        update();
        _imageViewController!.toPage(page);
      }
      return true;
    }
    return false;
  }

  bool get isPageAnimating => _animationCount > 0;

  bool _validateChapter(int chapter) {
    return chapter >= 1 && chapter <= maxChapter;
  }

  /// Returns true if the chapter is changed
  bool toNextChapter() {
    return toChapter(chapter + 1);
  }

  /// Returns true if the chapter is changed
  /// If [toLastPage] is true, the page will be set to the last page of the previous chapter.
  bool toPrevChapter({bool toLastPage = false}) {
    return toChapter(chapter - 1, toLastPage: toLastPage);
  }

  bool toChapter(int c, {bool toLastPage = false}) {
    if (_validateChapter(c) && !isLoading) {
      _chapterSession++;
      chapter = c;
      resetImageGrouping();
      page = 1;
      _jumpToLastPageOnLoad = toLastPage;
      update();
      return true;
    }
    return false;
  }

  Timer? autoPageTurningTimer;

  void autoPageTurning(String cid, ComicType type) {
    if (autoPageTurningTimer != null) {
      autoPageTurningTimer!.cancel();
      autoPageTurningTimer = null;
    } else {
      int interval = appdata.settings.getReaderSetting(
        cid,
        type.sourceKey,
        'autoPageTurningInterval',
      );
      autoPageTurningTimer = Timer.periodic(Duration(seconds: interval), (_) {
        if (page == maxPage) {
          autoPageTurningTimer!.cancel();
        }
        toNextPage();
      });
    }
  }
}

mixin class _ReaderWindow {
  bool isFullscreen = false;

  late WindowFrameController windowFrame;

  bool _isInit = false;

  void initReaderWindow() {
    if (!App.isDesktop || _isInit) return;
    windowFrame = WindowFrame.of(App.rootContext);
    windowFrame.addCloseListener(onWindowClose);
    _isInit = true;
  }

  void fullscreen() async {
    if (!App.isDesktop) return;
    await windowManager.hide();
    await windowManager.setFullScreen(!isFullscreen);
    await windowManager.show();
    isFullscreen = !isFullscreen;
    WindowFrame.of(App.rootContext).setWindowFrame(!isFullscreen);
  }

  bool onWindowClose() {
    if (Navigator.of(App.rootContext).canPop()) {
      Navigator.of(App.rootContext).pop();
      return false;
    } else {
      return true;
    }
  }

  void disposeReaderWindow() {
    if (!App.isDesktop) return;
    windowFrame.removeCloseListener(onWindowClose);
  }
}

enum ReaderMode {
  galleryLeftToRight('galleryLeftToRight'),
  galleryRightToLeft('galleryRightToLeft'),
  galleryTopToBottom('galleryTopToBottom'),
  continuousTopToBottom('continuousTopToBottom'),
  continuousLeftToRight('continuousLeftToRight'),
  continuousRightToLeft('continuousRightToLeft');

  final String key;

  bool get isGallery => key.startsWith('gallery');

  bool get isContinuous => key.startsWith('continuous');

  const ReaderMode(this.key);

  static ReaderMode fromKey(String key) {
    for (var mode in values) {
      if (mode.key == key) {
        return mode;
      }
    }
    return galleryLeftToRight;
  }
}

abstract interface class _ImageViewController {
  void toPage(int page);

  Future<void> animateToPage(int page);

  void handleDoubleTap(Offset location);

  void handleLongPressDown(Offset location);

  void handleLongPressUp(Offset location);

  void handleKeyEvent(KeyEvent event);

  /// Returns true if the event is handled.
  bool handleOnTap(Offset location);

  Future<Uint8List?> getImageByOffset(Offset offset);

  String? getImageKeyByOffset(Offset offset);
}
