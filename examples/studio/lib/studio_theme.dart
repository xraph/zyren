import 'package:flutter/material.dart';

/// Shared editor colors and compact controls, including dialogs and tool panels.
class StudioPalette {
  final bool dark;
  const StudioPalette(this.dark);
  factory StudioPalette.of(BuildContext context) =>
      StudioPalette(Theme.of(context).brightness == Brightness.dark);
  Color get chrome => Color(dark ? 0xff25272b : 0xffe9ecf0);
  Color get panel => Color(dark ? 0xff191b1e : 0xfffafbfc);
  Color get raised => Color(dark ? 0xff27292d : 0xfff0f2f5);
  Color get text => Color(dark ? 0xffdfe1e5 : 0xff242832);
  Color get muted => Color(dark ? 0xff9299a5 : 0xff626a78);
  Color get border => Color(dark ? 0xff303237 : 0xffd9dde3);
  Color get accent => Color(dark ? 0xff8aa8ff : 0xff315fbd);
  Color get selection => Color(dark ? 0xff334261 : 0xffe3ebfc);
  Color get positive => Color(dark ? 0xff9fc3ac : 0xff326745);
}

ThemeData studioTheme(Brightness brightness) {
  final p = StudioPalette(brightness == Brightness.dark);
  TextStyle type(
    double size, {
    FontWeight weight = FontWeight.w400,
    Color? color,
  }) => TextStyle(
    fontSize: size,
    height: 1.3,
    fontWeight: weight,
    color: color ?? p.text,
    letterSpacing: 0,
  );
  final button = TextButton.styleFrom(
    textStyle: type(11),
    foregroundColor: p.text,
    minimumSize: const Size(28, 28),
    padding: const EdgeInsets.symmetric(horizontal: 8),
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
  );
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    visualDensity: VisualDensity.compact,
    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    scaffoldBackgroundColor: p.chrome,
    colorScheme:
        ColorScheme.fromSeed(
          seedColor: p.accent,
          brightness: brightness,
        ).copyWith(
          surface: p.panel,
          onSurface: p.text,
          onSurfaceVariant: p.muted,
          surfaceContainerLow: p.chrome,
          surfaceContainer: p.raised,
          surfaceContainerHigh: p.raised,
          primary: p.accent,
          primaryContainer: p.selection,
          onPrimaryContainer: p.text,
          outline: p.border,
          outlineVariant: p.border,
        ),
    textTheme: TextTheme(
      displayLarge: type(24),
      displayMedium: type(22),
      displaySmall: type(20),
      headlineLarge: type(18),
      headlineMedium: type(16),
      headlineSmall: type(15),
      titleLarge: type(14, weight: FontWeight.w600),
      titleMedium: type(12, weight: FontWeight.w600),
      titleSmall: type(11, weight: FontWeight.w600),
      bodyLarge: type(12),
      bodyMedium: type(12),
      bodySmall: type(11, color: p.muted),
      labelLarge: type(11),
      labelMedium: type(11),
      labelSmall: type(10, color: p.muted),
    ),
    textButtonTheme: TextButtonThemeData(style: button),
    outlinedButtonTheme: OutlinedButtonThemeData(style: button),
    filledButtonTheme: FilledButtonThemeData(
      style: button.copyWith(
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? p.text.withValues(alpha: .12)
              : p.accent,
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? p.text.withValues(alpha: .38)
              : p.dark
              ? const Color(0xff17191c)
              : Colors.white,
        ),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: p.muted,
        iconSize: 15,
        minimumSize: const Size(28, 28),
        padding: const EdgeInsets.all(5),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      ),
    ),
    listTileTheme: ListTileThemeData(
      dense: true,
      minTileHeight: 30,
      minLeadingWidth: 16,
      horizontalTitleGap: 8,
      contentPadding: const EdgeInsets.symmetric(horizontal: 10),
      titleTextStyle: type(12),
      subtitleTextStyle: type(11, color: p.muted),
    ),
    expansionTileTheme: ExpansionTileThemeData(
      tilePadding: const EdgeInsets.symmetric(horizontal: 8),
      childrenPadding: const EdgeInsets.symmetric(horizontal: 8),
      collapsedShape: const Border(),
      shape: const Border(),
      iconColor: p.muted,
      collapsedIconColor: p.muted,
    ),
    popupMenuTheme: PopupMenuThemeData(
      textStyle: type(12),
      color: p.raised,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: p.panel,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: type(14, weight: FontWeight.w600),
      contentTextStyle: type(12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ),
    dividerTheme: DividerThemeData(color: p.border, space: 1, thickness: 1),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: p.raised,
      labelStyle: type(11, color: p.muted),
      hintStyle: type(11, color: p.muted),
      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      prefixIconConstraints: const BoxConstraints(minWidth: 28, minHeight: 28),
      suffixIconConstraints: const BoxConstraints(minWidth: 28, minHeight: 28),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(4),
        borderSide: BorderSide(color: p.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(4),
        borderSide: BorderSide(color: p.border),
      ),
    ),
    iconTheme: IconThemeData(size: 15, color: p.muted),
    tooltipTheme: TooltipThemeData(
      textStyle: type(11, color: p.dark ? Colors.black : Colors.white),
      waitDuration: const Duration(milliseconds: 450),
    ),
  );
}
