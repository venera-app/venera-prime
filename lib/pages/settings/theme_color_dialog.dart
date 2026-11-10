import 'package:flutter/material.dart';
import 'package:venera/foundation/theme_colors.dart';
import 'package:venera/utils/translations.dart';

class ThemeColorDialog extends StatefulWidget {
  const ThemeColorDialog({super.key, required this.initialColor});
  final Color initialColor;

  @override
  State<ThemeColorDialog> createState() => _ThemeColorDialogState();
}

class _ThemeColorDialogState extends State<ThemeColorDialog> {
  late Color color = widget.initialColor;
  late final text = TextEditingController(text: themeColorHex(color));
  bool valid = true;

  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  void setChannel(int shift, double value) {
    setState(() {
      color = Color(
        (color.toARGB32() & ~(255 << shift)) | (value.round() << shift),
      );
      text.text = themeColorHex(color);
      valid = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final preview = ColorScheme.fromSeed(
      seedColor: color,
      brightness: Theme.of(context).brightness,
    );
    return AlertDialog(
      title: Text('Custom theme color'.tl),
      content: SizedBox(
        width: 340,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: preview.primaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.palette_outlined,
                      color: preview.onPrimaryContainer,
                    ),
                    const SizedBox(width: 12),
                    Text(
                      themeColorHex(color),
                      style: TextStyle(color: preview.onPrimaryContainer),
                    ),
                    const Spacer(),
                    CircleAvatar(radius: 16, backgroundColor: color),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: text,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: 'HEX',
                  hintText: '#2196F3',
                  errorText: valid ? null : 'Enter a six-digit HEX color'.tl,
                ),
                onChanged: (value) => setState(() {
                  final parsed = parseThemeHex(value);
                  valid = parsed != null;
                  if (parsed != null) color = parsed;
                }),
              ),
              const SizedBox(height: 8),
              for (final channel in [('R', 16), ('G', 8), ('B', 0)])
                Row(
                  children: [
                    Text(channel.$1),
                    Expanded(
                      child: Slider(
                        value: ((color.toARGB32() >> channel.$2) & 255)
                            .toDouble(),
                        max: 255,
                        divisions: 255,
                        label: '${(color.toARGB32() >> channel.$2) & 255}',
                        onChanged: (value) => setChannel(channel.$2, value),
                      ),
                    ),
                    SizedBox(
                      width: 28,
                      child: Text('${(color.toARGB32() >> channel.$2) & 255}'),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('Cancel'.tl),
        ),
        FilledButton(
          onPressed: valid ? () => Navigator.pop(context, color) : null,
          child: Text('Apply'.tl),
        ),
      ],
    );
  }
}
