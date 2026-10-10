import 'package:flutter/material.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/utils/opencc.dart';

bool isAuthorNamespace(String namespace) => const {
  'author',
  'authors',
  'artist',
  'artists',
  '作者',
  '画师',
  '畫師',
  '绘师',
  '繪師',
}.contains(namespace.trim().toLowerCase());

/// Preserve source-specific author queries/category targets. Sources without a
/// tag callback can still search by the original author name.
PageJumpTarget? authorTagTarget(
  ComicSource source,
  String namespace,
  String author,
) {
  final target = source.handleClickTagEvent?.call(namespace, author);
  if (target != null) return target;
  if (!isAuthorNamespace(namespace) ||
      source.searchPageData == null ||
      author.trim().isEmpty) {
    return null;
  }
  return PageJumpTarget(source.key, 'search', {'text': author.trim()});
}

class ComicAuthorLink extends StatelessWidget {
  const ComicAuthorLink({super.key, required this.comic, this.style});

  final ComicDetails comic;
  final TextStyle? style;

  String? _authorNamespace(String author) {
    for (final entry in comic.tags.entries) {
      if (isAuthorNamespace(entry.key) &&
          entry.value.any((tag) => tag.trim() == author.trim())) {
        return entry.key;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final author = comic.subTitle ?? '';
    final source = ComicSource.find(comic.sourceKey);
    final namespace = _authorNamespace(author);
    final canSearch =
        author.trim().isNotEmpty &&
        source != null &&
        (source.searchPageData != null ||
            (namespace != null && source.handleClickTagEvent != null));
    return SelectableText(
      author.displayText,
      style: canSearch
          ? (style ?? const TextStyle()).copyWith(
              color: Theme.of(context).colorScheme.primary,
            )
          : style,
      onTap: !canSearch
          ? null
          : () {
              final target = namespace != null
                  ? authorTagTarget(source, namespace, author)
                  : PageJumpTarget(source.key, 'search', {
                      'text': author.trim(),
                    });
              target?.jump(context);
            },
    );
  }
}
