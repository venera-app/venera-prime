part of 'settings_page.dart';

class AboutSettings extends StatefulWidget {
  const AboutSettings({super.key});

  @override
  State<AboutSettings> createState() => _AboutSettingsState();
}

class _AboutSettingsState extends State<AboutSettings> {
  bool isCheckingUpdate = false;

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
            ),
            const SizedBox(height: 8),
          ],
        ).toSliver(),
        ListTile(
          title: Text("Check for updates".tl),
          trailing: Button.filled(
            isLoading: isCheckingUpdate,
            child: Text("Check".tl),
            onPressed: () {
              setState(() {
                isCheckingUpdate = true;
              });
              checkUpdateUi().then((value) {
                setState(() {
                  isCheckingUpdate = false;
                });
              });
            },
          ).fixHeight(32),
        ).toSliver(),
        _SwitchSetting(
          title: "Check for updates on startup".tl,
          settingKey: "checkUpdateOnStart",
        ).toSliver(),
        ListTile(
          title: const Text("Github"),
          trailing: const Icon(Icons.open_in_new),
          onTap: () {
            launchUrlString("https://github.com/venera-app/venera-prime");
          },
        ).toSliver(),
        ListTile(
          title: const Text("Telegram"),
          trailing: const Icon(Icons.open_in_new),
          onTap: () {
            launchUrlString("https://t.me/venera_release");
          },
        ).toSliver(),
      ],
    );
  }
}

class LatestRelease {
  final String version;
  final String title;
  final String body;
  final String url;

  const LatestRelease({
    required this.version,
    required this.title,
    required this.body,
    required this.url,
  });
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
    return null;
  }
  final data = res.data!;
  final tag = data["tag_name"]?.toString();
  if (tag == null || tag.isEmpty) {
    return null;
  }
  final version = tag.replaceFirst(RegExp(r"^[vV]"), '').split('+').first;
  return LatestRelease(
    version: version,
    title: data["name"]?.toString().trim().isNotEmpty == true
        ? data["name"].toString()
        : tag,
    body: data["body"]?.toString().trim() ?? '',
    url:
        data["html_url"]?.toString() ??
        "https://github.com/venera-app/venera-prime/releases/latest",
  );
}

Future<void> checkUpdateUi([
  bool showMessageIfNoUpdate = true,
  bool delay = false,
]) async {
  try {
    var release = await checkUpdate();
    if (release != null && _compareVersion(release.version, App.version)) {
      if (delay) {
        await Future.delayed(const Duration(seconds: 2));
      }
      showDialog(
        context: App.rootContext,
        builder: (context) {
          return ContentDialog(
            title: "${release.title} (${release.version})",
            content: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    "A new version is available. Do you want to update now?".tl,
                  ),
                  if (release.body.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text(release.body),
                  ],
                ],
              ).paddingHorizontal(16),
            ),
            actions: [
              Button.text(
                onPressed: () {
                  Navigator.pop(context);
                  launchUrlString(release.url);
                },
                child: Text("Update".tl),
              ),
            ],
          );
        },
      );
    } else if (showMessageIfNoUpdate) {
      App.rootContext.showMessage(message: "No new version available".tl);
    }
  } catch (e, s) {
    Log.error("Check Update", e.toString(), s);
  }
}

/// return true if version1 > version2
bool _compareVersion(String version1, String version2) {
  var v1 = version1.split(".");
  var v2 = version2.split(".");
  for (var i = 0; i < v1.length; i++) {
    if (int.parse(v1[i]) > int.parse(v2[i])) {
      return true;
    }
    if (int.parse(v1[i]) < int.parse(v2[i])) {
      return false;
    }
  }
  return false;
}
