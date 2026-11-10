part of 'settings_page.dart';

class AppearanceSettings extends StatefulWidget {
  const AppearanceSettings({super.key});

  @override
  State<AppearanceSettings> createState() => _AppearanceSettingsState();
}

class _AppearanceSettingsState extends State<AppearanceSettings> {
  Future<void> editColor() async {
    final color = await showDialog<Color>(
      context: context,
      builder: (_) => ThemeColorDialog(
        initialColor: resolveThemeColor(
          'custom',
          appdata.settings['customThemeColor'],
        ),
      ),
    );
    if (color == null || !mounted) return;
    appdata.settings['customThemeColor'] = color.toARGB32();
    appdata.settings['color'] = 'custom';
    await appdata.saveData();
    if (!mounted) return;
    setState(() {});
    App.forceRebuild();
  }

  @override
  Widget build(BuildContext context) {
    return SmoothCustomScrollView(
      slivers: [
        SliverAppbar(title: Text("Appearance".tl)),
        ListTile(
          leading: const Icon(Icons.dashboard_customize_outlined),
          title: Text('Customize home'.tl),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.to(() => const HomeLayoutPage()),
        ).toSliver(),
        SelectSetting(
          title: "Theme Mode".tl,
          settingKey: "theme_mode",
          optionTranslation: {
            "system": "System".tl,
            "light": "Light".tl,
            "dark": "Dark".tl,
          },
          onChanged: () async {
            App.forceRebuild();
          },
        ).toSliver(),
        SelectSetting(
          title: "Theme Color".tl,
          settingKey: "color",
          optionTranslation: {
            "system": "System".tl,
            "red": "Red".tl,
            "pink": "Pink".tl,
            "purple": "Purple".tl,
            "green": "Green".tl,
            "orange": "Orange".tl,
            "blue": "Blue".tl,
            "deepPurple": "Deep purple".tl,
            "indigo": "Indigo".tl,
            "lightBlue": "Light blue".tl,
            "cyan": "Cyan".tl,
            "teal": "Teal".tl,
            "lightGreen": "Light green".tl,
            "lime": "Lime".tl,
            "yellow": "Yellow".tl,
            "amber": "Amber".tl,
            "deepOrange": "Deep orange".tl,
            "brown": "Brown".tl,
            "blueGrey": "Blue grey".tl,
            "custom": "Custom".tl,
          },
          onChanged: () async {
            setState(() {});
            App.forceRebuild();
          },
        ).toSliver(),
        ListTile(
          leading: CircleAvatar(
            radius: 14,
            backgroundColor: resolveThemeColor(
              'custom',
              appdata.settings['customThemeColor'],
            ),
          ),
          title: Text('Custom theme color'.tl),
          subtitle: Text(
            themeColorHex(
              resolveThemeColor('custom', appdata.settings['customThemeColor']),
            ),
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: editColor,
        ).toSliver(),
      ],
    );
  }
}
