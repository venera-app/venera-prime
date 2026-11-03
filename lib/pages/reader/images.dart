part of 'reader.dart';

class _ReaderImages extends StatefulWidget {
  const _ReaderImages({super.key});

  @override
  State<_ReaderImages> createState() => _ReaderImagesState();
}

class _ReaderImagesState extends State<_ReaderImages> {
  String? error;

  bool inProgress = false;

  late _ReaderState reader;

  @override
  void initState() {
    reader = context.reader;
    reader.isLoading = true;
    super.initState();
  }

  @override
  void dispose() {
    super.dispose();
    ImageDownloader.cancelAllLoadingImages();
  }

  /// Handle jumping to last page when _jumpToLastPageOnLoad is true
  void _handleJumpToLastPage() {
    if (reader._jumpToLastPageOnLoad) {
      reader._page = reader.maxPage;
      reader._alignContinuousChapterEnd = reader.mode.isContinuous;
      reader._jumpToLastPageOnLoad = false;
    }
  }

  void load() async {
    if (inProgress) return;
    inProgress = true;
    if (reader.type == ComicType.local ||
        (LocalManager().isDownloaded(
          reader.cid,
          reader.type,
          reader.chapter,
          reader.widget.chapters,
        ))) {
      try {
        var images = await LocalManager().getImages(
          reader.cid,
          reader.type,
          reader.chapter,
        );
        if (!mounted) return;
        setState(() {
          reader.images = images;
          reader.prepareSpreadLayout();
          reader.resolveChapterNavigation();
          reader.isLoading = false;
          inProgress = false;
          _handleJumpToLastPage();
          Future.microtask(() {
            reader.updateHistory();
          });
        });
      } catch (e) {
        if (!mounted) return;
        setState(() {
          error = e.toString();
          reader.isLoading = false;
          inProgress = false;
        });
      }
    } else {
      var cp = reader.widget.chapters?.ids.elementAtOrNull(reader.chapter - 1);
      try {
        var res = await reader.type.comicSource!.loadComicPages!(
          reader.widget.cid,
          cp,
        );
        if (res.error) {
          if (!mounted) return;
          setState(() {
            error = res.errorMessage;
            reader.isLoading = false;
            inProgress = false;
          });
        } else {
          if (!mounted) return;
          setState(() {
            reader.images = res.data;
            reader.prepareSpreadLayout();
            reader.resolveChapterNavigation();
            reader.isLoading = false;
            inProgress = false;
            _handleJumpToLastPage();
            Future.microtask(() {
              reader.updateHistory();
            });
          });
        }
      } catch (e) {
        if (!mounted) return;
        setState(() {
          error = e.toString();
          reader.isLoading = false;
          inProgress = false;
        });
      }
    }
    context.readerScaffold.update();
  }

  @override
  Widget build(BuildContext context) {
    if (reader.isLoading) {
      load();
      return const Center(child: CircularProgressIndicator());
    } else if (error != null) {
      return GestureDetector(
        onTap: () {
          context.readerScaffold.openOrClose();
        },
        child: SizedBox.expand(
          child: NetworkError(
            message: error!,
            retry: () {
              setState(() {
                reader.isLoading = true;
                error = null;
              });
            },
          ),
        ),
      );
    } else {
      if (reader.mode.isGallery) {
        var showComments =
            appdata.settings.getReaderSetting(
              reader.cid,
              reader.type.sourceKey,
              'showChapterComments',
            ) ==
            true;
        var showCommentsAtEnd =
            appdata.settings.getReaderSetting(
              reader.cid,
              reader.type.sourceKey,
              'showChapterCommentsAtEnd',
            ) ==
            true;
        return _GalleryMode(
          key: Key(
            '${reader.mode.key}_${reader.imagesPerPage}_${reader.twoPageSpread}_${reader.showSingleImageOnFirstPage()}_${reader.imageGroupingOffset}_${reader.imageGroupingAnchor}_${reader.spreadLayoutRevision}_${showComments}_$showCommentsAtEnd',
          ),
        );
      } else {
        return _ContinuousMode(key: Key(reader.mode.key));
      }
    }
  }
}

class _GalleryMode extends StatefulWidget {
  const _GalleryMode({super.key});

  @override
  State<_GalleryMode> createState() => _GalleryModeState();
}

class _GalleryModeState extends State<_GalleryMode>
    implements _ImageViewController {
  late PageController controller;

  int get preCacheCount => appdata.settings["preloadImageCount"];

  var photoViewControllers = <int, PhotoViewController>{};

  double? _lastPageMargin;
  final _unmarginedInitialScales = <int, double>{};
  final _pendingSpreadSizes = <int, Size>{};
  bool _spreadSizeUpdateScheduled = false;
  Timer? _spreadSizeRetry;
  final _spreadMetadataStreams = <int, (ImageStream, ImageStreamListener)>{};

  void _queueSpreadSize(int index, Size size) {
    if (!mounted) return;
    if (reader.spreadImageSizes[index] == size ||
        _pendingSpreadSizes[index] == size) {
      return;
    }
    _pendingSpreadSizes[index] = size;
    if (_spreadSizeUpdateScheduled) return;
    _spreadSizeUpdateScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) => _flushSpreadSizes());
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  void _flushSpreadSizes() {
    if (!mounted) return;
    if (reader.isPageAnimating) {
      _spreadSizeRetry?.cancel();
      _spreadSizeRetry = Timer(
        const Duration(milliseconds: 50),
        _flushSpreadSizes,
      );
      return;
    }
    _spreadSizeUpdateScheduled = false;
    final sizes = Map<int, Size>.of(_pendingSpreadSizes);
    _pendingSpreadSizes.clear();
    if (sizes.isEmpty) return;
    if (reader.applySpreadImageSizes(sizes)) {
      reader.updateHistory();
      context.readerScaffold.update();
    } else {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _spreadSizeRetry?.cancel();
    keyRepeatTimer?.cancel();
    for (final (stream, listener) in _spreadMetadataStreams.values) {
      stream.removeListener(listener);
    }
    _spreadMetadataStreams.clear();
    super.dispose();
  }

  late _ReaderState reader;

  bool get showChapterCommentsAtEnd {
    if (reader.mode != ReaderMode.galleryLeftToRight &&
        reader.mode != ReaderMode.galleryRightToLeft) {
      return false;
    }
    if (reader.widget.chapters == null) return false;
    var source = ComicSource.find(reader.type.sourceKey);
    if (source?.chapterCommentsLoader == null) return false;
    return appdata.settings.getReaderSetting(
              reader.cid,
              reader.type.sourceKey,
              'showChapterComments',
            ) ==
            true &&
        appdata.settings.getReaderSetting(
              reader.cid,
              reader.type.sourceKey,
              'showChapterCommentsAtEnd',
            ) ==
            true;
  }

  int get totalImagePages {
    return reader.maxPage;
  }

  int get totalPages => reader.totalPages;

  bool isChapterCommentsPage(int pageIndex) {
    return showChapterCommentsAtEnd && pageIndex == totalImagePages + 1;
  }

  var imageStates = <State<ComicImage>>{};

  bool isLongPressing = false;

  int fingers = 0;

  @override
  void initState() {
    reader = context.reader;
    controller = PageController(initialPage: reader.page);
    reader._imageViewController = this;
    Future.microtask(() {
      context.readerScaffold.setFloatingButton(0);
    });
    super.initState();
  }

  /// Get the range of images for the given page. [page] is 1-based.
  (int start, int end) getPageImagesRange(int page) {
    return reader.imageLayout.range(page);
  }

  /// Get the image indices for current page. Returns null if no images.
  /// Returns a single index if only one image, or a range if multiple images.
  (int, int)? getCurrentPageImageRange() {
    if (reader.images == null || reader.images!.isEmpty) {
      return null;
    }
    var (startIndex, endIndex) = getPageImagesRange(reader.page);
    return (startIndex, endIndex);
  }

  void cache(int startPage) {
    for (int i = startPage - 1; i <= startPage + preCacheCount; i++) {
      if (i == startPage ||
          i <= 0 ||
          i > totalPages ||
          isChapterCommentsPage(i)) {
        continue;
      }
      _cachePage(i, i == startPage + 1 || i == startPage - 1);
    }
  }

  void _cachePage(int page, bool shouldPreCache) {
    if (isChapterCommentsPage(page)) return;
    var (startIndex, endIndex) = getPageImagesRange(page);
    for (int i = startIndex; i < endIndex; i++) {
      if (shouldPreCache && reader.twoPageSpread) {
        _precacheSpreadImage(i);
      } else if (shouldPreCache) {
        _precacheImage(i + 1, context);
      } else {
        _preDownloadImage(i + 1, context);
      }
    }
  }

  void _precacheSpreadImage(int index) {
    if (_spreadMetadataStreams.containsKey(index)) return;
    final stream = _createImageProvider(
      index + 1,
      context,
    ).resolve(createLocalImageConfiguration(context));
    late final ImageStreamListener listener;
    void release() {
      if (_spreadMetadataStreams[index]?.$2 != listener) return;
      stream.removeListener(listener);
      _spreadMetadataStreams.remove(index);
    }

    listener = ImageStreamListener((info, synchronous) {
      _queueSpreadSize(
        index,
        Size(info.image.width.toDouble(), info.image.height.toDouble()),
      );
      // Match precacheImage's ownership and keep it alive through this frame.
      SchedulerBinding.instance.addPostFrameCallback((_) {
        info.dispose();
        release();
      });
    }, onError: (Object error, StackTrace? stack) => release());
    _spreadMetadataStreams[index] = (stream, listener);
    stream.addListener(listener);
  }

  Widget _buildChapterCommentsPage() {
    var source = ComicSource.find(reader.type.sourceKey);
    var chapters = reader.widget.chapters;
    if (source == null || chapters == null) return const SizedBox();
    var chapterIndex = reader.chapter - 1;
    return _EmbeddedChapterCommentsPage(
      comicId: reader.cid,
      epId: chapters.ids.elementAt(chapterIndex),
      source: source,
      comicTitle: reader.widget.name,
      chapterTitle: chapters.titles.elementAt(chapterIndex),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewportSize = constraints.biggest;
        final margin = readerPageMargin(reader.cid, reader.type.sourceKey);
        final previousMargin = _lastPageMargin;
        _lastPageMargin = margin;
        if (previousMargin != null && previousMargin != margin) {
          final ratio = (1 - margin * 2) / (1 - previousMargin * 2);
          for (final entry in photoViewControllers.entries) {
            final (start, end) = getPageImagesRange(entry.key);
            if (end - start != 1 || reader.twoPageSpread) continue;
            final scale = entry.value.scale;
            if (scale == null) continue;
            final initialScale = entry.value.getInitialScale?.call();
            if (initialScale != null) {
              _unmarginedInitialScales.putIfAbsent(
                entry.key,
                () => initialScale / (1 - previousMargin * 2),
              );
            }
            // PhotoView retains its scale when only initialScale changes.
            entry.value.updateMultiple(
              scale: scale * ratio,
              position: entry.value.position * ratio,
            );
          }
        }
        return Listener(
          onPointerDown: (event) {
            fingers++;
          },
          onPointerUp: (event) {
            fingers--;
          },
          onPointerCancel: (event) {
            fingers--;
          },
          onPointerMove: (event) {
            if (isLongPressing) {
              var controller = photoViewControllers[reader.page]!;
              Offset value = event.delta;
              if (isLongPressing) {
                controller.updateMultiple(
                  position: controller.position + value,
                );
              }
            }
          },
          child: PhotoViewGallery.builder(
            backgroundDecoration: BoxDecoration(
              color: readerBackgroundColor(
                context,
                reader.cid,
                reader.type.sourceKey,
              ),
            ),
            reverse: reader.mode == ReaderMode.galleryRightToLeft,
            scrollDirection: reader.mode == ReaderMode.galleryTopToBottom
                ? Axis.vertical
                : Axis.horizontal,
            itemCount: totalPages + 2,
            builder: (BuildContext context, int index) {
              if (index == 0 || index == totalPages + 1) {
                return PhotoViewGalleryPageOptions.customChild(
                  child: const SizedBox(),
                );
              } else if (isChapterCommentsPage(index)) {
                return PhotoViewGalleryPageOptions.customChild(
                  child: _buildChapterCommentsPage(),
                );
              } else {
                var (startIndex, endIndex) = getPageImagesRange(index);
                List<String> pageImages = reader.images!.sublist(
                  startIndex,
                  endIndex,
                );

                cache(index);

                photoViewControllers[index] ??= PhotoViewController();

                if (reader.imagesPerPage == 1 ||
                    (pageImages.length == 1 && !reader.twoPageSpread)) {
                  return PhotoViewGalleryPageOptions(
                    filterQuality: FilterQuality.medium,
                    initialScale: margin == 0
                        ? null
                        : PhotoViewComputedScale.contained * (1 - margin * 2),
                    controller: photoViewControllers[index],
                    imageProvider: _createImageProviderFromKey(
                      pageImages[0],
                      context,
                      startIndex + 1,
                    ),
                    fit: BoxFit.contain,
                    errorBuilder: (_, error, s, retry) {
                      return NetworkError(
                        message: error.toString(),
                        retry: retry,
                      );
                    },
                  );
                }

                return PhotoViewGalleryPageOptions.customChild(
                  childSize: viewportSize,
                  controller: photoViewControllers[index],
                  minScale: PhotoViewComputedScale.contained * 1.0,
                  maxScale: PhotoViewComputedScale.covered * 10.0,
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: viewportSize.width * margin,
                      vertical: viewportSize.height * margin,
                    ),
                    child: buildPageImages(
                      pageImages,
                      startIndex,
                      singleCover:
                          index == 1 && reader.imageLayout.firstPageCount == 1,
                    ),
                  ),
                );
              }
            },
            pageController: controller,
            loadingBuilder: (context, event) {
              return PhotoView.customChild(
                childSize: viewportSize,
                initialScale: PhotoViewComputedScale.contained,
                minScale: PhotoViewComputedScale.contained * 1.0,
                maxScale: PhotoViewComputedScale.covered * 10.0,
                backgroundDecoration: BoxDecoration(
                  color: readerBackgroundColor(
                    context,
                    reader.cid,
                    reader.type.sourceKey,
                  ),
                ),
                child: Center(
                  child: SizedBox(
                    width: 20.0,
                    height: 20.0,
                    child: CircularProgressIndicator(
                      backgroundColor: readerBackgroundColor(
                        context,
                        reader.cid,
                        reader.type.sourceKey,
                      ),
                      value: event == null || event.expectedTotalBytes == null
                          ? null
                          : event.cumulativeBytesLoaded /
                                event.expectedTotalBytes!,
                    ),
                  ),
                ),
              );
            },
            onPageChanged: (i) {
              if (i == 0) {
                if (reader.isFirstChapterOfGroup ||
                    !reader.toPrevChapter(toLastPage: true)) {
                  controller.jumpToPage(1);
                }
              } else if (i == totalPages + 1) {
                if (reader.isLastChapterOfGroup || !reader.toNextChapter()) {
                  controller.jumpToPage(totalPages);
                }
              } else {
                reader.setPage(i);
                context.readerScaffold.update();
                // Auto close toolbar when entering chapter comments page
                if (isChapterCommentsPage(i) && context.readerScaffold.isOpen) {
                  context.readerScaffold.openOrClose();
                }
              }
              // Remove other pages' controllers to reset their state.
              var keys = photoViewControllers.keys.toList();
              for (var key in keys) {
                if (key != i) {
                  photoViewControllers.remove(key);
                  _unmarginedInitialScales.remove(key);
                }
              }
            },
          ),
        );
      },
    );
  }

  Widget buildPageImages(
    List<String> images,
    int startIndex, {
    bool singleCover = false,
  }) {
    if (reader.twoPageSpread) {
      return _buildBookSpread(images, startIndex, singleCover: singleCover);
    }
    final axis = reader.mode == ReaderMode.galleryTopToBottom
        ? Axis.vertical
        : Axis.horizontal;
    final reverse = reader.mode == ReaderMode.galleryRightToLeft;
    // Keep the original image index when reversing visual order. Network
    // sources can use that index to resolve an image request.
    var slots = List<int?>.generate(images.length, (i) => i);
    if (reader.twoPageSpread && slots.length == 1) {
      slots = singleCover ? [null, 0] : [0, null];
    }
    if (reverse) slots = slots.reversed.toList();
    final children = <Widget>[];
    for (var slot = 0; slot < slots.length; slot++) {
      final imageIndex = slots[slot];
      children.add(
        Expanded(
          child: imageIndex == null
              ? const SizedBox.expand(key: ValueKey('reader-spread-blank'))
              : ComicImage(
                  key: ValueKey(
                    'reader-spread-image-${startIndex + imageIndex + 1}',
                  ),
                  width: double.infinity,
                  height: double.infinity,
                  image: _createImageProviderFromKey(
                    images[imageIndex],
                    context,
                    startIndex + imageIndex + 1,
                  ),
                  fit: BoxFit.contain,
                  alignment: slots.length != 2
                      ? Alignment.center
                      : axis == Axis.vertical
                      ? (slot == 0
                            ? Alignment.bottomCenter
                            : Alignment.topCenter)
                      : (slot == 0
                            ? Alignment.centerRight
                            : Alignment.centerLeft),
                  onInit: (state) => imageStates.add(state),
                  onDispose: (state) => imageStates.remove(state),
                ),
        ),
      );
    }
    return axis == Axis.vertical
        ? Column(children: children)
        : Row(children: children);
  }

  Widget _buildBookSpread(
    List<String> images,
    int startIndex, {
    required bool singleCover,
  }) {
    var slots = List<int?>.generate(images.length, (i) => i);
    if (slots.length == 1 &&
        !reader.standaloneSpreadImages.contains(startIndex)) {
      slots = singleCover ? [null, 0] : [0, null];
    }
    if (reader.mode == ReaderMode.galleryRightToLeft) {
      slots = slots.reversed.toList();
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final rects = readerSpreadRects(constraints.biggest, [
          for (final slot in slots)
            slot == null ? null : reader.spreadImageSizes[startIndex + slot],
        ]);
        return Stack(
          children: [
            for (var i = 0; i < rects.length; i++)
              Positioned.fromRect(
                rect: rects[i],
                child: slots[i] == null
                    ? const SizedBox.expand(
                        key: ValueKey('reader-spread-blank'),
                      )
                    : ComicImage(
                        key: ValueKey(
                          'reader-spread-image-${startIndex + slots[i]! + 1}',
                        ),
                        image: _createImageProviderFromKey(
                          images[slots[i]!],
                          context,
                          startIndex + slots[i]! + 1,
                        ),
                        width: rects[i].width,
                        height: rects[i].height,
                        fit: BoxFit.contain,
                        onImageSize: (size) =>
                            _queueSpreadSize(startIndex + slots[i]!, size),
                        onInit: imageStates.add,
                        onDispose: imageStates.remove,
                      ),
              ),
          ],
        );
      },
    );
  }

  @override
  Future<void> animateToPage(int page) {
    if ((page - controller.page!.round()).abs() > 1) {
      controller.jumpToPage(page > controller.page! ? page - 1 : page + 1);
    }
    return controller.animateToPage(
      page,
      duration: const Duration(milliseconds: 200),
      curve: Curves.ease,
    );
  }

  @override
  void toPage(int page) {
    controller.jumpToPage(page);
  }

  @override
  void handleDoubleTap(Offset location) {
    if (appdata.settings['quickCollectImage'] == 'DoubleTap') {
      context.readerScaffold.addImageFavorite();
      return;
    }
    var controller = photoViewControllers[reader.page]!;
    if (reader.twoPageSpread) {
      final initial = initialScaleForPage();
      if ((controller.scale ?? initial) > initial * 1.05) {
        controller.animateScale?.call(initial, Offset.zero);
        return;
      }
      final (start, end) = getPageImagesRange(reader.page);
      final viewport = context.findRenderObject();
      if (end - start == 2 && viewport is RenderBox) {
        for (final imageState in imageStates) {
          final key = imageState.widget.key;
          if (key != ValueKey('reader-spread-image-${start + 1}') &&
              key != ValueKey('reader-spread-image-$end')) {
            continue;
          }
          final box = imageState.context.findRenderObject();
          if (box is! RenderBox || !box.hasSize) continue;
          final origin = box.localToGlobal(Offset.zero);
          final globalRect = origin & box.size;
          if (!globalRect.contains(location)) continue;
          final center = viewport.globalToLocal(globalRect.center);
          final target =
              initial * (viewport.size.width / box.size.width).clamp(1.0, 4.0);
          controller.animateScale?.call(
            target,
            (viewport.size.center(Offset.zero) - center) * (target / initial),
          );
          return;
        }
      }
    }
    controller.onDoubleClick?.call();
  }

  @override
  void handleLongPressDown(Offset location) {
    if (!appdata.settings['enableLongPressToZoom'] || fingers != 1) {
      return;
    }
    var photoViewController = photoViewControllers[reader.page]!;
    double target = initialScaleForPage() * 1.75;
    var size = reader.size;
    Offset zoomPosition;
    if (appdata.settings['longPressZoomPosition'] != 'center') {
      zoomPosition = Offset(
        size.width / 2 - location.dx,
        size.height / 2 - location.dy,
      );
    } else {
      zoomPosition = Offset(0, 0);
    }
    photoViewController.animateScale?.call(target, zoomPosition);
    isLongPressing = true;
  }

  @override
  void handleLongPressUp(Offset location) {
    if (!appdata.settings['enableLongPressToZoom'] || !isLongPressing) {
      return;
    }
    var photoViewController = photoViewControllers[reader.page]!;
    double target = initialScaleForPage();
    photoViewController.animateScale?.call(target);
    isLongPressing = false;
  }

  double initialScaleForPage() {
    final unmarginedScale = _unmarginedInitialScales[reader.page];
    if (unmarginedScale != null) {
      return unmarginedScale *
          (1 - readerPageMargin(reader.cid, reader.type.sourceKey) * 2);
    }
    return photoViewControllers[reader.page]!.getInitialScale!.call()!;
  }

  Timer? keyRepeatTimer;

  @override
  void handleKeyEvent(KeyEvent event) {
    bool? forward;
    if (reader.mode == ReaderMode.galleryLeftToRight &&
        event.logicalKey == LogicalKeyboardKey.arrowRight) {
      forward = true;
    } else if (reader.mode == ReaderMode.galleryRightToLeft &&
        event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      forward = true;
    } else if (reader.mode == ReaderMode.galleryTopToBottom &&
        event.logicalKey == LogicalKeyboardKey.arrowDown) {
      forward = true;
    } else if (reader.mode == ReaderMode.galleryTopToBottom &&
        event.logicalKey == LogicalKeyboardKey.arrowUp) {
      forward = false;
    } else if (reader.mode == ReaderMode.galleryLeftToRight &&
        event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      forward = false;
    } else if (reader.mode == ReaderMode.galleryRightToLeft &&
        event.logicalKey == LogicalKeyboardKey.arrowRight) {
      forward = false;
    }
    if (event is KeyDownEvent) {
      if (keyRepeatTimer != null) {
        keyRepeatTimer!.cancel();
        keyRepeatTimer = null;
      }
      if (forward == true) {
        reader.turnPage(forward: true);
      } else if (forward == false) {
        reader.turnPage(forward: false);
      }
    }
    if (event is KeyRepeatEvent && keyRepeatTimer == null) {
      keyRepeatTimer = Timer.periodic(
        reader.enablePageAnimation(reader.cid, reader.type)
            ? const Duration(milliseconds: 200)
            : const Duration(milliseconds: 50),
        (timer) {
          if (!mounted) {
            timer.cancel();
            return;
          } else if (forward == true) {
            reader.turnPage(forward: true);
          } else if (forward == false) {
            reader.turnPage(forward: false);
          }
        },
      );
    }
    if (event is KeyUpEvent && keyRepeatTimer != null) {
      keyRepeatTimer!.cancel();
      keyRepeatTimer = null;
    }
  }

  @override
  bool handleOnTap(Offset location) {
    return false;
  }

  @override
  Future<Uint8List?> getImageByOffset(Offset offset) async {
    var imageKey = getImageKeyByOffset(offset);
    if (imageKey == null) return null;
    if (imageKey.startsWith("file://")) {
      return await File(imageKey.substring(7)).readAsBytes();
    } else {
      return CacheManager().readCache(
        "$imageKey@${context.reader.type.sourceKey}@${context.reader.cid}@${context.reader.eid}",
      );
    }
  }

  @override
  String? getImageKeyByOffset(Offset offset) {
    var range = getCurrentPageImageRange();
    if (range == null) return null;

    var (startIndex, endIndex) = range;
    int actualImageCount = endIndex - startIndex;

    if (actualImageCount == 1) {
      return reader.images![startIndex];
    }

    for (var imageState in imageStates) {
      if ((imageState as _ComicImageState).containsPoint(offset)) {
        var imageKey =
            (imageState.widget.image as ReaderImageProvider).imageKey;
        int index = reader.images!.indexOf(imageKey);
        if (index >= startIndex && index < endIndex) {
          return imageKey;
        }
      }
    }

    return reader.images![startIndex];
  }
}

const Set<PointerDeviceKind> _kTouchLikeDeviceTypes = <PointerDeviceKind>{
  PointerDeviceKind.touch,
  PointerDeviceKind.mouse,
  PointerDeviceKind.stylus,
  PointerDeviceKind.invertedStylus,
  PointerDeviceKind.unknown,
};

const double _kChangeChapterOffset = 160;

// Use finger travel for a new swipe at the boundary. Elastic overscroll is
// damped and may be unavailable when a short chapter fits in the viewport.
const double _kChapterSwipeDistance = 64;

class _ContinuousMode extends StatefulWidget {
  const _ContinuousMode({super.key});

  @override
  State<_ContinuousMode> createState() => _ContinuousModeState();
}

class _ContinuousModeState extends State<_ContinuousMode>
    implements _ImageViewController {
  late _ReaderState reader;

  var itemScrollController = ItemScrollController();
  var itemPositionsListener = ItemPositionsListener.create();
  var photoViewController = PhotoViewController();
  ScrollController? _scrollController;

  ScrollController get scrollController => _scrollController!;

  bool get isAtChapterStart =>
      _visibleImagesReady &&
      _scrollController?.hasClients == true &&
      scrollController.position.pixels <=
          scrollController.position.minScrollExtent + 0.5;

  bool get isAtChapterEnd =>
      _visibleImagesReady &&
      _scrollController?.hasClients == true &&
      scrollController.position.pixels >=
          scrollController.position.maxScrollExtent - 0.5;

  bool get _visibleImagesReady =>
      imageStates.isNotEmpty &&
      imageStates.every(
        (state) =>
            state is _ComicImageState &&
            (state._imageInfo != null || state._lastException != null),
      );

  bool scrollWithinPage({required bool forward}) {
    if (!_visibleImagesReady || _scrollController?.hasClients != true) {
      return false;
    }
    final position = scrollController.position;
    final remaining = forward
        ? position.maxScrollExtent - position.pixels
        : position.pixels - position.minScrollExtent;
    if (remaining <= 0.5) return false;
    smoothTo(
      position.viewportDimension * 0.9 * (forward ? 1 : -1),
      accelerate: false,
    );
    return true;
  }

  var isCTRLPressed = false;
  static var _isMouseScrolling = false;
  var fingers = 0;
  bool disableScroll = false;

  late List<bool> cached;

  int get preCacheCount => appdata.settings["preloadImageCount"];

  /// Whether the user was scrolling the page.
  /// The gesture detector has a delay to detect tap event.
  /// To handle the tap event, we need to know if the user was scrolling before the delay.
  bool delayedIsScrolling = false;

  var imageStates = <State<ComicImage>>{};

  void delayedSetIsScrolling(bool value) {
    Future.delayed(
      const Duration(milliseconds: 300),
      () => delayedIsScrolling = value,
    );
  }

  bool prepareToPrevChapter = false;
  bool prepareToNextChapter = false;
  bool jumpToNextChapter = false;
  bool jumpToPrevChapter = false;

  bool _swipeStartedAtChapterStart = false;
  bool _swipeStartedAtChapterEnd = false;
  bool _chapterSwipeAllowed = false;
  Offset _chapterSwipeDelta = Offset.zero;
  bool _chapterNavigationPending = false;

  void _resetChapterSwipe() {
    _chapterSwipeAllowed = false;
    _swipeStartedAtChapterStart = false;
    _swipeStartedAtChapterEnd = false;
    _chapterSwipeDelta = Offset.zero;
    jumpToNextChapter = false;
    jumpToPrevChapter = false;
  }

  double _readingDelta(Offset delta) =>
      reader.mode == ReaderMode.continuousTopToBottom
      ? -delta.dy
      : reader.mode == ReaderMode.continuousRightToLeft
      ? delta.dx
      : -delta.dx;

  void _scrollInReadingDirection(double delta) {
    if (delta == 0 || _chapterNavigationPending) return;
    final forward = delta > 0;
    if (!isZoomedIn && (forward ? isAtChapterEnd : isAtChapterStart)) {
      _chapterNavigationPending = reader.turnPage(forward: forward);
      return;
    }
    smoothTo(delta);
  }

  bool isZoomedIn = false;
  bool isLongPressing = false;

  Size? _lastViewport;
  double? _lastCrossExtent;
  bool _restoringLayout = false;
  int _layoutGeneration = 0;
  (int, double)? _resizeAnchor;

  void _preservePositionOnResize(Size viewport, double crossExtent) {
    final previous = _lastViewport;
    final previousCross = _lastCrossExtent;
    _lastViewport = viewport;
    _lastCrossExtent = crossExtent;
    if (previous == null ||
        previousCross == null ||
        (previous == viewport && previousCross == crossExtent)) {
      return;
    }
    final vertical = reader.mode == ReaderMode.continuousTopToBottom;
    final oldMain = vertical ? previous.height : previous.width;
    final newMain = vertical ? viewport.height : viewport.width;
    if (_resizeAnchor == null) {
      final page = reader.page;
      final position = itemPositionsListener.itemPositions.value
          .where((item) => item.index == page)
          .firstOrNull;
      _resizeAnchor = (
        page,
        position == null || previousCross <= 0
            ? 0.0
            : position.itemLeadingEdge * oldMain / previousCross,
      );
    }
    final (page, leadingOffset) = _resizeAnchor!;
    // Keep the same fraction of the current image above the viewport after
    // rescaling it, including rotations and adjustments made while reading.
    final alignment = newMain <= 0
        ? 0.0
        : leadingOffset * crossExtent / newMain;
    final generation = ++_layoutGeneration;
    _restoringLayout = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _layoutGeneration) return;
      if (itemScrollController.isAttached) {
        itemScrollController.jumpTo(index: page, alignment: alignment);
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && generation == _layoutGeneration) {
          _restoringLayout = false;
          _resizeAnchor = null;
        }
      });
    });
  }

  @override
  void initState() {
    reader = context.reader;
    _openingAtChapterEnd = reader._alignContinuousChapterEnd;
    reader._alignContinuousChapterEnd = false;
    reader._imageViewController = this;
    itemPositionsListener.itemPositions.addListener(onPositionChanged);
    cached = List.filled(reader.maxPage + 2, false);
    Future.delayed(
      const Duration(milliseconds: 100),
      () => cacheImages(reader.page),
    );
    super.initState();
  }

  bool _openingAtChapterEnd = false;
  bool _endAlignmentScheduled = false;

  void _alignChapterEnd() {
    if (!_openingAtChapterEnd || _endAlignmentScheduled) return;
    _endAlignmentScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _endAlignmentScheduled = false;
      if (!mounted ||
          !_openingAtChapterEnd ||
          !_visibleImagesReady ||
          _scrollController?.hasClients != true) {
        return;
      }
      // Initial placeholder extents can move the list away from its end when
      // uncached images decode. Enter the previous chapter at the decoded end.
      final position = scrollController.position;
      position.jumpTo(position.maxScrollExtent);
      _openingAtChapterEnd = false;
    });
  }

  @override
  void dispose() {
    itemPositionsListener.itemPositions.removeListener(onPositionChanged);
    super.dispose();
  }

  void onPositionChanged() {
    if (_restoringLayout || itemPositionsListener.itemPositions.value.isEmpty) {
      return;
    }
    final visible = itemPositionsListener.itemPositions.value.where(
      (item) => item.itemTrailingEdge > 0.000001 && item.itemLeadingEdge < 1,
    );
    if (visible.isEmpty) return;
    // The listener also reports cached off-screen items, in no guaranteed order.
    var page = visible.map((item) => item.index).reduce(math.min);
    page = page.clamp(1, reader.maxPage);
    if (page != reader.page) {
      reader.setPage(page);
      context.readerScaffold.update();
    }
    cacheImages(page);
  }

  double? _futurePosition;

  void smoothTo(double offset, {bool accelerate = true}) {
    if (HardwareKeyboard.instance.isShiftPressed) {
      return;
    }
    final animationEnabled = context.reader.enablePageAnimation(
      context.reader.cid,
      context.reader.type,
    );
    var currentLocation = scrollController.position.pixels;
    var old = _futurePosition;
    _futurePosition ??= currentLocation;
    double k = accelerate
        ? (_futurePosition! - currentLocation).abs() / 1600 + 1
        : 1;
    final customSpeed = appdata.settings.getReaderSetting(
      context.reader.cid,
      context.reader.type.sourceKey,
      "readerScrollSpeed",
    );
    if (accelerate && customSpeed is num) {
      k *= customSpeed;
    }
    _futurePosition = _futurePosition! + offset * k;
    var beforeOffset = (_futurePosition! - currentLocation).abs();
    _futurePosition = _futurePosition!.clamp(
      scrollController.position.minScrollExtent,
      scrollController.position.maxScrollExtent,
    );
    var afterOffset = (_futurePosition! - currentLocation).abs();
    if (_futurePosition == old) return;
    var target = _futurePosition!;
    if (!animationEnabled) {
      // Respect the reader setting for drag/trackpad scrolling as well as
      // discrete page transitions (important for e-ink devices).
      scrollController.jumpTo(target);
      _futurePosition = null;
      return;
    }
    var duration = const Duration(milliseconds: 160);
    if (afterOffset < beforeOffset) {
      duration = duration * (afterOffset / beforeOffset);
      if (duration < Duration(milliseconds: 10)) {
        duration = Duration(milliseconds: 10);
      }
    }
    scrollController
        .animateTo(_futurePosition!, duration: duration, curve: Curves.linear)
        .then((_) {
          var current = scrollController.position.pixels;
          if (current == target && current == _futurePosition) {
            _futurePosition = null;
          }
        });
  }

  void onPointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent) {
      if (!_isMouseScrolling) {
        setState(() {
          _isMouseScrolling = true;
        });
      }
      if (isCTRLPressed) {
        return;
      }
      final horizontal = reader.mode != ReaderMode.continuousTopToBottom;
      final delta =
          horizontal && event.scrollDelta.dx.abs() > event.scrollDelta.dy.abs()
          ? event.scrollDelta.dx *
                (reader.mode == ReaderMode.continuousRightToLeft ? -1 : 1)
          : event.scrollDelta.dy;
      _scrollInReadingDirection(delta);
    }
  }

  void cacheImages(int current) {
    for (int i = current + 1; i <= current + preCacheCount; i++) {
      if (i <= reader.maxPage && !cached[i]) {
        _preDownloadImage(i, context);
        cached[i] = true;
      }
    }
  }

  void onScroll() {
    if (prepareToPrevChapter) {
      jumpToNextChapter = false;
      jumpToPrevChapter =
          scrollController.offset <
          scrollController.position.minScrollExtent - _kChangeChapterOffset;
    } else if (prepareToNextChapter) {
      jumpToNextChapter =
          scrollController.offset >
          scrollController.position.maxScrollExtent + _kChangeChapterOffset;
      jumpToPrevChapter = false;
    }
  }

  bool onScaleUpdate([double? scale]) {
    if (prepareToNextChapter || prepareToPrevChapter) {
      setState(() {
        prepareToPrevChapter = false;
        prepareToNextChapter = false;
      });
      context.readerScaffold.setFloatingButton(0);
    }
    var isZoomedIn = (scale ?? photoViewController.scale) != 1.0;
    if (isZoomedIn) _resetChapterSwipe();
    if (isZoomedIn != this.isZoomedIn) {
      setState(() {
        this.isZoomedIn = isZoomedIn;
      });
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) =>
          _buildImages(context, constraints.biggest),
    );
  }

  Widget _buildImages(BuildContext context, Size viewport) {
    final margin = readerPageMargin(reader.cid, reader.type.sourceKey);
    final marginEnabled =
        appdata.settings.getReaderSetting(
          reader.cid,
          reader.type.sourceKey,
          'readerPageMarginEnabled',
        ) ==
        true;
    final imageWidth =
        !marginEnabled &&
            appdata.settings.getReaderSetting(
                  reader.cid,
                  reader.type.sourceKey,
                  'limitImageWidth',
                ) ==
                true &&
            viewport.width / viewport.height > 0.7 &&
            reader.mode == ReaderMode.continuousTopToBottom
        ? viewport.height * 0.7
        : viewport.width * (1 - margin * 2);
    final imageHeight = viewport.height * (1 - margin * 2);
    _preservePositionOnResize(
      viewport,
      reader.mode == ReaderMode.continuousTopToBottom
          ? imageWidth
          : imageHeight,
    );
    Widget widget = ScrollablePositionedList.builder(
      initialScrollIndex: reader.page,
      itemScrollController: itemScrollController,
      itemPositionsListener: itemPositionsListener,
      scrollControllerCallback: (scrollController) {
        if (_scrollController != null) {
          _scrollController!.removeListener(onScroll);
        }
        _scrollController = scrollController;
        _scrollController!.addListener(onScroll);
      },
      itemCount: reader.maxPage + 2,
      addSemanticIndexes: false,
      scrollDirection: reader.mode == ReaderMode.continuousTopToBottom
          ? Axis.vertical
          : Axis.horizontal,
      reverse: reader.mode == ReaderMode.continuousRightToLeft,
      physics: isCTRLPressed || _isMouseScrolling || disableScroll
          ? const NeverScrollableScrollPhysics()
          : isZoomedIn
          ? const ClampingScrollPhysics()
          : const BouncingScrollPhysics(),
      itemBuilder: (context, index) {
        if (index == 0 || index == reader.maxPage + 1) {
          return const SizedBox();
        }
        double? width, height;
        if (reader.mode == ReaderMode.continuousLeftToRight ||
            reader.mode == ReaderMode.continuousRightToLeft) {
          height = double.infinity;
        } else {
          width = double.infinity;
        }

        ImageProvider image = _createImageProvider(index, context);

        return ColoredBox(
          color: readerBackgroundColor(
            context,
            reader.cid,
            reader.type.sourceKey,
          ),
          child: Center(
            child: SizedBox(
              width: reader.mode == ReaderMode.continuousTopToBottom
                  ? imageWidth
                  : null,
              height: reader.mode == ReaderMode.continuousTopToBottom
                  ? null
                  : imageHeight,
              child: ComicImage(
                key: ValueKey('reader-continuous-image-$index'),
                // Bilinear filtering avoids mipmap work while large images are
                // continuously moving. Gallery mode keeps medium quality for zoom.
                filterQuality: FilterQuality.low,
                image: image,
                width: width,
                height: height,
                fit: BoxFit.contain,
                onInit: (state) => imageStates.add(state),
                onDispose: (state) => imageStates.remove(state),
                onImageReady: _alignChapterEnd,
              ),
            ),
          ),
        );
      },
      scrollBehavior: const MaterialScrollBehavior().copyWith(
        scrollbars: false,
        dragDevices: _kTouchLikeDeviceTypes,
      ),
    );

    widget = ColoredBox(
      color: readerBackgroundColor(context, reader.cid, reader.type.sourceKey),
      child: widget,
    );

    widget = Stack(
      children: [
        Positioned.fill(child: buildBackground(context)),
        Positioned.fill(child: widget),
      ],
    );

    widget = Listener(
      onPointerDown: (event) {
        _openingAtChapterEnd = false;
        fingers++;
        _resetChapterSwipe();
        if (fingers == 1 && !isZoomedIn) {
          _chapterSwipeAllowed = true;
          _swipeStartedAtChapterStart = isAtChapterStart;
          _swipeStartedAtChapterEnd = isAtChapterEnd;
        }
        if (fingers > 1 && !disableScroll) {
          setState(() {
            disableScroll = true;
          });
        }
        _futurePosition = null;
        if (_isMouseScrolling) {
          setState(() {
            _isMouseScrolling = false;
          });
        }
      },
      onPointerUp: (event) {
        fingers--;
        if (fingers <= 1 && disableScroll) {
          setState(() {
            disableScroll = false;
          });
        }
        if (fingers == 0) {
          if (!_chapterSwipeAllowed) {
            _resetChapterSwipe();
            return;
          }
          final travel = _readingDelta(_chapterSwipeDelta);
          final crossTravel = reader.mode == ReaderMode.continuousTopToBottom
              ? _chapterSwipeDelta.dx.abs()
              : _chapterSwipeDelta.dy.abs();
          final nextSwipe =
              _swipeStartedAtChapterEnd &&
              travel >= _kChapterSwipeDistance &&
              travel > crossTravel;
          final prevSwipe =
              _swipeStartedAtChapterStart &&
              -travel >= _kChapterSwipeDistance &&
              -travel > crossTravel;
          if (!isZoomedIn &&
              !_chapterNavigationPending &&
              (jumpToPrevChapter || prevSwipe) &&
              !reader.isFirstChapterOfGroup) {
            context.readerScaffold.setFloatingButton(0);
            _chapterNavigationPending = reader.toPrevChapter(toLastPage: true);
          } else if (!isZoomedIn &&
              !_chapterNavigationPending &&
              (jumpToNextChapter || nextSwipe) &&
              !reader.isLastChapterOfGroup) {
            context.readerScaffold.setFloatingButton(0);
            _chapterNavigationPending = reader.toNextChapter();
          }
          _resetChapterSwipe();
        }
      },
      onPointerCancel: (event) {
        fingers--;
        _resetChapterSwipe();
        if (fingers <= 1 && disableScroll) {
          setState(() {
            disableScroll = false;
          });
        }
      },
      onPointerPanZoomUpdate: (event) {
        if (event.scale == 1.0) {
          _scrollInReadingDirection(_readingDelta(event.panDelta));
        }
      },
      onPointerMove: (event) {
        Offset value = event.delta;
        if (fingers == 1 && !isZoomedIn) {
          _chapterSwipeDelta += value;
        }
        if (photoViewController.scale == 1 || fingers != 1) {
          return;
        }
        Offset offset;
        var sp = scrollController.position;
        if (sp.pixels <= sp.minScrollExtent ||
            sp.pixels >= sp.maxScrollExtent) {
          offset = Offset(value.dx, value.dy);
        } else {
          if (reader.mode == ReaderMode.continuousTopToBottom) {
            offset = Offset(value.dx, 0);
          } else {
            offset = Offset(0, value.dy);
          }
        }
        if (isLongPressing) {
          offset += value;
        }
        photoViewController.updateMultiple(
          position: photoViewController.position + offset,
        );
      },
      onPointerSignal: onPointerSignal,
      child: widget,
    );

    widget = NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is ScrollStartNotification) {
          delayedSetIsScrolling(true);
        } else if (notification is ScrollEndNotification) {
          delayedSetIsScrolling(false);
        }

        var scale = photoViewController.scale ?? 1.0;

        if (notification is ScrollUpdateNotification &&
            (scale - 1).abs() < 0.05) {
          if (!scrollController.hasClients) return false;
          if (scrollController.position.pixels <=
                  scrollController.position.minScrollExtent &&
              !reader.isFirstChapterOfGroup) {
            if (!prepareToPrevChapter) {
              jumpToPrevChapter = false;
              jumpToNextChapter = false;
              context.readerScaffold.setFloatingButton(-1);
              setState(() {
                prepareToPrevChapter = true;
              });
            }
          } else if (scrollController.position.pixels >=
                  scrollController.position.maxScrollExtent &&
              !reader.isLastChapterOfGroup) {
            if (!prepareToNextChapter) {
              jumpToPrevChapter = false;
              jumpToNextChapter = false;
              context.readerScaffold.setFloatingButton(1);
              setState(() {
                prepareToNextChapter = true;
              });
            }
          } else {
            context.readerScaffold.setFloatingButton(0);
            if (prepareToPrevChapter || prepareToNextChapter) {
              jumpToPrevChapter = false;
              jumpToNextChapter = false;
              setState(() {
                prepareToPrevChapter = false;
                prepareToNextChapter = false;
              });
            }
          }
        }

        return true;
      },
      child: widget,
    );
    final width = viewport.width;
    final height = viewport.height;

    return PhotoView.customChild(
      backgroundDecoration: BoxDecoration(
        color: readerBackgroundColor(
          context,
          reader.cid,
          reader.type.sourceKey,
        ),
      ),
      childSize: Size(width, height),
      minScale: 1.0,
      maxScale: 2.5,
      strictScale: true,
      controller: photoViewController,
      onScaleUpdate: onScaleUpdate,
      child: SizedBox(width: width, height: height, child: widget),
    );
  }

  Widget buildBackground(BuildContext context) {
    return Column(
      children: [
        SizedBox(height: context.padding.top + 16),
        if (prepareToPrevChapter)
          _SwipeChangeChapterProgress(
            controller: scrollController,
            isPrev: true,
          ),
        const Spacer(),
        if (prepareToNextChapter)
          _SwipeChangeChapterProgress(
            controller: scrollController,
            isPrev: false,
          ),
        SizedBox(height: 36),
      ],
    );
  }

  @override
  Future<void> animateToPage(int page) {
    return itemScrollController.scrollTo(
      index: page,
      duration: const Duration(milliseconds: 200),
      curve: Curves.ease,
    );
  }

  @override
  void handleDoubleTap(Offset location) {
    if (appdata.settings['quickCollectImage'] == 'DoubleTap') {
      context.readerScaffold.addImageFavorite();
      return;
    }
    double target;
    if (photoViewController.scale !=
        photoViewController.getInitialScale?.call()) {
      target = photoViewController.getInitialScale!.call()!;
    } else {
      target = photoViewController.getInitialScale!.call()! * 1.75;
    }
    var size = MediaQuery.of(context).size;
    photoViewController.animateScale?.call(
      target,
      Offset(size.width / 2 - location.dx, size.height / 2 - location.dy),
    );
    onScaleUpdate(target);
  }

  @override
  void handleLongPressDown(Offset location) {
    if (!appdata.settings['enableLongPressToZoom'] || delayedIsScrolling) {
      return;
    }
    double target = photoViewController.getInitialScale!.call()! * 1.75;
    var size = reader.size;
    Offset zoomPosition;
    if (appdata.settings['longPressZoomPosition'] != 'center') {
      zoomPosition = Offset(
        size.width / 2 - location.dx,
        size.height / 2 - location.dy,
      );
    } else {
      zoomPosition = Offset(0, 0);
    }
    photoViewController.animateScale?.call(target, zoomPosition);
    onScaleUpdate(target);
    isLongPressing = true;
  }

  @override
  void handleLongPressUp(Offset location) {
    if (!appdata.settings['enableLongPressToZoom']) {
      return;
    }
    double target = photoViewController.getInitialScale!.call()!;
    photoViewController.animateScale?.call(target);
    onScaleUpdate(target);
    isLongPressing = false;
  }

  @override
  void toPage(int page) {
    _openingAtChapterEnd = false;
    itemScrollController.jumpTo(index: page);
    _futurePosition = null;
  }

  @override
  void handleKeyEvent(KeyEvent event) {
    if (event.logicalKey == LogicalKeyboardKey.controlLeft ||
        event.logicalKey == LogicalKeyboardKey.controlRight) {
      setState(() {
        if (event is KeyDownEvent) {
          isCTRLPressed = true;
        } else if (event is KeyUpEvent) {
          isCTRLPressed = false;
        }
      });
    }
    if (event is KeyUpEvent) {
      return;
    }
    bool? forward;
    if (reader.mode == ReaderMode.continuousLeftToRight &&
        event.logicalKey == LogicalKeyboardKey.arrowRight) {
      forward = true;
    } else if (reader.mode == ReaderMode.continuousRightToLeft &&
        event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      forward = true;
    } else if (reader.mode == ReaderMode.continuousTopToBottom &&
        event.logicalKey == LogicalKeyboardKey.arrowDown) {
      forward = true;
    } else if (reader.mode == ReaderMode.continuousTopToBottom &&
        event.logicalKey == LogicalKeyboardKey.arrowUp) {
      forward = false;
    } else if (reader.mode == ReaderMode.continuousLeftToRight &&
        event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      forward = false;
    } else if (reader.mode == ReaderMode.continuousRightToLeft &&
        event.logicalKey == LogicalKeyboardKey.arrowRight) {
      forward = false;
    }
    if (forward != null) {
      _scrollInReadingDirection(
        scrollController.position.viewportDimension * (forward ? .25 : -.25),
      );
    }
  }

  @override
  bool handleOnTap(Offset location) {
    // A boundary can still be bouncing after a swipe/trackpad gesture. The
    // next edge tap must be able to continue reading instead of being eaten
    // by the delayed scrolling guard.
    if (delayedIsScrolling && !isAtChapterStart && !isAtChapterEnd) {
      return true;
    }
    return false;
  }

  @override
  Future<Uint8List?> getImageByOffset(Offset offset) async {
    var imageKey = getImageKeyByOffset(offset);
    if (imageKey == null) return null;
    if (imageKey.startsWith("file://")) {
      return await File(imageKey.substring(7)).readAsBytes();
    } else {
      return CacheManager().readCache(
        "$imageKey@${context.reader.type.sourceKey}@${context.reader.cid}@${context.reader.eid}",
      );
    }
  }

  @override
  String? getImageKeyByOffset(Offset offset) {
    String? imageKey;
    for (var imageState in imageStates) {
      if ((imageState as _ComicImageState).containsPoint(offset)) {
        imageKey = (imageState.widget.image as ReaderImageProvider).imageKey;
      }
    }
    return imageKey;
  }
}

ImageProvider _createImageProviderFromKey(
  String imageKey,
  BuildContext context,
  int page,
) {
  var reader = context.reader;
  return ReaderImageProvider(
    imageKey,
    reader.type.comicSource?.key,
    reader.cid,
    reader.eid,
    page,
    enableResize: reader
        .mode
        .isContinuous, // For continuous mode, we need to resize the image to improve performance
  );
}

ImageProvider _createImageProvider(int page, BuildContext context) {
  var reader = context.reader;
  var imageKey = reader.images![page - 1];
  return _createImageProviderFromKey(imageKey, context, page);
}

/// [_precacheImage] is used to precache the image for the given page.
/// The image is cached using the flutter's [precacheImage] method.
/// The image will be downloaded and decoded into memory.
void _precacheImage(int page, BuildContext context) {
  if (page <= 0 || page > context.reader.images!.length) {
    return;
  }
  precacheImage(_createImageProvider(page, context), context);
}

/// [_preDownloadImage] is used to download the image for the given page.
/// The image is downloaded using the [CacheManager] and saved to the local storage.
void _preDownloadImage(int page, BuildContext context) {
  if (page <= 0 || page > context.reader.images!.length) {
    return;
  }
  var reader = context.reader;
  var imageKey = reader.images![page - 1];
  if (imageKey.startsWith("file://")) {
    return;
  }
  var cid = reader.cid;
  var eid = reader.eid;
  var sourceKey = reader.type.comicSource?.key;
  ImageDownloader.loadComicImage(imageKey, sourceKey, cid, eid);
}

class _SwipeChangeChapterProgress extends StatefulWidget {
  const _SwipeChangeChapterProgress({this.controller, required this.isPrev});

  final ScrollController? controller;

  final bool isPrev;

  @override
  State<_SwipeChangeChapterProgress> createState() =>
      _SwipeChangeChapterProgressState();
}

class _SwipeChangeChapterProgressState
    extends State<_SwipeChangeChapterProgress> {
  double value = 0;

  late final isPrev = widget.isPrev;

  ScrollController? controller;

  @override
  void initState() {
    super.initState();
    if (widget.controller != null) {
      controller = widget.controller;
      controller!.addListener(onScroll);
    }
  }

  @override
  void didUpdateWidget(covariant _SwipeChangeChapterProgress oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      controller?.removeListener(onScroll);
      controller = widget.controller;
      controller?.addListener(onScroll);
      if (value != 0) {
        setState(() {
          value = 0;
        });
      }
    }
  }

  @override
  void dispose() {
    super.dispose();
    controller?.removeListener(onScroll);
  }

  void onScroll() {
    var position = controller!.position.pixels;
    var offset = isPrev
        ? controller!.position.minScrollExtent - position
        : position - controller!.position.maxScrollExtent;
    var newValue = offset / _kChangeChapterOffset;
    newValue = newValue.clamp(0.0, 1.0);
    if (newValue != value) {
      setState(() {
        value = newValue;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final msg = widget.isPrev
        ? "Swipe down for previous chapter".tl
        : "Swipe up for next chapter".tl;

    return CustomPaint(
      painter: _ProgressPainter(
        value: value,
        backgroundColor: context.colorScheme.surfaceContainerLow,
        color: context.colorScheme.surfaceContainerHighest,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            widget.isPrev ? Icons.arrow_downward : Icons.arrow_upward,
            color: context.colorScheme.onSurface,
            size: 16,
          ),
          const SizedBox(width: 4),
          Text(msg),
        ],
      ).paddingVertical(6).paddingHorizontal(16),
    );
  }
}

class _ProgressPainter extends CustomPainter {
  final double value;

  final Color backgroundColor;

  final Color color;

  const _ProgressPainter({
    required this.value,
    required this.backgroundColor,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = backgroundColor
      ..style = PaintingStyle.fill;
    canvas.drawRRect(
      RRect.fromLTRBR(0, 0, size.width, size.height, Radius.circular(16)),
      paint,
    );

    paint.color = color;
    canvas.drawRRect(
      RRect.fromLTRBR(
        0,
        0,
        size.width * value,
        size.height,
        Radius.circular(16),
      ),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    return oldDelegate is! _ProgressPainter ||
        oldDelegate.value != value ||
        oldDelegate.backgroundColor != backgroundColor ||
        oldDelegate.color != color;
  }
}
