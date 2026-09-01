// ./lib/ui_theme.dart

import 'package:flutter/material.dart';

/// Global UI scale for the control surface. Every font size, padding, and
/// control dimension in the design system multiplies through this — one
/// knob to make the whole app bigger or smaller. Hairlines stay 1px.
const double uiScale = 1.25;

/// Shorthand: scale a logical dimension.
double sc(double v) => v * uiScale;

/// R3nder's design system: a broadcast-equipment control surface that
/// inherits its accent from the currently selected phosphor color.
///
/// Everything routes through [R3Theme]: build one from the active phosphor
/// (R3Theme.of(fontColor)) and pass it down. Pick Amber in the color
/// presets and the whole UI warms to amber; pick Green and it goes green.
/// The app becomes a preview of the piece's mood.
///
/// Principles:
///  - Near-black base, panels barely lifted, separated by hairlines not fills
///  - ONE accent color, used sparingly: active states, focus, the tally badge
///  - Monospace everywhere; uppercase micro-labels with wide letterspacing
///  - Compact "mixer channel" sliders instead of full Material sliders
///  - One unmistakable hot button (BAKE); everything else stays quiet
class R3Theme {
  /// The accent — derived from the phosphor, desaturated slightly so pure
  /// #00FF00 doesn't scream against the dark surface.
  final Color accent;

  /// Dimmed accent for borders and inactive-but-themed elements.
  final Color accentDim;

  /// Barely-there accent for panel border tints and fills.
  final Color accentFaint;

  // Fixed surface stack (phosphor-independent).
  static const Color bg = Color(0xFF0C0C10); // app background
  static const Color panel = Color(0xFF13131A); // panel fill
  static const Color panelHi = Color(0xFF1A1A24); // raised: fields, hovers
  static const Color hairline = Color(0xFF26262F); // 1px separators

  // Text stack.
  static const Color textBright = Color(0xFFE8E6E3);
  static const Color textMid = Color(0xFF9C9AA6);
  static const Color textDim = Color(0xFF5C5A66);

  // Fixed signal colors (status semantics never re-tint).
  static const Color danger = Color(0xFFFF4D4D);
  static const Color warn = Color(0xFFFFB84D);
  static const Color okGreen = Color(0xFF4DFF88);

  // -------------------------------------------------------------------
  // SCRIPT RIBBON PALETTE
  //
  // The strip used to be three greys, one phosphor tint, and a hairline:
  // text was textDim, media was textMid, holds were hairline. Every block
  // therefore read as the same substance at four brightnesses, and the
  // only question it could answer at a glance was "is something here",
  // never "what kind of thing".
  //
  // These are hues instead, because the question worth answering while
  // scanning a timeline is what KIND of time each stretch is. Brightness
  // is reserved for selection, which _brighten in script_ribbon.dart
  // applies by scaling channels proportionally, so a lifted block is the
  // same hue and louder. Encoding both identity and state in brightness is
  // what made the old strip unreadable.
  //
  // Only the text band is phosphor-derived, and deliberately so: typed
  // characters ARE the phosphor. Everything else is either not the
  // terminal (the simulated desktop), not text (in-terminal stencils), or
  // not output at all (dead air), so a fixed hue keeps it distinct no
  // matter what the phosphor is set to. Amber phosphor must not collapse
  // the media band into the text band.
  //
  // All sit well below the warning colours. A ribbon is a map, not an
  // alarm.
  // -------------------------------------------------------------------

  /// Desktop presentations: GALLERY, VIDEO, APP, CARD, DOSSIER, TIMELINE.
  /// Steel blue, reading as window chrome rather than as terminal output,
  /// which is exactly what these are.
  static const Color ribbonWindow = Color(0xFF3F76A8);

  /// In-terminal stencils: IMG, PHOTO, SVG, SVGFLASH, SPRITE. On the
  /// terminal surface but not typed, so adjacent to the phosphor family
  /// without being in it.
  static const Color ribbonMedia = Color(0xFF7A56A6);

  /// A [PAUSE]: the script deliberately doing nothing. Muted red, so a
  /// stretch of dead air is findable at a glance without ever reading as
  /// [danger], which it is not.
  static const Color deadAir = Color(0xFF8C3A48);

  /// A [WIPE]. A hold, but an event rather than a span: it clears and
  /// moves on. Kept near-neutral so it reads as a seam between blocks
  /// instead of competing with them.
  static const Color ribbonSeam = Color(0xFF30303C);

  static const List<String> monoStack = [
    'monospace', 'Courier', 'Consolas', 'Courier New',
  ];

  R3Theme._(this.accent, this.accentDim, this.accentFaint);

  /// Builds the theme from the active phosphor color. Pure function —
  /// cheap enough to call in every build().
  factory R3Theme.of(Color phosphor) {
    // Pull saturation and brightness in slightly so neon phosphors read
    // as an accent, not a glare. White phosphor gets a neutral warm accent.
    final HSLColor hsl = HSLColor.fromColor(phosphor);
    final HSLColor tuned = hsl.saturation < 0.05
        ? const HSLColor.fromAHSL(1.0, 36, 0.12, 0.72) // white -> warm grey
        : hsl
            .withSaturation((hsl.saturation * 0.75).clamp(0.0, 1.0))
            .withLightness(hsl.lightness.clamp(0.45, 0.62));
    final Color accent = tuned.toColor();
    return R3Theme._(
      accent,
      accent.withValues(alpha: 0.55),
      accent.withValues(alpha: 0.16),
    );
  }

  // -------------------------------------------------------------------
  // Text styles (all sizes scale through uiScale)
  // -------------------------------------------------------------------

  /// Uppercase micro-label: section names, field captions.
  TextStyle get micro => TextStyle(
        fontFamily: 'monospace',
        fontFamilyFallback: monoStack,
        fontSize: sc(10.5),
        letterSpacing: sc(2.2),
        fontWeight: FontWeight.bold,
        color: textDim,
      );

  /// The accent-colored variant of [micro] for active sections.
  TextStyle get microAccent => micro.copyWith(color: accentDim);

  /// Body / value text.
  TextStyle get value => TextStyle(
        fontFamily: 'monospace',
        fontFamilyFallback: monoStack,
        fontSize: sc(13.5),
        color: textBright,
        fontWeight: FontWeight.w600,
      );

  TextStyle get valueDim => value.copyWith(color: textMid);

  /// Small annotation text (paths, hints).
  TextStyle get fine => TextStyle(
        fontFamily: 'monospace',
        fontFamilyFallback: monoStack,
        fontSize: sc(11),
        color: textDim,
      );

  /// The app title / screen headers.
  TextStyle get header => TextStyle(
        fontFamily: 'monospace',
        fontFamilyFallback: monoStack,
        fontSize: sc(22),
        letterSpacing: sc(3),
        fontWeight: FontWeight.bold,
        color: textBright.withValues(alpha: 0.95),
      );

  // -------------------------------------------------------------------
  // Material ThemeData bridge — keeps dialogs, snackbars, text fields,
  // chips, and anything we don't hand-roll on-system.
  // -------------------------------------------------------------------

  /// Multiplies every font size in [t] by [factor], leaving styles that
  /// have no size alone.
  ///
  /// REPLACES TextTheme.apply(fontSizeFactor:), which asserts.
  ///
  /// Some styles in ThemeData.dark().textTheme carry a null fontSize, and
  /// TextStyle.apply asserts when a factor is supplied against one. The
  /// assertion is a warning rather than a defect report: at runtime apply
  /// does `fontSize == null ? null : fontSize * factor`, so a null size
  /// passes through untouched and the factor is silently ignored for that
  /// style. Flutter would rather tell you than let it pass unnoticed.
  ///
  /// Which is why this only ever showed up under `flutter run`. Asserts
  /// are compiled out of release builds, so every release has been doing
  /// exactly what the code below now does explicitly, and only a debug run
  /// stops to complain about it.
  static TextTheme _scaleFontSizes(TextTheme t, double factor) {
    if (factor == 1.0) return t;

    TextStyle? s(TextStyle? style) {
      final double? size = style?.fontSize;
      if (style == null || size == null) return style;
      return style.copyWith(fontSize: size * factor);
    }

    return TextTheme(
      displayLarge: s(t.displayLarge),
      displayMedium: s(t.displayMedium),
      displaySmall: s(t.displaySmall),
      headlineLarge: s(t.headlineLarge),
      headlineMedium: s(t.headlineMedium),
      headlineSmall: s(t.headlineSmall),
      titleLarge: s(t.titleLarge),
      titleMedium: s(t.titleMedium),
      titleSmall: s(t.titleSmall),
      bodyLarge: s(t.bodyLarge),
      bodyMedium: s(t.bodyMedium),
      bodySmall: s(t.bodySmall),
      labelLarge: s(t.labelLarge),
      labelMedium: s(t.labelMedium),
      labelSmall: s(t.labelSmall),
    );
  }

  ThemeData materialTheme() {
    final base = ThemeData.dark();
    return base.copyWith(
      scaffoldBackgroundColor: bg,
      colorScheme: base.colorScheme.copyWith(
        primary: accent,
        secondary: accent,
        surface: panel,
        error: danger,
      ),
      textTheme: _scaleFontSizes(
        base.textTheme.apply(
          fontFamily: 'monospace',
          bodyColor: textBright,
          displayColor: textBright,
        ),
        uiScale,
      ),
      dialogTheme: base.dialogTheme.copyWith(
        backgroundColor: panel,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
          side: const BorderSide(color: hairline),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
          borderSide: const BorderSide(color: hairline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
          borderSide: const BorderSide(color: hairline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
          borderSide: BorderSide(color: accentDim),
        ),
        labelStyle: fine,
        hintStyle: fine,
        fillColor: panelHi,
        filled: true,
        contentPadding: EdgeInsets.symmetric(
            horizontal: sc(12), vertical: sc(12)),
      ),
      snackBarTheme: base.snackBarTheme.copyWith(
        backgroundColor: panelHi,
        contentTextStyle: value,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(4),
          side: const BorderSide(color: hairline),
        ),
      ),
      chipTheme: base.chipTheme.copyWith(
        backgroundColor: panelHi,
        selectedColor: accentFaint,
        labelStyle: fine.copyWith(color: textMid),
        secondaryLabelStyle: fine.copyWith(color: accent),
        side: const BorderSide(color: hairline),
        padding: EdgeInsets.symmetric(horizontal: sc(8), vertical: sc(4)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(3)),
      ),
      sliderTheme: base.sliderTheme.copyWith(
        activeTrackColor: accentDim,
        inactiveTrackColor: hairline,
        thumbColor: accent,
        trackHeight: 2,
        overlayShape: RoundSliderOverlayShape(overlayRadius: sc(12)),
        thumbShape: RoundSliderThumbShape(enabledThumbRadius: sc(6)),
      ),
    );
  }
}

// -----------------------------------------------------------------------
// Panels & labels
// -----------------------------------------------------------------------

/// A surface panel: barely-lifted fill, hairline border, optional
/// micro-label header row (with optional trailing widget on that row).
class R3Panel extends StatelessWidget {
  final R3Theme theme;
  final String? label;
  final Widget? trailing;
  final Widget child;
  final EdgeInsets? padding;
  final bool accentBorder;

  const R3Panel({
    super.key,
    required this.theme,
    required this.child,
    this.label,
    this.trailing,
    this.padding,
    this.accentBorder = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding ?? EdgeInsets.all(sc(14)),
      decoration: BoxDecoration(
        color: R3Theme.panel,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(
          color: accentBorder ? theme.accentFaint : R3Theme.hairline,
        ),
      ),
      child: label == null
          ? child
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Text(label!.toUpperCase(), style: theme.micro),
                    if (trailing != null) ...[
                      const Spacer(),
                      trailing!,
                    ],
                  ],
                ),
                SizedBox(height: sc(10)),
                child,
              ],
            ),
    );
  }
}

/// Standalone micro-label for use outside panels.
class R3MicroLabel extends StatelessWidget {
  final R3Theme theme;
  final String text;
  final bool accent;

  const R3MicroLabel(this.text,
      {super.key, required this.theme, this.accent = false});

  @override
  Widget build(BuildContext context) {
    return Text(text.toUpperCase(),
        style: accent ? theme.microAccent : theme.micro);
  }
}

// -----------------------------------------------------------------------
// Mixer-channel slider: label left, live value right, thin track under.
// Horizontal drag anywhere on the row adjusts; a third the height of a
// Material slider and reads like broadcast gear.
// -----------------------------------------------------------------------

class R3Slider extends StatelessWidget {
  final R3Theme theme;
  final String label;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;

  /// Value formatting; defaults to integer display.
  final String Function(double v)? format;

  const R3Slider({
    super.key,
    required this.theme,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.format,
  });

  @override
  Widget build(BuildContext context) {
    final double t = ((value - min) / (max - min)).clamp(0.0, 1.0);
    final String display = format?.call(value) ?? value.toInt().toString();

    return LayoutBuilder(builder: (ctx, constraints) {
      final double w = constraints.maxWidth;

      void setFromDx(double dx) {
        final double nt = (dx / w).clamp(0.0, 1.0);
        onChanged(min + nt * (max - min));
      }

      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (d) => setFromDx(d.localPosition.dx),
        onTapDown: (d) => setFromDx(d.localPosition.dx),
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: sc(7)),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Text(label.toUpperCase(), style: theme.micro),
                  const Spacer(),
                  Text(display, style: theme.value),
                ],
              ),
              SizedBox(height: sc(6)),
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(height: 2, color: R3Theme.hairline),
                  FractionallySizedBox(
                    widthFactor: t == 0 ? 0.001 : t,
                    child: Container(height: 2, color: theme.accentDim),
                  ),
                  // Thumb tick.
                  Positioned(
                    left: (t * w - 1).clamp(0.0, w - 2),
                    top: sc(-3),
                    child: Container(
                      width: 2,
                      height: sc(8),
                      color: theme.accent,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    });
  }
}

// -----------------------------------------------------------------------
// Buttons
// -----------------------------------------------------------------------

enum R3ButtonKind {
  /// Quiet outlined action (most buttons).
  normal,

  /// Accent-tinted primary (LIVE PREVIEW).
  primary,

  /// The one unmistakable hot button (BAKE).
  hot,
}

class R3Button extends StatelessWidget {
  final R3Theme theme;
  final String label;
  final VoidCallback? onPressed;
  final R3ButtonKind kind;
  final Widget? badge;
  final bool compact;

  const R3Button(
    this.label, {
    super.key,
    required this.theme,
    required this.onPressed,
    this.kind = R3ButtonKind.normal,
    this.badge,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final bool disabled = onPressed == null;

    Color border;
    Color fill;
    Color text;

    switch (kind) {
      case R3ButtonKind.normal:
        border = R3Theme.hairline;
        fill = Colors.transparent;
        text = R3Theme.textMid;
        break;
      case R3ButtonKind.primary:
        border = theme.accentDim;
        fill = theme.accentFaint;
        text = theme.accent;
        break;
      case R3ButtonKind.hot:
        border = R3Theme.danger.withValues(alpha: 0.7);
        fill = R3Theme.danger.withValues(alpha: 0.12);
        text = R3Theme.danger;
        break;
    }

    if (disabled) {
      border = R3Theme.hairline;
      fill = Colors.transparent;
      text = R3Theme.textDim;
    }

    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(4),
      child: Container(
        padding: compact
            ? EdgeInsets.symmetric(horizontal: sc(14), vertical: sc(8))
            : EdgeInsets.symmetric(horizontal: sc(24), vertical: sc(16)),
        decoration: BoxDecoration(
          color: fill,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label.toUpperCase(),
              style: TextStyle(
                fontFamily: 'monospace',
                fontFamilyFallback: R3Theme.monoStack,
                fontSize: compact ? sc(11.5) : sc(12.5),
                letterSpacing: sc(1.8),
                fontWeight: FontWeight.bold,
                color: text,
              ),
            ),
            if (badge != null) ...[
              SizedBox(width: sc(8)),
              badge!,
            ],
          ],
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------
// Status badge (tally light)
// -----------------------------------------------------------------------

enum R3TallyState { ok, warn, error, off }

class R3Tally extends StatelessWidget {
  final R3TallyState state;
  final String? count;

  const R3Tally({super.key, required this.state, this.count});

  @override
  Widget build(BuildContext context) {
    Color c;
    switch (state) {
      case R3TallyState.ok:
        c = R3Theme.okGreen;
        break;
      case R3TallyState.warn:
        c = R3Theme.warn;
        break;
      case R3TallyState.error:
        c = R3Theme.danger;
        break;
      case R3TallyState.off:
        c = R3Theme.textDim;
        break;
    }

    if (count != null) {
      return Container(
        padding: EdgeInsets.symmetric(horizontal: sc(7), vertical: sc(2)),
        decoration: BoxDecoration(
          color: c.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(3),
          border: Border.all(color: c.withValues(alpha: 0.6)),
        ),
        child: Text(
          count!,
          style: TextStyle(
            fontFamily: 'monospace',
            fontFamilyFallback: R3Theme.monoStack,
            fontSize: sc(11),
            fontWeight: FontWeight.bold,
            color: c,
          ),
        ),
      );
    }

    return Container(
      width: sc(8),
      height: sc(8),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: c,
        boxShadow: [
          BoxShadow(color: c.withValues(alpha: 0.5), blurRadius: sc(6)),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------
// Stepper row: < value > selector (documents, fonts)
// -----------------------------------------------------------------------

class R3Stepper extends StatelessWidget {
  final R3Theme theme;
  final String label;
  final String value;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;

  const R3Stepper({
    super.key,
    required this.theme,
    required this.label,
    required this.value,
    required this.onPrev,
    required this.onNext,
  });

  Widget _arrow(IconData icon, VoidCallback? onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(3),
      child: Padding(
        padding: EdgeInsets.all(sc(4)),
        child: Icon(icon, size: sc(14),
            color: onTap == null ? R3Theme.textDim : R3Theme.textMid),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: sc(88),
          child: Text(label.toUpperCase(), style: theme.micro),
        ),
        _arrow(Icons.chevron_left, onPrev),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
            style: theme.value,
          ),
        ),
        _arrow(Icons.chevron_right, onNext),
      ],
    );
  }
}

// -----------------------------------------------------------------------
// Dropdown row: < label  [ value v ] >
// -----------------------------------------------------------------------

class R3Dropdown<T> extends StatelessWidget {
  final R3Theme theme;
  final String label;
  final T? value;
  final List<T> items;
  final String Function(T) itemLabel;
  final ValueChanged<T?> onChanged;

  const R3Dropdown({
    super.key,
    required this.theme,
    required this.label,
    required this.value,
    required this.items,
    required this.itemLabel,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    // Failsafe: Ensure the value actually exists in the items list to prevent 
    // Material DropdownButton from throwing assertion crashes when lists dynamically update.
    final T? safeValue = items.contains(value) ? value : (items.isNotEmpty ? items.first : null);

    return Row(
      children: [
        SizedBox(
          width: sc(88), // Matches R3Stepper label width perfectly
          child: Text(label.toUpperCase(), style: theme.micro),
        ),
        Expanded(
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: sc(8), vertical: sc(4)),
            decoration: BoxDecoration(
              color: R3Theme.panelHi,
              borderRadius: BorderRadius.circular(3),
              border: Border.all(color: R3Theme.hairline),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<T>(
                value: safeValue,
                dropdownColor: R3Theme.panelHi, // Matches the dark UI
                icon: Icon(Icons.arrow_drop_down, color: R3Theme.textMid, size: sc(18)),
                isExpanded: true,
                isDense: true,
                style: theme.value,
                focusColor: Colors.transparent, // Prevents default material highlight
                onChanged: items.isEmpty ? null : onChanged,
                items: items.map((T item) {
                  return DropdownMenuItem<T>(
                    value: item,
                    child: Text(
                      itemLabel(item),
                      style: theme.value,
                      overflow: TextOverflow.ellipsis, // Keep it constrained
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
        ),
      ],
    );
  }
}