// ./lib/app_info.dart

import 'package:flutter/material.dart';

import 'ui_theme.dart';

// =====================================================================
// APP IDENTITY
// =====================================================================

const String kAppName = 'R3nder';
const String kAppTagline = 'Terminal Engine';

/// Displayed version. Keep in step with `version:` in pubspec.yaml.
const String kAppVersion = '1.0.0';

const String kAppAuthor = 'Nathaniel Westveer';
const String kAppCopyrightYear = '2026';
const String kAppLicense = 'MIT License';

/// Short form for the menu header, next to the title.
const String kVersionLabel = 'v$kAppVersion';

/// About dialog.
///
/// Deliberately factual rather than promotional. The one thing it is
/// careful about is dependencies: R3nder leans on FFmpeg heavily and on
/// two Dart packages, and an About box that implied otherwise would be
/// the sort of small dishonesty that is easy to write and annoying to
/// discover.
Future<void> showAboutR3nder(BuildContext context, R3Theme theme) {
  final t = theme;

  Widget line(String label, String value) => Padding(
        padding: EdgeInsets.only(bottom: sc(6)),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: sc(86), child: R3MicroLabel(label, theme: t)),
            Expanded(child: Text(value, style: t.value)),
          ],
        ),
      );

  Widget bullet(String text) => Padding(
        padding: EdgeInsets.only(bottom: sc(6)),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: EdgeInsets.only(top: sc(5), right: sc(9)),
              child: Container(
                width: sc(3),
                height: sc(3),
                color: t.accentDim,
              ),
            ),
            Expanded(child: Text(text, style: t.fine.copyWith(height: 1.45))),
          ],
        ),
      );

  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: R3Theme.panel,
      title: Row(
        children: [
          Text(kAppName.toUpperCase(), style: t.header),
          SizedBox(width: sc(12)),
          Container(width: 1, height: sc(20), color: R3Theme.hairline),
          SizedBox(width: sc(12)),
          R3MicroLabel(kVersionLabel, theme: t, accent: true),
        ],
      ),
      content: SizedBox(
        width: sc(460),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'A motion graphics tool for terminal sequences.',
              style: t.fine.copyWith(height: 1.5),
            ),
            SizedBox(height: sc(18)),
            Divider(color: R3Theme.hairline, height: sc(1)),
            SizedBox(height: sc(16)),

            // Version is in the title bar, so no line for it here.
            line('AUTHOR', kAppAuthor),
            line('LICENSE', '$kAppLicense, (c) $kAppCopyrightYear'),
            line('PLATFORM', 'Linux desktop, Flutter'),

            SizedBox(height: sc(12)),
            Divider(color: R3Theme.hairline, height: sc(1)),
            SizedBox(height: sc(14)),

            // Kept as its own section, trimmed to three lines. Credit where
            // it is due, and an About box that let you think FFmpeg ships in
            // the box would be a small dishonesty that only surfaces on a
            // machine that does not have it.
            R3MicroLabel('BUILT ON', theme: t),
            SizedBox(height: sc(10)),
            bullet('FFmpeg and ffprobe, invoked as external processes. '
                'Not bundled.'),
            bullet('Flutter, plus window_manager and cupertino_icons.'),
            bullet('Everything else first-party: the tag grammar, the SVG '
                'parser, the terminal rasterizer, the desktop window '
                'manager, and the export pipeline.'),
          ],
        ),
      ),
      actions: [
        R3Button('Close',
            theme: t,
            compact: true,
            kind: R3ButtonKind.primary,
            onPressed: () => Navigator.pop(ctx)),
      ],
    ),
  );
}