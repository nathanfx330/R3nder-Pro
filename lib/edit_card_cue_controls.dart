// ./lib/edit_card_cue_controls.dart
//
// GUI authoring controls for clip-local CARD-family cues in the EDIT inspector.
//
// This widget owns only transient form state. Every durable change is returned
// to EditSurface as a CardRequest and is serialized into the canonical CLIP
// source by edit_cue_authoring.dart. SideCardRequest is a CardRequest subtype,
// so the existing inspector/history seam remains one source-backed path.

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'card_overlay.dart';
import 'card_overlay_state.dart';
import 'edit_cue.dart';
import 'edit_surface_model.dart';
import 'presentation_panel_content.dart';
import 'presentation_requests.dart';
import 'ui_theme.dart';

typedef EditCardCueChanged = void Function(int cueIndex, CardRequest card);

class EditCardCueControls extends StatefulWidget {
  const EditCardCueControls({
    super.key,
    required this.clip,
    required this.cues,
    required this.playheadFrame,
    required this.theme,
    required this.imageOptions,
    this.resolveSource,
    required this.onAddAtPlayhead,
    required this.onChanged,
    required this.onDeleted,
  });

  final EditSurfaceClip clip;
  final List<EditCardCue> cues;
  final int playheadFrame;
  final R3Theme theme;

  /// Returns workspace-relative image paths when the author opens a CARD form.
  /// The directory is scanned on demand rather than on every EDIT rebuild.
  final List<String> Function()? imageOptions;

  /// Resolves workspace-relative media for the real-painter card preview.
  /// Production supplies the same resolver used by structural preview/BAKE.
  final String Function(String source)? resolveSource;

  /// Null while playback is running or when the playhead is outside the CLIP.
  final ValueChanged<CardRequest>? onAddAtPlayhead;
  final EditCardCueChanged? onChanged;
  final ValueChanged<int>? onDeleted;

  @override
  State<EditCardCueControls> createState() => _EditCardCueControlsState();
}

class _EditCardCueControlsState extends State<EditCardCueControls> {
  static const List<String> _fontChoices = <String>[
    '',
    'sans-serif',
    'serif',
    'monospace',
    'DejaVu Sans',
    'DejaVu Serif',
    'DejaVu Sans Mono',
  ];

  static String _displayNumber(double value) {
    final int rounded = value.round();
    if ((value - rounded).abs() < 0.000001) return '$rounded';
    return value.toStringAsFixed(1);
  }

  int? get _playheadSourceFrame {
    final int frame = widget.playheadFrame;
    if (frame < widget.clip.atFrame || frame >= widget.clip.endFrameExclusive) {
      return null;
    }
    return widget.clip.clip.sourceFrameAtProjectOffset(frame - widget.clip.atFrame);
  }

  Future<CardRequest?> _editCard({
    required int sourceFrame,
    CardRequest? existing,
  }) async {
    final List<String> images = <String>{
      ...?widget.imageOptions?.call(),
      if (existing != null && existing.image.trim().isNotEmpty)
        existing.image.trim(),
    }.toList()
      ..sort();

    final int argb = existing?.panelColor.toARGB32() ?? 0xFF1E1E26;
    final int red = (argb >> 16) & 0xFF;
    final int green = (argb >> 8) & 0xFF;
    final int blue = argb & 0xFF;
    final PresentationPanelContent panel = parsePresentationPanelContent(
      heading: existing?.heading ?? '',
      body: existing?.body ?? '',
    );

    bool sideDraft = existing is SideCardRequest;
    String imageDraft = existing?.image ?? (images.isEmpty ? '' : images.first);
    String holdDraft = '${existing?.holdFrames ?? 90}';
    String rgbDraft = '$red,$green,$blue';
    String headingDraft = existing?.heading ?? '';
    PresentationPanelPreset presetDraft =
        existing == null ? PresentationPanelPreset.editorial : panel.preset;
    bool kickerFollowsPresetDefault = panel.kicker.trim().isEmpty;
    String kickerDraft = kickerFollowsPresetDefault
        ? presentationPanelDefaultKicker(presetDraft)
        : panel.kicker;
    String fontDraft = panel.fontFamily;
    String headingSizeDraft = existing == null
        ? '32'
        : (panel.headingSize == null ? '' : _displayNumber(panel.headingSize!));
    String bodySizeDraft = existing == null
        ? '17'
        : (panel.bodySize == null ? '' : _displayNumber(panel.bodySize!));
    String imagePercentDraft = existing == null
        ? '38'
        : (panel.imageFraction == null
            ? ''
            : _displayNumber(panel.imageFraction! * 100.0));
    String subtitleDraft = panel.subtitle;
    String metadataDraft = panel.metadata
        .map((PresentationPanelMetadata item) => '${item.label} | ${item.value}')
        .join('\n');
    String bodyDraft = panel.hasErrors ? '' : panel.body;
    final List<String> preservedPanelDirectives = panel.preservedDirectives;

    return showDialog<CardRequest>(
      context: context,
      builder: (BuildContext dialogContext) {
        return _CardDialogFocusScope(
          builder: (
            BuildContext context,
            FocusNode kickerFocus,
            FocusNode headingFocus,
            FocusNode bodyFocus,
          ) {
            String? errorText;

            return StatefulBuilder(
              builder: (
                BuildContext context,
                void Function(VoidCallback fn) setDialogState,
              ) {
            List<PresentationPanelMetadata>? parseMetadataDraft() {
              final List<PresentationPanelMetadata> out =
                  <PresentationPanelMetadata>[];
              final String normalized = metadataDraft
                  .replaceAll('\r\n', '\n')
                  .replaceAll('\r', '\n');
              for (final String rawLine in normalized.split('\n')) {
                final String line = rawLine.trim();
                if (line.isEmpty) continue;
                final int pipe = line.indexOf('|');
                if (pipe <= 0 || pipe >= line.length - 1) return null;
                final String label = line.substring(0, pipe).trim();
                final String value = line.substring(pipe + 1).trim();
                if (label.isEmpty || value.isEmpty) return null;
                out.add(PresentationPanelMetadata(label: label, value: value));
              }
              return out;
            }

            double? previewNumber(
              String raw, {
              required double min,
              required double max,
            }) {
              final String clean = raw.trim();
              if (clean.isEmpty) return null;
              final double? value = double.tryParse(clean);
              if (value == null || !value.isFinite || value < min || value > max) {
                return null;
              }
              return value;
            }

            Color previewPanelColor() {
              final List<int?> values = rgbDraft
                  .split(',')
                  .map((String value) => int.tryParse(value.trim()))
                  .toList(growable: false);
              if (values.length != 3 ||
                  values.any((int? value) =>
                      value == null || value < 0 || value > 255)) {
                return existing?.panelColor ?? const Color(0xFF1E1E26);
              }
              return Color.fromARGB(255, values[0]!, values[1]!, values[2]!);
            }

            CardRequest previewCard() {
              if (panel.hasErrors && existing != null) return existing;

              final List<PresentationPanelMetadata> metadata =
                  parseMetadataDraft() ?? const <PresentationPanelMetadata>[];
              final String cleanKicker = kickerDraft.trim();
              final String authoredKicker =
                  cleanKicker == presentationPanelDefaultKicker(presetDraft)
                      ? ''
                      : cleanKicker;
              final double? imagePercent = previewNumber(
                imagePercentDraft,
                min: 1,
                max: 100,
              );
              final String previewBody = formatPresentationPanelBody(
                preset: presetDraft,
                kicker: authoredKicker,
                fontFamily: fontDraft,
                headingSize: previewNumber(
                  headingSizeDraft,
                  min: 1,
                  max: 200,
                ),
                bodySize: previewNumber(
                  bodySizeDraft,
                  min: 1,
                  max: 200,
                ),
                imageFraction:
                    imagePercent == null ? null : imagePercent / 100.0,
                subtitle: subtitleDraft,
                metadata: metadata,
                preservedDirectives: preservedPanelDirectives,
                body: bodyDraft,
              );
              final CardRequest card = sideDraft
                  ? SideCardRequest(
                      image: imageDraft.trim(),
                      holdFrames: int.tryParse(holdDraft.trim()) ?? 0,
                      panelColor: previewPanelColor(),
                      heading: headingDraft.trim(),
                      body: previewBody,
                    )
                  : CardRequest(
                      image: imageDraft.trim(),
                      holdFrames: int.tryParse(holdDraft.trim()) ?? 0,
                      panelColor: previewPanelColor(),
                      heading: headingDraft.trim(),
                      body: previewBody,
                    );
              return card;
            }

            void apply() {
              final String imageValue = imageDraft.trim();
              final int? holdFrames = int.tryParse(holdDraft.trim());
              final List<String> channels = rgbDraft
                  .split(',')
                  .map((String value) => value.trim())
                  .toList(growable: false);
              final List<int?> parsed = channels
                  .map((String value) => int.tryParse(value))
                  .toList(growable: false);
              final List<PresentationPanelMetadata>? metadata =
                  parseMetadataDraft();
              final String cleanHeadingSize = headingSizeDraft.trim();
              final String cleanBodySize = bodySizeDraft.trim();
              final String cleanImagePercent = imagePercentDraft.trim();
              final double? headingSize = cleanHeadingSize.isEmpty
                  ? null
                  : double.tryParse(cleanHeadingSize);
              final double? bodySize = cleanBodySize.isEmpty
                  ? null
                  : double.tryParse(cleanBodySize);
              final double? imagePercent = cleanImagePercent.isEmpty
                  ? null
                  : double.tryParse(cleanImagePercent);

              String? problem;
              if (panel.hasErrors) {
                problem = 'This CARD has malformed PANEL source. Fix the script warning before editing it here.';
              } else if (imageValue.isEmpty ||
                  imageValue.contains(':') ||
                  imageValue.contains(']') ||
                  imageValue.contains('\n') ||
                  imageValue.contains('\r')) {
                problem = 'Choose one image path from the workspace images folder.';
              } else if (holdFrames == null || holdFrames < 0) {
                problem = 'Hold must be zero or more frames.';
              } else if (channels.length != 3 ||
                  parsed.length != 3 ||
                  parsed.any((int? value) =>
                      value == null || value < 0 || value > 255)) {
                problem = 'Color must be r,g,b with values from 0 to 255.';
              } else if (headingDraft.contains(':') ||
                  headingDraft.contains(']') ||
                  headingDraft.contains('\n') ||
                  headingDraft.contains('\r')) {
                problem = 'Heading cannot contain colon, ] or a newline.';
              } else if (kickerDraft.contains('\n') ||
                  kickerDraft.contains('\r')) {
                problem = 'Top label must stay on one line.';
              } else if (fontDraft.contains('\n') || fontDraft.contains('\r')) {
                problem = 'Font family must stay on one line.';
              } else if (headingSize != null &&
                  (!headingSize.isFinite ||
                      headingSize < 8.0 ||
                      headingSize > 96.0)) {
                problem = 'Heading size must be 8–96 reference units.';
              } else if (cleanHeadingSize.isNotEmpty && headingSize == null) {
                problem = 'Heading size must be a number or left blank.';
              } else if (bodySize != null &&
                  (!bodySize.isFinite || bodySize < 8.0 || bodySize > 72.0)) {
                problem = 'Body size must be 8–72 reference units.';
              } else if (cleanBodySize.isNotEmpty && bodySize == null) {
                problem = 'Body size must be a number or left blank.';
              } else if (imagePercent != null &&
                  (!imagePercent.isFinite ||
                      imagePercent < 25.0 ||
                      imagePercent > 55.0)) {
                problem = 'Image height must be 25–55 percent.';
              } else if (cleanImagePercent.isNotEmpty && imagePercent == null) {
                problem = 'Image height must be a percentage number or left blank.';
              } else if (subtitleDraft.contains('\n') ||
                  subtitleDraft.contains('\r')) {
                problem = 'Subtitle must stay on one line.';
              } else if (metadata == null) {
                problem = 'Metadata must use one LABEL | VALUE pair per line.';
              } else if (bodyDraft.contains('[/CARD]') ||
                  bodyDraft.contains('[/SIDECARD]')) {
                problem = 'Body cannot contain a CARD-family closing tag.';
              } else if (bodyDraft.contains('[PANEL]') ||
                  bodyDraft.contains('[/PANEL]')) {
                problem = 'The PANEL block is owned by these fields, not Body.';
              }

              if (problem != null) {
                setDialogState(() => errorText = problem);
                return;
              }

              final String cleanKicker = kickerDraft.trim();
              final String authoredKicker =
                  cleanKicker == presentationPanelDefaultKicker(presetDraft)
                      ? ''
                      : cleanKicker;
              final String authoredBody = formatPresentationPanelBody(
                preset: presetDraft,
                kicker: authoredKicker,
                fontFamily: fontDraft,
                headingSize: headingSize,
                bodySize: bodySize,
                imageFraction:
                    imagePercent == null ? null : imagePercent / 100.0,
                subtitle: subtitleDraft,
                metadata: metadata!,
                preservedDirectives: preservedPanelDirectives,
                body: bodyDraft,
              );
              final Color panelColor = Color.fromARGB(
                255,
                parsed[0]!,
                parsed[1]!,
                parsed[2]!,
              );
              final CardRequest next = sideDraft
                  ? SideCardRequest(
                      image: imageValue,
                      holdFrames: holdFrames!,
                      panelColor: panelColor,
                      heading: headingDraft.trim(),
                      body: authoredBody,
                    )
                  : CardRequest(
                      image: imageValue,
                      holdFrames: holdFrames!,
                      panelColor: panelColor,
                      heading: headingDraft.trim(),
                      body: authoredBody,
                    );
              Navigator.of(dialogContext).pop(next);
            }

            Widget menuShell({
              required Widget child,
              double? width,
            }) {
              return SizedBox(
                width: width,
                child: Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: sc(9),
                    vertical: sc(7),
                  ),
                  decoration: BoxDecoration(
                    color: R3Theme.bg,
                    border: Border.all(color: R3Theme.hairline),
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: child,
                ),
              );
            }

            return AlertDialog(
              backgroundColor: R3Theme.panel,
              title: Text(
                existing == null
                    ? 'Add CARD cue · source F$sourceFrame'
                    : 'Edit CARD cue · source F$sourceFrame',
                style: widget.theme.value,
              ),
              content: SizedBox(
                width: sc(560),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _CardFacePreview(
                        card: previewCard(),
                        resolveSource: widget.resolveSource,
                        onKickerTap: () => kickerFocus.requestFocus(),
                        onHeadingTap: () => headingFocus.requestFocus(),
                        onBodyTap: () => bodyFocus.requestFocus(),
                      ),
                      SizedBox(height: sc(14)),
                      if (errorText != null) ...[
                        Text(
                          errorText!,
                          key: const ValueKey<String>('edit-card-cue-error'),
                          style: widget.theme.fine.copyWith(
                            color: R3Theme.danger,
                          ),
                        ),
                        SizedBox(height: sc(10)),
                      ],
                      Text('CONTENT', style: widget.theme.microAccent),
                      SizedBox(height: sc(7)),
                      Row(
                        children: [
                          Expanded(
                            child: PopupMenuButton<bool>(
                              key: const ValueKey<String>(
                                'edit-card-cue-style-menu',
                              ),
                              tooltip: 'Card presentation style',
                              color: R3Theme.panelHi,
                              onSelected: (bool value) {
                                setDialogState(() {
                                  sideDraft = value;
                                  errorText = null;
                                });
                              },
                              itemBuilder: (_) => const <PopupMenuEntry<bool>>[
                                PopupMenuItem<bool>(
                                  value: false,
                                  child: Text('FULLSCREEN CARD'),
                                ),
                                PopupMenuItem<bool>(
                                  value: true,
                                  child: Text('SIDE CARD + VIDEO WINDOW'),
                                ),
                              ],
                              child: menuShell(
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        sideDraft
                                            ? 'SIDE CARD + VIDEO WINDOW'
                                            : 'FULLSCREEN CARD',
                                        key: const ValueKey<String>(
                                          'edit-card-cue-style-value',
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: widget.theme.micro.copyWith(
                                          color: R3Theme.textBright,
                                        ),
                                      ),
                                    ),
                                    const Icon(
                                      Icons.arrow_drop_down,
                                      size: 15,
                                      color: R3Theme.textDim,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: sc(8)),
                      Row(
                        children: [
                          Expanded(
                            child: KeyedSubtree(
                              key: ValueKey<String>(
                                'edit-card-cue-image-draft:$imageDraft',
                              ),
                              child: TextFormField(
                                key: const ValueKey<String>(
                                  'edit-card-cue-image-field',
                                ),
                                initialValue: imageDraft,
                                decoration: const InputDecoration(
                                  labelText: 'Hero image',
                                  hintText: 'images/ subject',
                                ),
                                style: widget.theme.value,
                                onChanged: (String value) {
                                  setDialogState(() {
                                    imageDraft = value;
                                    errorText = null;
                                  });
                                },
                              ),
                            ),
                          ),
                          SizedBox(width: sc(8)),
                          PopupMenuButton<String>(
                            key: const ValueKey<String>(
                              'edit-card-cue-image-menu',
                            ),
                            enabled: images.isNotEmpty,
                            tooltip: 'Choose workspace image',
                            color: R3Theme.panelHi,
                            onSelected: (String value) {
                              setDialogState(() {
                                imageDraft = value;
                                errorText = null;
                              });
                            },
                            itemBuilder: (_) => images
                                .map(
                                  (String value) => PopupMenuItem<String>(
                                    value: value,
                                    child: Text(value),
                                  ),
                                )
                                .toList(growable: false),
                            child: Container(
                              padding: EdgeInsets.symmetric(
                                horizontal: sc(10),
                                vertical: sc(11),
                              ),
                              decoration: BoxDecoration(
                                color: R3Theme.bg,
                                border: Border.all(color: R3Theme.hairline),
                                borderRadius: BorderRadius.circular(3),
                              ),
                              child: const Icon(
                                Icons.image_outlined,
                                size: 18,
                                color: R3Theme.textMid,
                              ),
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: sc(8)),
                      KeyedSubtree(
                        key: ValueKey<String>(
                          'edit-card-cue-kicker-draft:$kickerDraft',
                        ),
                        child: TextFormField(
                          key: const ValueKey<String>(
                            'edit-card-cue-kicker-field',
                          ),
                          focusNode: kickerFocus,
                          initialValue: kickerDraft,
                          enabled: !panel.hasErrors,
                          decoration: const InputDecoration(
                            labelText: 'Kicker / category',
                            helperText:
                                'EDITORIAL places this below the image, above the heading.',
                          ),
                          style: widget.theme.value,
                          onChanged: (String value) {
                            setDialogState(() {
                              kickerDraft = value;
                              final String clean = value.trim();
                              kickerFollowsPresetDefault = clean.isEmpty ||
                                  clean ==
                                      presentationPanelDefaultKicker(
                                        presetDraft,
                                      );
                              errorText = null;
                            });
                          },
                        ),
                      ),
                      SizedBox(height: sc(8)),
                      TextFormField(
                        key: const ValueKey<String>(
                          'edit-card-cue-heading-field',
                        ),
                        focusNode: headingFocus,
                        initialValue: headingDraft,
                        decoration: const InputDecoration(
                          labelText: 'Heading',
                        ),
                        style: widget.theme.value,
                        onChanged: (String value) {
                          setDialogState(() {
                            headingDraft = value;
                            errorText = null;
                          });
                        },
                      ),
                      SizedBox(height: sc(8)),
                      TextFormField(
                        key: const ValueKey<String>(
                          'edit-card-cue-subtitle-field',
                        ),
                        initialValue: subtitleDraft,
                        enabled: !panel.hasErrors,
                        decoration: const InputDecoration(
                          labelText: 'Subtitle / role (optional)',
                        ),
                        style: widget.theme.value,
                        onChanged: (String value) {
                          setDialogState(() {
                            subtitleDraft = value;
                            errorText = null;
                          });
                        },
                      ),
                      SizedBox(height: sc(8)),
                      TextFormField(
                        key: const ValueKey<String>(
                          'edit-card-cue-metadata-field',
                        ),
                        initialValue: metadataDraft,
                        enabled: !panel.hasErrors,
                        minLines: 1,
                        maxLines: 4,
                        decoration: const InputDecoration(
                          labelText: 'Metadata (optional)',
                          hintText:
                              'ORGANIZATION | Example News\nLOCATION | Washington, DC',
                          helperText: 'One LABEL | VALUE pair per line.',
                          alignLabelWithHint: true,
                        ),
                        style: widget.theme.value,
                        onChanged: (String value) {
                          setDialogState(() {
                            metadataDraft = value;
                            errorText = null;
                          });
                        },
                      ),
                      SizedBox(height: sc(8)),
                      TextFormField(
                        key: const ValueKey<String>('edit-card-cue-body-field'),
                        focusNode: bodyFocus,
                        initialValue: bodyDraft,
                        enabled: !panel.hasErrors,
                        minLines: 4,
                        maxLines: 8,
                        decoration: const InputDecoration(
                          labelText: 'Body',
                          hintText: 'Write the editorial copy here.',
                          alignLabelWithHint: true,
                        ),
                        style: widget.theme.value,
                        onChanged: (String value) {
                          setDialogState(() {
                            bodyDraft = value;
                            errorText = null;
                          });
                        },
                      ),
                      if (panel.hasWarnings) ...[
                        SizedBox(height: sc(6)),
                        Text(
                          'Unknown PANEL directives will be preserved unchanged.',
                          key: const ValueKey<String>(
                            'edit-card-cue-panel-warning',
                          ),
                          style: widget.theme.fine.copyWith(
                            color: R3Theme.warn,
                          ),
                        ),
                      ],
                      if (panel.hasErrors) ...[
                        SizedBox(height: sc(6)),
                        Text(
                          'This PANEL is malformed. Fix the script warning first; the GUI will not rewrite it.',
                          key: const ValueKey<String>(
                            'edit-card-cue-panel-error',
                          ),
                          style: widget.theme.fine.copyWith(
                            color: R3Theme.danger,
                          ),
                        ),
                      ],
                      SizedBox(height: sc(16)),
                      Text('TYPE', style: widget.theme.microAccent),
                      SizedBox(height: sc(7)),
                      Row(
                        children: [
                          Expanded(
                            child: PopupMenuButton<PresentationPanelPreset>(
                              key: const ValueKey<String>(
                                'edit-card-cue-preset-menu',
                              ),
                              tooltip: 'Panel presentation preset',
                              color: R3Theme.panelHi,
                              onSelected: panel.hasErrors
                                  ? null
                                  : (PresentationPanelPreset value) {
                                      setDialogState(() {
                                        final String previousDefault =
                                            presentationPanelDefaultKicker(
                                          presetDraft,
                                        );
                                        final bool followsDefault =
                                            kickerFollowsPresetDefault ||
                                                kickerDraft.trim().isEmpty ||
                                                kickerDraft.trim() ==
                                                    previousDefault;
                                        presetDraft = value;
                                        if (followsDefault) {
                                          kickerDraft =
                                              presentationPanelDefaultKicker(
                                            presetDraft,
                                          );
                                          kickerFollowsPresetDefault = true;
                                        }
                                        errorText = null;
                                      });
                                    },
                              itemBuilder: (_) => PresentationPanelPreset.values
                                  .map(
                                    (PresentationPanelPreset value) =>
                                        PopupMenuItem<PresentationPanelPreset>(
                                      value: value,
                                      child: Text(
                                        presentationPanelPresetName(value),
                                      ),
                                    ),
                                  )
                                  .toList(growable: false),
                              child: menuShell(
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        presentationPanelPresetName(
                                          presetDraft,
                                        ),
                                        key: const ValueKey<String>(
                                          'edit-card-cue-preset-value',
                                        ),
                                        style: widget.theme.value.copyWith(
                                          color: R3Theme.textBright,
                                        ),
                                      ),
                                    ),
                                    const Icon(
                                      Icons.arrow_drop_down,
                                      size: 16,
                                      color: R3Theme.textDim,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          SizedBox(width: sc(8)),
                          Expanded(
                            flex: 2,
                            child: Row(
                              children: [
                                Expanded(
                                  child: KeyedSubtree(
                                    key: ValueKey<String>(
                                      'edit-card-cue-font-draft:$fontDraft',
                                    ),
                                    child: TextFormField(
                                      key: const ValueKey<String>(
                                        'edit-card-cue-font-field',
                                      ),
                                      initialValue: fontDraft,
                                      enabled: !panel.hasErrors,
                                      decoration: const InputDecoration(
                                        labelText: 'Font',
                                        hintText: 'Project font',
                                      ),
                                      style: widget.theme.value,
                                      onChanged: (String value) {
                                        setDialogState(() {
                                          fontDraft = value;
                                          errorText = null;
                                        });
                                      },
                                    ),
                                  ),
                                ),
                                SizedBox(width: sc(6)),
                                PopupMenuButton<String>(
                                  key: const ValueKey<String>(
                                    'edit-card-cue-font-menu',
                                  ),
                                  enabled: !panel.hasErrors,
                                  tooltip: 'Common font families',
                                  color: R3Theme.panelHi,
                                  onSelected: (String value) {
                                    setDialogState(() {
                                      fontDraft = value;
                                      errorText = null;
                                    });
                                  },
                                  itemBuilder: (_) => _fontChoices
                                      .map(
                                        (String value) =>
                                            PopupMenuItem<String>(
                                          value: value,
                                          child: Text(
                                            value.isEmpty
                                                ? 'PROJECT FONT'
                                                : value,
                                          ),
                                        ),
                                      )
                                      .toList(growable: false),
                                  child: Container(
                                    padding: EdgeInsets.symmetric(
                                      horizontal: sc(9),
                                      vertical: sc(11),
                                    ),
                                    decoration: BoxDecoration(
                                      color: R3Theme.bg,
                                      border: Border.all(
                                        color: R3Theme.hairline,
                                      ),
                                      borderRadius: BorderRadius.circular(3),
                                    ),
                                    child: const Icon(
                                      Icons.font_download_outlined,
                                      size: 17,
                                      color: R3Theme.textMid,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: sc(8)),
                      Row(
                        children: [
                          Expanded(
                            child: TextFormField(
                              key: const ValueKey<String>(
                                'edit-card-cue-heading-size-field',
                              ),
                              initialValue: headingSizeDraft,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                decimal: true,
                              ),
                              decoration: const InputDecoration(
                                labelText: 'Heading size',
                                helperText: 'Reference units',
                              ),
                              style: widget.theme.value,
                              onChanged: (String value) {
                                setDialogState(() {
                                  headingSizeDraft = value;
                                  errorText = null;
                                });
                              },
                            ),
                          ),
                          SizedBox(width: sc(8)),
                          Expanded(
                            child: TextFormField(
                              key: const ValueKey<String>(
                                'edit-card-cue-body-size-field',
                              ),
                              initialValue: bodySizeDraft,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                decimal: true,
                              ),
                              decoration: const InputDecoration(
                                labelText: 'Body size',
                                helperText: 'Reference units',
                              ),
                              style: widget.theme.value,
                              onChanged: (String value) {
                                setDialogState(() {
                                  bodySizeDraft = value;
                                  errorText = null;
                                });
                              },
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: sc(16)),
                      Text('STYLE', style: widget.theme.microAccent),
                      SizedBox(height: sc(7)),
                      Row(
                        children: [
                          Expanded(
                            child: TextFormField(
                              key: const ValueKey<String>(
                                'edit-card-cue-rgb-field',
                              ),
                              initialValue: rgbDraft,
                              decoration: const InputDecoration(
                                labelText: 'Panel r,g,b',
                              ),
                              style: widget.theme.value,
                              onChanged: (String value) {
                                setDialogState(() {
                                  rgbDraft = value;
                                  errorText = null;
                                });
                              },
                            ),
                          ),
                          SizedBox(width: sc(8)),
                          Expanded(
                            child: TextFormField(
                              key: const ValueKey<String>(
                                'edit-card-cue-image-percent-field',
                              ),
                              initialValue: imagePercentDraft,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                decimal: true,
                              ),
                              decoration: const InputDecoration(
                                labelText: 'Image height %',
                                helperText: '25–55; EDITORIAL default 38',
                              ),
                              style: widget.theme.value,
                              onChanged: (String value) {
                                setDialogState(() {
                                  imagePercentDraft = value;
                                  errorText = null;
                                });
                              },
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: sc(16)),
                      Text('TIMING', style: widget.theme.microAccent),
                      SizedBox(height: sc(7)),
                      TextFormField(
                        key: const ValueKey<String>(
                          'edit-card-cue-hold-field',
                        ),
                        initialValue: holdDraft,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Hold frames',
                        ),
                        style: widget.theme.value,
                        onChanged: (String value) {
                          holdDraft = value;
                          errorText = null;
                        },
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('CANCEL'),
                ),
                TextButton(
                  key: const ValueKey<String>('edit-card-cue-apply'),
                  onPressed: panel.hasErrors ? null : apply,
                  child: Text(existing == null ? 'ADD CUE' : 'APPLY'),
                ),
              ],
            );
              },
            );
          },
        );
      },
    );
  }

  Future<void> _add() async {
    final int? sourceFrame = _playheadSourceFrame;
    final ValueChanged<CardRequest>? callback = widget.onAddAtPlayhead;
    if (sourceFrame == null || callback == null) return;
    final CardRequest? card = await _editCard(sourceFrame: sourceFrame);
    if (!mounted || card == null) return;
    callback(card);
  }

  Future<void> _edit(int index, EditCardCue cue) async {
    final EditCardCueChanged? callback = widget.onChanged;
    if (callback == null) return;
    final CardRequest? card = await _editCard(
      sourceFrame: cue.sourceFrame,
      existing: cue.card,
    );
    if (!mounted || card == null) return;
    callback(index, card);
  }

  @override
  Widget build(BuildContext context) {
    final int? playheadSourceFrame = _playheadSourceFrame;
    final bool canAdd =
        widget.onAddAtPlayhead != null && playheadSourceFrame != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: sc(32),
          child: OutlinedButton.icon(
            key: const ValueKey<String>('edit-card-cue-add'),
            onPressed: canAdd ? _add : null,
            icon: const Icon(Icons.add, size: 16),
            label: const Text('ADD CARD CUE AT PLAYHEAD'),
            style: OutlinedButton.styleFrom(
              padding: EdgeInsets.symmetric(horizontal: sc(7)),
              foregroundColor: widget.theme.accent,
              side: BorderSide(color: widget.theme.accentDim),
            ),
          ),
        ),
        SizedBox(height: sc(5)),
        Text(
          key: const ValueKey<String>('edit-card-cue-playhead'),
          canAdd
              ? 'Playhead F${widget.playheadFrame} → source F$playheadSourceFrame.'
              : 'Park the playhead inside this clip to add a CARD cue.',
          style: widget.theme.micro.copyWith(color: R3Theme.textDim),
        ),
        if (widget.cues.isEmpty) ...[
          SizedBox(height: sc(8)),
          Text(
            'No authored CARD cues in this CLIP.',
            key: const ValueKey<String>('edit-card-cue-empty'),
            style: widget.theme.fine.copyWith(color: R3Theme.textDim),
          ),
        ] else ...[
          SizedBox(height: sc(9)),
          for (int index = 0; index < widget.cues.length; index++)
            _cueRow(index, widget.cues[index]),
        ],
      ],
    );
  }

  Widget _cueRow(int index, EditCardCue cue) {
    final int? projectFrame = cueProjectFrame(widget.clip.clip, cue.sourceFrame);
    final String project = projectFrame == null ? 'DORMANT' : 'P$projectFrame';
    final String heading = cue.card.heading.trim();
    final String style = cue.isSideCard ? 'SIDE' : 'FULL';

    return Container(
      key: ValueKey<String>('edit-card-cue-row-$index'),
      margin: EdgeInsets.only(bottom: sc(7)),
      padding: EdgeInsets.all(sc(7)),
      decoration: BoxDecoration(
        color: R3Theme.bg,
        border: Border.all(color: R3Theme.hairline),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '$style   SOURCE F${cue.sourceFrame}   $project',
                  key: ValueKey<String>('edit-card-cue-style-row-$index'),
                  style: widget.theme.microAccent,
                ),
              ),
              Text('${cue.card.holdFrames}F', style: widget.theme.micro),
            ],
          ),
          SizedBox(height: sc(3)),
          Text(
            cue.card.image,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: widget.theme.fine.copyWith(color: R3Theme.textBright),
          ),
          if (heading.isNotEmpty) ...[
            SizedBox(height: sc(2)),
            Text(
              heading,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: widget.theme.micro.copyWith(color: R3Theme.textMid),
            ),
          ],
          SizedBox(height: sc(5)),
          Row(
            children: [
              TextButton(
                key: ValueKey<String>('edit-card-cue-edit-$index'),
                onPressed: widget.onChanged == null ? null : () => _edit(index, cue),
                style: TextButton.styleFrom(
                  minimumSize: Size.zero,
                  padding: EdgeInsets.symmetric(
                    horizontal: sc(6),
                    vertical: sc(3),
                  ),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text('EDIT', style: widget.theme.micro),
              ),
              const Spacer(),
              TextButton(
                key: ValueKey<String>('edit-card-cue-delete-$index'),
                onPressed: widget.onDeleted == null
                    ? null
                    : () => widget.onDeleted!(index),
                style: TextButton.styleFrom(
                  minimumSize: Size.zero,
                  padding: EdgeInsets.symmetric(
                    horizontal: sc(6),
                    vertical: sc(3),
                  ),
                  foregroundColor: R3Theme.danger,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text('DELETE', style: widget.theme.micro),
              ),
            ],
          ),
        ],
      ),
    );
  }
}



class _CardDialogFocusScope extends StatefulWidget {
  const _CardDialogFocusScope({required this.builder});

  final Widget Function(
    BuildContext context,
    FocusNode kickerFocus,
    FocusNode headingFocus,
    FocusNode bodyFocus,
  ) builder;

  @override
  State<_CardDialogFocusScope> createState() => _CardDialogFocusScopeState();
}

class _CardDialogFocusScopeState extends State<_CardDialogFocusScope> {
  final FocusNode _kickerFocus = FocusNode(debugLabel: 'card-kicker');
  final FocusNode _headingFocus = FocusNode(debugLabel: 'card-heading');
  final FocusNode _bodyFocus = FocusNode(debugLabel: 'card-body');

  @override
  void dispose() {
    _kickerFocus.dispose();
    _headingFocus.dispose();
    _bodyFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(
        context,
        _kickerFocus,
        _headingFocus,
        _bodyFocus,
      );
}

class _CardFacePreview extends StatefulWidget {
  const _CardFacePreview({
    required this.card,
    required this.resolveSource,
    this.onKickerTap,
    this.onHeadingTap,
    this.onBodyTap,
  });

  final CardRequest card;
  final String Function(String source)? resolveSource;
  final VoidCallback? onKickerTap;
  final VoidCallback? onHeadingTap;
  final VoidCallback? onBodyTap;

  @override
  State<_CardFacePreview> createState() => _CardFacePreviewState();
}

class _CardFacePreviewState extends State<_CardFacePreview> {
  CardOverlayImageCache? _cache;

  @override
  void initState() {
    super.initState();
    _resetCache();
  }

  @override
  void didUpdateWidget(covariant _CardFacePreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.resolveSource, widget.resolveSource)) {
      _resetCache();
    } else if (oldWidget.card.image != widget.card.image) {
      _ensureImage();
    }
  }

  void _resetCache() {
    _cache?.dispose();
    final String Function(String source)? resolver = widget.resolveSource;
    _cache = resolver == null ? null : CardOverlayImageCache(resolver);
    _ensureImage();
  }

  void _ensureImage() {
    final CardOverlayImageCache? cache = _cache;
    if (cache == null || widget.card.image.trim().isEmpty) return;
    final StructuralCardOverlayPlacement placement =
        StructuralCardOverlayPlacement(
      card: widget.card,
      slide: 1.0,
      normalizedRect: const Rect.fromLTWH(0, 0, 1, 1),
    );
    cache.ensure(<StructuralCardOverlayPlacement>[placement]).then(
      (bool changed) {
        if (changed && mounted) setState(() {});
      },
    );
  }

  @override
  void dispose() {
    _cache?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Rect reference = sideCardSeatedPanelRect(
      const Size(1920, 1080),
    );
    final PresentationPanelContent content = parsePresentationPanelContent(
      heading: widget.card.heading,
      body: widget.card.body,
    );
    final double imageFraction = content.imageFraction ??
        (content.preset == PresentationPanelPreset.editorial
            ? 0.38
            : (content.preset == PresentationPanelPreset.simple ? 0.42 : 0.34));

    return Center(
      child: SizedBox(
        height: sc(300),
        child: AspectRatio(
          aspectRatio: reference.width / reference.height,
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final Size size = constraints.biggest;
              final double imageH = size.height * imageFraction;
              final double contentTop = imageH;
              final double kickerH = math.min(sc(34), size.height * 0.09);
              final double headingH = math.min(sc(70), size.height * 0.18);
              final double bodyTop = math.min(
                size.height,
                contentTop + kickerH + headingH,
              );

              return Stack(
                fit: StackFit.expand,
                children: [
                  CustomPaint(
                    key: const ValueKey<String>('edit-card-face-preview'),
                    painter: _CardFacePreviewPainter(
                      card: widget.card,
                      image: _cache?.imageFor(widget.card),
                      referenceRect: reference,
                    ),
                  ),
                  if (widget.onKickerTap != null)
                    Positioned(
                      left: 0,
                      right: 0,
                      top: contentTop,
                      height: kickerH,
                      child: GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onTap: widget.onKickerTap,
                      ),
                    ),
                  if (widget.onHeadingTap != null)
                    Positioned(
                      left: 0,
                      right: 0,
                      top: contentTop + kickerH,
                      height: headingH,
                      child: GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onTap: widget.onHeadingTap,
                      ),
                    ),
                  if (widget.onBodyTap != null && bodyTop < size.height)
                    Positioned(
                      left: 0,
                      right: 0,
                      top: bodyTop,
                      bottom: 0,
                      child: GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onTap: widget.onBodyTap,
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _CardFacePreviewPainter extends CustomPainter {
  const _CardFacePreviewPainter({
    required this.card,
    required this.image,
    required this.referenceRect,
  });

  final CardRequest card;
  final ui.Image? image;
  final Rect referenceRect;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final double sx = size.width / referenceRect.width;
    final double sy = size.height / referenceRect.height;
    final double scale = math.min(sx, sy);
    final double drawW = referenceRect.width * scale;
    final double drawH = referenceRect.height * scale;
    final Offset origin = Offset(
      (size.width - drawW) / 2.0,
      (size.height - drawH) / 2.0,
    );

    canvas.save();
    canvas.translate(origin.dx, origin.dy);
    canvas.scale(scale, scale);
    paintPresentationCardFace(
      canvas: canvas,
      cardRect: Rect.fromLTWH(
        0,
        0,
        referenceRect.width,
        referenceRect.height,
      ),
      referenceScale: 1.0,
      card: card,
      image: image,
      inheritedFontFamily: 'monospace',
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _CardFacePreviewPainter oldDelegate) => true;
}
