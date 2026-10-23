import 'package:flutter/material.dart';

/// FastDrop 的视觉系统。
///
/// 设计取向：**安静、隐藏、克制**——扁平 + 细边框，不做阴影堆叠，
/// 不用装饰性彩色阴影。层级只靠字号、字重与间距表达。
///
/// 语义令牌与电脑端 `fastdrop-desktop/web/src/desktop.css` 的 `:root`
/// 保持**同名同值**（--surface / --border / --text-primary / --accent …），
/// 两端视觉才不会各走一路。
class AppTheme {
  AppTheme._();

  // ---------------------------------------------------------------------------
  // 圆角：只允许三档 + 圆形
  // ---------------------------------------------------------------------------
  static const double radiusCard = 12;
  static const double radiusControl = 10;
  static const double radiusPill = 999;

  // ---------------------------------------------------------------------------
  // 语义色令牌 —— 浅色值（深色值见 _darkTokens）
  // ---------------------------------------------------------------------------
  static const surface = Color(0xFFFFFFFF);
  static const surfaceMuted = Color(0xFFF6F7FB);
  static const surfaceSunken = Color(0xFFF1F3F8);

  static const border = Color(0xFFE4E7EF);
  static const borderStrong = Color(0xFFD2D7E2);

  static const textPrimary = Color(0xFF171A23);
  static const textSecondary = Color(0xFF596275);
  static const textTertiary = Color(0xFF747E91);
  static const textDisabled = Color(0xFFA7AFBF);

  static const primary = Color(0xFF4F6EF7);
  static const primaryDark = Color(0xFF3F5EE8);
  static const primaryLight = Color(0xFFEEF1FF);

  static const success = Color(0xFF1D8A5B);
  static const successSoft = Color(0xFFEDF9F3);
  static const danger = Color(0xFFD23B42);
  static const dangerSoft = Color(0xFFFFF0F1);
  static const warning = Color(0xFFB86D00);
  static const warningSoft = Color(0xFFFFF7E8);

  /// 页面底色（浅色）。界面请优先用 `Theme.of(context).scaffoldBackgroundColor`。
  static const pageBackground = surfaceMuted;

  /// 深色令牌。与 `desktop.css` 的 `prefers-color-scheme: dark` 一一对应。
  static const _darkSurface = Color(0xFF16181D);
  static const _darkSurfaceMuted = Color(0xFF101216);
  static const _darkSurfaceSunken = Color(0xFF1C1F26);
  static const _darkBorder = Color(0xFF272B33);
  static const _darkBorderStrong = Color(0xFF343943);
  static const _darkTextPrimary = Color(0xFFE6E8EE);
  static const _darkTextSecondary = Color(0xFFA2A9B8);
  static const _darkTextTertiary = Color(0xFF7C8494);
  static const _darkTextDisabled = Color(0xFF565D6B);
  static const _darkPrimary = Color(0xFF7C93FF);
  static const _darkPrimaryHover = Color(0xFF93A6FF);
  static const _darkPrimarySoft = Color(0xFF1E2436);
  static const _darkSuccess = Color(0xFF3ECF8E);
  static const _darkSuccessSoft = Color(0xFF16301F);
  static const _darkDanger = Color(0xFFFF6B70);
  static const _darkDangerSoft = Color(0xFF33191B);
  static const _darkWarning = Color(0xFFE0A04A);
  static const _darkWarningSoft = Color(0xFF33240F);

  // ---------------------------------------------------------------------------
  // 公开入口
  // ---------------------------------------------------------------------------
  static ThemeData get light => _build(
        brightness: Brightness.light,
        scheme: const ColorScheme.light(
          primary: primary,
          onPrimary: Colors.white,
          primaryContainer: primaryLight,
          onPrimaryContainer: Color(0xFF2F42A2),
          secondary: primaryDark,
          onSecondary: Colors.white,
          surface: surface,
          onSurface: textPrimary,
          onSurfaceVariant: textSecondary,
          surfaceContainerHighest: surfaceSunken,
          error: danger,
          onError: Colors.white,
          outline: border,
          outlineVariant: borderStrong,
        ),
      );

  static ThemeData get dark => _build(
        brightness: Brightness.dark,
        scheme: const ColorScheme.dark(
          primary: _darkPrimary,
          onPrimary: Color(0xFF12141A),
          primaryContainer: _darkPrimarySoft,
          onPrimaryContainer: Color(0xFFC9D2FF),
          secondary: _darkPrimaryHover,
          onSecondary: Color(0xFF12141A),
          surface: _darkSurface,
          onSurface: _darkTextPrimary,
          onSurfaceVariant: _darkTextSecondary,
          surfaceContainerHighest: _darkSurfaceSunken,
          error: _darkDanger,
          onError: Color(0xFF12141A),
          outline: _darkBorder,
          outlineVariant: _darkBorderStrong,
        ),
      );

  // ---------------------------------------------------------------------------
  // 单一构造函数：两套主题共用，避免浅色改了深色忘改
  // ---------------------------------------------------------------------------
  static ThemeData _build({
    required Brightness brightness,
    required ColorScheme scheme,
  }) {
    final isDark = brightness == Brightness.dark;

    final bg = isDark ? _darkSurfaceMuted : surfaceMuted;
    final surfaceColor = isDark ? _darkSurface : surface;
    final sunkenColor = isDark ? _darkSurfaceSunken : surfaceSunken;
    final borderColor = isDark ? _darkBorder : border;
    final borderStrongColor = isDark ? _darkBorderStrong : borderStrong;
    final tPrimary = isDark ? _darkTextPrimary : textPrimary;
    final tSecondary = isDark ? _darkTextSecondary : textSecondary;
    final tTertiary = isDark ? _darkTextTertiary : textTertiary;
    final tDisabled = isDark ? _darkTextDisabled : textDisabled;
    final primaryColor = isDark ? _darkPrimary : primaryDark;

    TextStyle t(double size, double height, FontWeight weight, Color color) =>
        TextStyle(
          fontSize: size,
          height: height,
          fontWeight: weight,
          color: color,
        );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: bg,
      canvasColor: surfaceColor,
      fontFamily: 'Roboto',
      // 卡片：扁平 + 细边框，不用阴影（"安静"的核心）
      cardTheme: CardThemeData(
        elevation: 0,
        color: surfaceColor,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusCard),
          side: BorderSide(color: borderColor),
        ),
      ),
      textTheme: TextTheme(
        headlineSmall: t(24, 1.25, FontWeight.w700, tPrimary),
        titleLarge: t(20, 1.3, FontWeight.w700, tPrimary),
        titleMedium: t(16, 1.4, FontWeight.w600, tPrimary),
        titleSmall: t(14, 1.45, FontWeight.w600, tPrimary),
        bodyLarge: t(16, 1.5, FontWeight.w400, tPrimary),
        bodyMedium: t(14, 1.5, FontWeight.w400, tPrimary),
        bodySmall: t(12, 1.55, FontWeight.w400, tSecondary),
        labelSmall: t(11, 1.45, FontWeight.w500, tTertiary),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: bg,
        foregroundColor: tPrimary,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: tPrimary,
          fontSize: 20,
          fontWeight: FontWeight.w700,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          elevation: 0,
          shadowColor: Colors.transparent,
          backgroundColor: primaryColor,
          foregroundColor: isDark ? const Color(0xFF12141A) : Colors.white,
          disabledBackgroundColor: sunkenColor,
          disabledForegroundColor: tDisabled,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusControl),
          ),
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: primaryColor,
          side: BorderSide(
            color: isDark ? _darkBorderStrong : const Color(0xFFBEC9FF),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusControl),
          ),
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: primaryColor),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: sunkenColor,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        hintStyle: TextStyle(color: tTertiary, fontSize: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusControl),
          borderSide: BorderSide(color: borderColor),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusControl),
          borderSide: BorderSide(color: borderColor),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusControl),
          borderSide: BorderSide(color: scheme.primary, width: 1.5),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 72,
        elevation: 0,
        backgroundColor: surfaceColor,
        indicatorColor: isDark ? _darkPrimarySoft : primaryLight,
        surfaceTintColor: Colors.transparent,
        labelTextStyle: WidgetStateProperty.resolveWith((states) => TextStyle(
              fontSize: 12,
              fontWeight: states.contains(WidgetState.selected)
                  ? FontWeight.w600
                  : FontWeight.w500,
              color: states.contains(WidgetState.selected)
                  ? scheme.primary
                  : tSecondary,
            )),
        iconTheme: WidgetStateProperty.resolveWith((states) => IconThemeData(
              size: 22,
              color: states.contains(WidgetState.selected)
                  ? scheme.primary
                  : tSecondary,
            )),
      ),
      dividerTheme: DividerThemeData(color: borderColor, thickness: 1, space: 1),
      dividerColor: borderColor,
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: isDark ? sunkenColor : const Color(0xFF292F3D),
        contentTextStyle: TextStyle(
          color: isDark ? _darkTextPrimary : Colors.white,
          fontSize: 14,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusControl),
        ),
      ),
      dialogTheme: DialogThemeData(
        elevation: 0,
        backgroundColor: surfaceColor,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusCard),
          side: BorderSide(color: borderColor),
        ),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: tSecondary,
        textColor: tPrimary,
      ),
      // 语义色扩展（供业务代码取用，避免再硬编码）
      extensions: <ThemeExtension<dynamic>>[
        FastDropTokens(
          success: isDark ? _darkSuccess : success,
          successSoft: isDark ? _darkSuccessSoft : successSoft,
          danger: isDark ? _darkDanger : danger,
          dangerSoft: isDark ? _darkDangerSoft : dangerSoft,
          warning: isDark ? _darkWarning : warning,
          warningSoft: isDark ? _darkWarningSoft : warningSoft,
          textTertiary: tTertiary,
          borderStrong: borderStrongColor,
        ),
      ],
    );
  }
}

/// 主题扩展：给业务代码一个**跟随深浅色**的语义色入口。
///
/// 用法：`Theme.of(context).extension<FastDropTokens>()!.success`
/// 取代以前直接写 `AppTheme.success`（静态色不随主题变化，是深色模式的主要障碍）。
@immutable
class FastDropTokens extends ThemeExtension<FastDropTokens> {
  const FastDropTokens({
    required this.success,
    required this.successSoft,
    required this.danger,
    required this.dangerSoft,
    required this.warning,
    required this.warningSoft,
    required this.textTertiary,
    required this.borderStrong,
  });

  final Color success;
  final Color successSoft;
  final Color danger;
  final Color dangerSoft;
  final Color warning;
  final Color warningSoft;
  final Color textTertiary;
  final Color borderStrong;

  @override
  FastDropTokens copyWith({
    Color? success,
    Color? successSoft,
    Color? danger,
    Color? dangerSoft,
    Color? warning,
    Color? warningSoft,
    Color? textTertiary,
    Color? borderStrong,
  }) {
    return FastDropTokens(
      success: success ?? this.success,
      successSoft: successSoft ?? this.successSoft,
      danger: danger ?? this.danger,
      dangerSoft: dangerSoft ?? this.dangerSoft,
      warning: warning ?? this.warning,
      warningSoft: warningSoft ?? this.warningSoft,
      textTertiary: textTertiary ?? this.textTertiary,
      borderStrong: borderStrong ?? this.borderStrong,
    );
  }

  @override
  FastDropTokens lerp(FastDropTokens? other, double t) {
    if (other == null) return this;
    return FastDropTokens(
      success: Color.lerp(success, other.success, t)!,
      successSoft: Color.lerp(successSoft, other.successSoft, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      dangerSoft: Color.lerp(dangerSoft, other.dangerSoft, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      warningSoft: Color.lerp(warningSoft, other.warningSoft, t)!,
      textTertiary: Color.lerp(textTertiary, other.textTertiary, t)!,
      borderStrong: Color.lerp(borderStrong, other.borderStrong, t)!,
    );
  }
}
