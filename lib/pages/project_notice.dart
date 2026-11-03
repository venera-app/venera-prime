import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/utils/atomic_file.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/translations.dart';

const primeTelegramUrl = 'https://t.me/+Musk77e3ahFhMjg1';
const upstreamTelegramUrl = 'https://t.me/+-Z0d_TB_Alk0YzU1';

/// Separate from appdata and backups: acknowledgement belongs to this install.
class ProjectNoticeReceipt {
  static const version = '1';
  static File get _file => File('${App.dataPath}/project-notice-receipt');

  static Future<bool> isAcknowledged() async {
    try {
      return await _file.readAsString() == version;
    } on FileSystemException {
      return false;
    } on FormatException {
      return false;
    }
  }

  static Future<void> acknowledge() => atomicWriteString(_file, version);
}

Future<void> showProjectNotice(
  BuildContext context, {
  bool acknowledgementRequired = false,
}) => showDialog<void>(
  context: context,
  barrierDismissible: !acknowledgementRequired,
  builder: (_) =>
      ProjectNoticeDialog(acknowledgementRequired: acknowledgementRequired),
);

class ProjectNoticeDialog extends StatefulWidget {
  const ProjectNoticeDialog({super.key, this.acknowledgementRequired = false});
  final bool acknowledgementRequired;

  @override
  State<ProjectNoticeDialog> createState() => _ProjectNoticeDialogState();
}

class _ProjectNoticeDialogState extends State<ProjectNoticeDialog> {
  bool _saving = false;
  String? _error;

  Future<void> _confirm() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      if (widget.acknowledgementRequired) {
        await ProjectNoticeReceipt.acknowledge();
      }
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = 'Could not save your acknowledgement. Please try again.'.tl;
        });
      }
    }
  }

  Future<void> _joinGroup() async {
    try {
      if (!await launchUrlString(
        primeTelegramUrl,
        mode: LaunchMode.externalApplication,
      )) {
        throw StateError('Could not open Telegram');
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'Could not open Telegram. Please try again.'.tl,
        );
      }
    }
  }

  Widget _section(String title, String body) => Padding(
    padding: const EdgeInsets.only(bottom: 18),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title.tl,
          style: Theme.of(
            context,
          ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 6),
        Text(
          body.tl,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.5),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !widget.acknowledgementRequired && !_saving,
    child: AlertDialog(
      scrollable: true,
      title: Text('About Venera Prime'.tl),
      content: SizedBox(
        width: 520,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _section(
              'Unofficial fork',
              'This project is independently maintained by a third party. It is not affiliated with, and does not represent, the upstream team. Its maintenance approach and release schedule differ from upstream, and the same level of quality and stability cannot be guaranteed.',
            ),
            _section(
              'Community and feedback',
              'The upstream community is already large. As this fork is maintained independently and cannot guarantee the same quality and stability as upstream, we have created a separate group for its users and feedback to avoid adding to the upstream community’s support burden.\n\nYou are welcome to join the Venera Prime Telegram group. For the upstream group, go to Settings → About.',
            ),
            _section(
              'How this project is maintained',
              'The current maintainer has experience in traditional software development. As AI capabilities improve and personal time and energy remain limited, much of this project’s repair and maintenance work is assisted by or carried out by large language models (LLMs); not all code is written by hand. Testing may still miss problems, so reproducible bug reports are welcome. Please back up your favorites, reading history, and important settings before upgrading.',
            ),
            _section(
              'Intended use',
              'This software is intended for reading your personal comic collection. JavaScript scripts can provide access to comics stored locally, on a NAS, or on other personal storage. Please ensure you have lawful access to the content and do not use this software for illegal purposes.',
            ),
            _section(
              'Contributing',
              'This repository is not currently accepting pull requests. To contribute, fork the repository and make your changes, then open an issue with a link to your branch or commits and a description of the changes to request review and merging.',
            ),
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : _joinGroup,
          child: Text('Join Telegram group'.tl),
        ),
        FilledButton(
          key: const Key('project-notice-confirm'),
          onPressed: _saving ? null : _confirm,
          child: Text(
            (widget.acknowledgementRequired
                    ? 'I understand, start using the app'
                    : 'Close')
                .tl,
          ),
        ),
      ],
    ),
  );
}
