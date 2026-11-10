import 'package:flutter/material.dart';

const themeColors = <String, Color>{
  'red': Colors.red,
  'pink': Colors.pink,
  'purple': Colors.purple,
  'deepPurple': Colors.deepPurple,
  'indigo': Colors.indigo,
  'blue': Colors.blue,
  'lightBlue': Colors.lightBlue,
  'cyan': Colors.cyan,
  'teal': Colors.teal,
  'green': Colors.green,
  'lightGreen': Colors.lightGreen,
  'lime': Colors.lime,
  'yellow': Colors.yellow,
  'amber': Colors.amber,
  'orange': Colors.orange,
  'deepOrange': Colors.deepOrange,
  'brown': Colors.brown,
  'blueGrey': Colors.blueGrey,
};

Color resolveThemeColor(Object? name, Object? custom) {
  if (name == 'custom' &&
      custom is int &&
      custom >= 0 &&
      custom <= 0xffffffff) {
    return Color(custom | 0xff000000);
  }
  return themeColors[name] ?? Colors.blue;
}

Color? parseThemeHex(String text) {
  final hex = text.trim().replaceFirst(RegExp(r'^#'), '');
  if (!RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(hex)) return null;
  return Color(0xff000000 | int.parse(hex, radix: 16));
}

String themeColorHex(Color color) =>
    '#${(color.toARGB32() & 0xffffff).toRadixString(16).padLeft(6, '0').toUpperCase()}';
