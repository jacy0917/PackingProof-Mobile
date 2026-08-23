import 'package:flutter/material.dart';

@immutable
class PackingProofSemanticColors
    extends ThemeExtension<PackingProofSemanticColors> {
  const PackingProofSemanticColors({
    required this.dangerAction,
    required this.onDangerAction,
  });

  final Color dangerAction;
  final Color onDangerAction;

  @override
  PackingProofSemanticColors copyWith({
    Color? dangerAction,
    Color? onDangerAction,
  }) => PackingProofSemanticColors(
    dangerAction: dangerAction ?? this.dangerAction,
    onDangerAction: onDangerAction ?? this.onDangerAction,
  );

  @override
  PackingProofSemanticColors lerp(
    covariant PackingProofSemanticColors? other,
    double t,
  ) {
    if (other == null) return this;
    return PackingProofSemanticColors(
      dangerAction: Color.lerp(dangerAction, other.dangerAction, t)!,
      onDangerAction: Color.lerp(onDangerAction, other.onDangerAction, t)!,
    );
  }
}

abstract final class PackingProofTheme {
  static const Color forest = Color(0xFF087454);
  static const Color ink = Color(0xFF151918);
  static const PackingProofSemanticColors semanticColors =
      PackingProofSemanticColors(
        dangerAction: Color(0xFFD92D20),
        onDangerAction: Colors.white,
      );

  static ThemeData light() => _build(Brightness.light);

  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final bool dark = brightness == Brightness.dark;
    final ColorScheme colors =
        ColorScheme.fromSeed(
          seedColor: forest,
          brightness: brightness,
        ).copyWith(
          primary: dark ? const Color(0xFF65DDB7) : forest,
          onPrimary: dark ? const Color(0xFF00382A) : Colors.white,
          surface: dark ? const Color(0xFF101412) : Colors.white,
          surfaceContainerLowest: dark ? const Color(0xFF0B0F0D) : Colors.white,
          surfaceContainerLow: dark
              ? const Color(0xFF171C19)
              : const Color(0xFFF5F6F3),
          surfaceContainer: dark
              ? const Color(0xFF1C221F)
              : const Color(0xFFF2F6F4),
          surfaceContainerHigh: dark
              ? const Color(0xFF252C28)
              : const Color(0xFFE7ECE9),
          surfaceContainerHighest: dark
              ? const Color(0xFF303833)
              : const Color(0xFFDDE3E0),
          onSurface: dark ? const Color(0xFFE4EAE6) : ink,
          onSurfaceVariant: dark
              ? const Color(0xFFBAC4BF)
              : const Color(0xFF69716E),
          outlineVariant: dark
              ? const Color(0xFF3E4944)
              : const Color(0xFFD5E0DB),
          error: dark ? const Color(0xFFFFB4AB) : const Color(0xFFC43D32),
          onError: dark ? const Color(0xFF690005) : Colors.white,
          errorContainer: dark
              ? const Color(0xFF93000A)
              : const Color(0xFFFFE5E2),
          onErrorContainer: dark
              ? const Color(0xFFFFDAD6)
              : const Color(0xFFD92D20),
        );
    final ThemeData base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: colors,
    );

    return base.copyWith(
      extensions: const <ThemeExtension<dynamic>>[semanticColors],
      scaffoldBackgroundColor: colors.surface,
      appBarTheme: AppBarTheme(
        backgroundColor: colors.surface,
        foregroundColor: colors.onSurface,
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
        elevation: 0,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: colors.surface,
        indicatorColor: colors.secondaryContainer,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: colors.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: colors.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
      ),
      searchBarTheme: SearchBarThemeData(
        backgroundColor: WidgetStatePropertyAll(colors.surfaceContainerLow),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: colors.primary,
          foregroundColor: colors.onPrimary,
          minimumSize: const Size.fromHeight(58),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          textStyle: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.2,
          ),
        ),
      ),
    );
  }
}
