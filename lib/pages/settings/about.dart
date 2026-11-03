part of 'settings_page.dart';

class AboutSettings extends StatefulWidget {
  const AboutSettings({super.key});

  @override
  State<AboutSettings> createState() => _AboutSettingsState();
}

class _AboutSettingsState extends State<AboutSettings> {
  @override
  Widget build(BuildContext context) {
    return SmoothCustomScrollView(
      slivers: [
        SliverAppbar(title: Text("About".tl)),
        SizedBox(
          height: 112,
          width: double.infinity,
          child: Center(
            child: Container(
              width: 112,
              height: 112,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(136),
              ),
              clipBehavior: Clip.antiAlias,
              child: const Image(
                image: AssetImage("assets/app_icon.png"),
                filterQuality: FilterQuality.medium,
              ),
            ),
          ),
        ).paddingTop(16).toSliver(),
        Column(
          children: [
            const SizedBox(height: 8),
            Text("V${App.version}", style: const TextStyle(fontSize: 16)),
            Text(
              "Venera Prime is a free and open-source app for comic reading."
                  .tl,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
          ],
        ).paddingHorizontal(24).toSliver(),
        ListenableBuilder(
          listenable: BackgroundTasks.instance,
          builder: (context, _) {
            final task = BackgroundTasks.instance.latest('app-update-check');
            final hasUpdate =
                task?.status == BackgroundTaskStatus.completed &&
                task?.onOpenResult != null;
            return ListTile(
              title: Text("Check for updates".tl),
              subtitle: hasUpdate
                  ? Text('New version available'.tl)
                  : const TaskStatusText(taskKey: 'app-update-check'),
              trailing: Button.filled(
                child: Text(
                  task?.isRunning == true
                      ? "Checking".tl
                      : hasUpdate
                      ? "View update".tl
                      : "Check".tl,
                ),
                onPressed: hasUpdate
                    ? task!.onOpenResult!
                    : () => checkUpdateUi(),
              ).fixHeight(32),
            );
          },
        ).toSliver(),
        _SwitchSetting(
          title: "Check for updates on startup".tl,
          settingKey: "checkUpdateOnStart",
        ).toSliver(),
        ListTile(
          title: Text('Project notice'.tl),
          leading: const Icon(Icons.info_outline),
          onTap: () => showProjectNotice(context),
        ).toSliver(),
        ListTile(
          title: const Text("GitHub"),
          trailing: const Icon(Icons.open_in_new),
          onTap: () {
            launchUrlString("https://github.com/venera-app/venera-prime");
          },
        ).toSliver(),
        ListTile(
          title: Text("Venera Prime Telegram group".tl),
          trailing: const Icon(Icons.open_in_new),
          onTap: () {
            launchUrlString(primeTelegramUrl);
          },
        ).toSliver(),
        ListTile(
          title: Text('Upstream project Telegram group'.tl),
          subtitle: Text(
            'Upstream community, not this fork’s support group'.tl,
          ),
          trailing: const Icon(Icons.open_in_new),
          onTap: () => launchUrlString(upstreamTelegramUrl),
        ).toSliver(),
      ],
    );
  }
}

Future<LatestRelease?> checkUpdate() async {
  const url =
      "https://api.github.com/repos/venera-app/venera-prime/releases/latest";
  final res = await AppDio().get<Map<String, dynamic>>(
    url,
    options: Options(
      headers: {"Accept": "application/vnd.github+json", "cache-time": "no"},
      responseType: ResponseType.json,
    ),
  );
  if (res.statusCode != 200 || res.data == null) {
    throw StateError('Release request failed: ${res.statusCode}');
  }
  return LatestRelease.fromJson(res.data!);
}

Future<LatestRelease?> startAppUpdateCheck({
  Future<LatestRelease?> Function()? fetch,
}) => BackgroundTasks.instance.run<LatestRelease?>(
  'app-update-check',
  "Check for updates".tl,
  (task) async {
    final release = await (fetch ?? checkUpdate)();
    if (release == null) {
      throw const FormatException('Invalid release response');
    }
    if (isNewerAppVersion(release.version, App.version)) {
      task.update(message: '${release.title} (${release.version})');
      task.resultLabel = "View update".tl;
      task.onOpenResult = () => showAppUpdateDialog(release);
    } else {
      task.update(message: "No new version available".tl);
    }
    return release;
  },
);

bool _appUpdateDialogOpen = false;

Future<void> showAppUpdateDialog(LatestRelease release) async {
  if (_appUpdateDialogOpen) return;
  _appUpdateDialogOpen = true;
  try {
    await showDialog<void>(
      context: App.rootContext,
      builder: (_) => _AppUpdateDialog(release: release),
    );
  } finally {
    _appUpdateDialogOpen = false;
  }
}

Future<void> checkUpdateUi([
  bool showMessageIfNoUpdate = true,
  bool delay = false,
]) async {
  final future = startAppUpdateCheck();
  if (showMessageIfNoUpdate) {
    // Closing/minimizing this dialog never cancels the owned job.
    unawaited(
      showBackgroundTask(
        App.rootContext,
        BackgroundTasks.instance.latest('app-update-check')!,
        openResultOnCompletion: true,
      ),
    );
  }
  try {
    final release = await future;
    // Startup notifies separately; manual checks open results only while their
    // progress dialog is visible, keeping dismissed checks in the task center.
    if (!showMessageIfNoUpdate &&
        release != null &&
        isNewerAppVersion(release.version, App.version)) {
      if (delay) await Future<void>.delayed(const Duration(seconds: 2));
      showAppUpdateDialog(release);
    }
  } catch (error, stack) {
    Log.error('Check Update', error, stack);
  }
}
