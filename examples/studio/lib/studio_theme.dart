import 'package:flutter/material.dart';

/// Semantic colors shared by the mock workspace and settings.
class StudioPalette {
  final bool dark;
  const StudioPalette(this.dark);
  factory StudioPalette.of(BuildContext context) =>
      StudioPalette(Theme.of(context).brightness == Brightness.dark);
  Color get chrome => Color(dark ? 0xff1e1f22 : 0xffedf0f3);
  Color get panel => Color(dark ? 0xff25262a : 0xffffffff);
  Color get raised => Color(dark ? 0xff2b2d30 : 0xfff3f5f7);
  Color get text => Color(dark ? 0xffdfe1e5 : 0xff242832);
  Color get muted => Color(dark ? 0xff9299a5 : 0xff626a78);
  Color get border => Color(dark ? 0xff34363b : 0xffd7dce3);
  Color get accent => Color(dark ? 0xff8aa8ff : 0xff315fbd);
  Color get selection => Color(dark ? 0xff334261 : 0xffe3ebfc);
  Color get positive => Color(dark ? 0xff9fc3ac : 0xff326745);
}

ThemeData studioTheme(Brightness brightness) {
  final p = StudioPalette(brightness == Brightness.dark);
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    visualDensity: VisualDensity.compact,
    scaffoldBackgroundColor: p.panel,
    colorScheme: ColorScheme.fromSeed(
      seedColor: p.accent,
      brightness: brightness,
      surface: p.panel,
    ),
    textTheme: TextTheme(
      bodyMedium: TextStyle(fontSize: 13, color: p.text),
      bodySmall: TextStyle(fontSize: 11, color: p.muted),
      titleMedium: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: p.text,
      ),
      titleSmall: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: p.text,
      ),
    ),
    dividerTheme: DividerThemeData(color: p.border, space: 1, thickness: 1),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: p.raised,
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(5),
        borderSide: BorderSide(color: p.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(5),
        borderSide: BorderSide(color: p.border),
      ),
    ),
    iconTheme: IconThemeData(size: 17, color: p.muted),
    tooltipTheme: const TooltipThemeData(
      waitDuration: Duration(milliseconds: 450),
    ),
  );
}
