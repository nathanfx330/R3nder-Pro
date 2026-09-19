// ./lib/edit_card_cue_controls.dart
//
// GUI authoring controls for clip-local CARD-family cues in the EDIT inspector.
//
// This widget owns only transient form state. Every durable change is returned
// to EditSurface as a CardRequest and is serialized into the canonical CLIP
// source by edit_cue_authoring.dart. SideCardRequest is a CardRequest subtype,
// so the existing inspector/history seam remains one source-backed path.

import 'package:flutter/material.dart';

import 'edit_cue.dart';
import 'edit_surface_model.dart';
import 'presentation_card_face_preview.dart';
import 'presentation_panel_content.dart';
import 'presentation_requests.dart';
import 'r3_color_picker.dart';
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
    this.resolveImageSource,
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

  /// Resolves workspace-relative CARD images for the read-only face preview.
  final String Function(String source)? resolveImageSource;

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

  static String _draftNumber(double value) {
    if (value == value.roundToDouble()) return value.toStringAsFixed(0);
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
    String headingSizeDraft = _draftNumber(
      panel.headingSize ?? presentationPanelDefaultHeadingSize(presetDraft),
    );
    String bodySizeDraft = _draftNumber(
      panel.bodySize ?? presentationPanelDefaultBodySize(presetDraft),
    );
    String imagePercentDraft = _draftNumber(
      (panel.imageFraction ??
              presentationPanelDefaultImageFraction(presetDraft)) *
          100.0,
    );
    bool headingSizeTouched = false;
    bool bodySizeTouched = false;
    bool imagePercentTouched = false;
    String subtitleDraft = panel.subtitle;
    String metadataDraft = panel.metadata
        .map((PresentationPanelMetadata item) => '${item.label} | ${item.value}')
        .join('\n');
    String bodyDraft = panel.hasErrors ? '' : panel.body;
    final List<String> preservedPanelDirectives = panel.preservedDirectives;

    final TextEditingController imageController =
        TextEditingController(text: imageDraft);
    final TextEditingController kickerController =
        TextEditingController(text: kickerDraft);
    final TextEditingController fontController =
        TextEditingController(text: fontDraft);
    final TextEditingController headingSizeController =
        TextEditingController(text: headingSizeDraft);
    final TextEditingController bodySizeController =
        TextEditingController(text: bodySizeDraft);
    final TextEditingController imagePercentController =
        TextEditingController(text: imagePercentDraft);

    ModalRoute<dynamic>? dialogRoute;
    final CardRequest? result = await showDialog<CardRequest>(
      context: context,
      builder: (BuildContext dialogContext) {
        dialogRoute ??= ModalRoute.of(dialogContext);
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

            Color draftPanelColor() {
              final List<int?> rgb = rgbDraft
                  .split(',')
                  .map((String value) => int.tryParse(value.trim()))
                  .toList(growable: false);
              if (rgb.length == 3 &&
                  rgb.every(
                    (int? value) =>
                        value != null && value >= 0 && value <= 255,
                  )) {
                return Color.fromARGB(255, rgb[0]!, rgb[1]!, rgb[2]!);
              }
              return existing?.panelColor ?? const Color(0xFF1E1E26);
            }

            CardRequest previewCard() {
              final Color panelColor = draftPanelColor();
              final double headingSize =
                  double.tryParse(headingSizeDraft.trim()) ??
                      presentationPanelDefaultHeadingSize(presetDraft);
              final double bodySize = double.tryParse(bodySizeDraft.trim()) ??
                  presentationPanelDefaultBodySize(presetDraft);
              final double imagePercent =
                  double.tryParse(imagePercentDraft.trim()) ??
                      presentationPanelDefaultImageFraction(presetDraft) * 100.0;
              final List<PresentationPanelMetadata> metadata = sideDraft
                  ? panel.metadata
                  : (parseMetadataDraft() ?? panel.metadata);
              final String cleanKicker = kickerDraft.trim();
              final String authoredKicker =
                  cleanKicker == presentationPanelDefaultKicker(presetDraft)
                      ? ''
                      : cleanKicker;
              final String previewBody = formatPresentationPanelBody(
                preset: presetDraft,
                kicker: authoredKicker,
                fontFamily: fontDraft,
                headingSize: headingSize,
                bodySize: bodySize,
                imageFraction:
                    (imagePercent / 100.0).clamp(0.01, 0.99).toDouble(),
                subtitle: subtitleDraft,
                metadata: metadata,
                preservedDirectives: preservedPanelDirectives,
                body: bodyDraft,
              );
              final String previewImage = imageDraft.trim();
              final String previewHeading = headingDraft.trim();
              final int previewHold =
                  int.tryParse(holdDraft.trim()) ?? existing?.holdFrames ?? 90;
              return sideDraft
                  ? SideCardRequest(
                      image: previewImage,
                      holdFrames: previewHold,
                      panelColor: panelColor,
                      heading: previewHeading,
                      body: previewBody,
                    )
                  : CardRequest(
                      image: previewImage,
                      holdFrames: previewHold,
                      panelColor: panelColor,
                      heading: previewHeading,
                      body: previewBody,
                    );
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
                  sideDraft ? panel.metadata : parseMetadataDraft();
              final double? headingSize =
                  double.tryParse(headingSizeDraft.trim());
              final double? bodySize =
                  double.tryParse(bodySizeDraft.trim());
              final double? imagePercent =
                  double.tryParse(imagePercentDraft.trim());

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
              } else if (headingSize == null ||
                  !headingSize.isFinite ||
                  headingSize <= 0 ||
                  headingSize > 200) {
                problem = 'Heading size must be greater than 0 and at most 200.';
              } else if (bodySize == null ||
                  !bodySize.isFinite ||
                  bodySize <= 0 ||
                  bodySize > 200) {
                problem = 'Body size must be greater than 0 and at most 200.';
              } else if (imagePercent == null ||
                  !imagePercent.isFinite ||
                  imagePercent <= 0 ||
                  imagePercent >= 100) {
                problem = 'Image height must be greater than 0% and less than 100%.';
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
                headingSize:
                    panel.headingSize != null || headingSizeTouched
                        ? headingSize
                        : null,
                bodySize:
                    panel.bodySize != null || bodySizeTouched ? bodySize : null,
                imageFraction:
                    panel.imageFraction != null || imagePercentTouched
                        ? imagePercent! / 100.0
                        : null,
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

            final CardRequest preview = previewCard();

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
                      Text('LIVE PREVIEW', style: widget.theme.microAccent),
                      SizedBox(height: sc(6)),
                      if (!panel.hasErrors) ...[
                        Container(
                          key: const ValueKey<String>(
                            'edit-card-cue-preview-slot',
                          ),
                          padding: EdgeInsets.all(sc(8)),
                          decoration: BoxDecoration(
                            color: R3Theme.bg,
                            border: Border.all(color: R3Theme.hairline),
                            borderRadius: BorderRadius.circular(3),
                          ),
                          child: PresentationCardFacePreview(
                            card: preview,
                            resolveSource: widget.resolveImageSource,
                            height: sc(230),
                          ),
                        ),
                      ],
                      if (panel.hasWarnings) ...[
                        SizedBox(height: sc(8)),
                        Text(
                          'This PANEL contains directives this build does not '
                          'use. They will be preserved unchanged when you apply '
                          'edits.',
                          key: const ValueKey<String>(
                            'edit-card-cue-panel-warning',
                          ),
                          style: widget.theme.fine.copyWith(
                            color: R3Theme.warn,
                          ),
                        ),
                      ],
                      if (panel.hasErrors) ...[
                        SizedBox(height: sc(8)),
                        Text(
                          'This PANEL is malformed. Fix the script warning '
                          'first; the GUI will not rewrite it.',
                          key: const ValueKey<String>(
                            'edit-card-cue-panel-error',
                          ),
                          style: widget.theme.fine.copyWith(
                            color: R3Theme.danger,
                          ),
                        ),
                      ],
                      SizedBox(height: sc(16)),
                      Text('CONTENT', style: widget.theme.microAccent),
                      SizedBox(height: sc(8)),
                      Row(
                        children: [
                          Expanded(
                            child: TextFormField(
                              key: const ValueKey<String>(
                                'edit-card-cue-image-field',
                              ),
                              controller: imageController,
                                decoration: const InputDecoration(
                                  labelText: 'Hero image',
                                  hintText: 'workspace images/',
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
                                imageController.text = value;
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
                                border: Border.all(
                                  color: R3Theme.hairline,
                                ),
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
                      SizedBox(height: sc(10)),
                      TextFormField(
                        key: const ValueKey<String>(
                          'edit-card-cue-kicker-field',
                        ),
                        controller: kickerController,
                          enabled: !panel.hasErrors,
                          decoration: const InputDecoration(
                            labelText: 'Kicker / category',
                            hintText: 'WILDLIFE',
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
                      SizedBox(height: sc(10)),
                      TextFormField(
                        key: const ValueKey<String>(
                          'edit-card-cue-heading-field',
                        ),
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
                      SizedBox(height: sc(10)),
                      TextFormField(
                        key: const ValueKey<String>(
                          'edit-card-cue-body-field',
                        ),
                        initialValue: bodyDraft,
                        enabled: !panel.hasErrors,
                        minLines: 3,
                        maxLines: 7,
                        decoration: InputDecoration(
                          labelText: 'Body copy',
                          hintText:
                              'Write the short editorial copy shown beneath '
                              'the heading.',
                          errorText: errorText,
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
                      if (presetDraft != PresentationPanelPreset.editorial) ...[
                        SizedBox(height: sc(10)),
                        TextFormField(
                          key: const ValueKey<String>(
                            'edit-card-cue-subtitle-field',
                          ),
                          initialValue: subtitleDraft,
                          enabled: !panel.hasErrors,
                          decoration: const InputDecoration(
                            labelText: 'Subtitle / role',
                            hintText: 'Investigative Reporter',
                          ),
                          style: widget.theme.value,
                          onChanged: (String value) {
                            setDialogState(() {
                              subtitleDraft = value;
                              errorText = null;
                            });
                          },
                        ),
                        if (!sideDraft) ...[
                          SizedBox(height: sc(10)),
                          TextFormField(
                            key: const ValueKey<String>(
                              'edit-card-cue-metadata-field',
                            ),
                            initialValue: metadataDraft,
                            enabled: !panel.hasErrors,
                            minLines: 2,
                            maxLines: 5,
                            decoration: const InputDecoration(
                              labelText: 'Fact rows / metadata',
                              hintText:
                                  'ORGANIZATION | Example News\n'
                                  'LOCATION | Washington, DC',
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
                        ],
                      ],
                      SizedBox(height: sc(16)),
                      Text('TYPE', style: widget.theme.microAccent),
                      SizedBox(height: sc(8)),
                      Row(
                        children: [
                          Expanded(
                            child:
                                PopupMenuButton<PresentationPanelPreset>(
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
                                          kickerController.text = kickerDraft;
                                          kickerFollowsPresetDefault = true;
                                        }
                                        if (panel.headingSize == null &&
                                            !headingSizeTouched) {
                                          headingSizeDraft = _draftNumber(
                                            presentationPanelDefaultHeadingSize(
                                              presetDraft,
                                            ),
                                          );
                                          headingSizeController.text =
                                              headingSizeDraft;
                                        }
                                        if (panel.bodySize == null &&
                                            !bodySizeTouched) {
                                          bodySizeDraft = _draftNumber(
                                            presentationPanelDefaultBodySize(
                                              presetDraft,
                                            ),
                                          );
                                          bodySizeController.text =
                                              bodySizeDraft;
                                        }
                                        if (panel.imageFraction == null &&
                                            !imagePercentTouched) {
                                          imagePercentDraft = _draftNumber(
                                            presentationPanelDefaultImageFraction(
                                                  presetDraft,
                                                ) *
                                                100.0,
                                          );
                                          imagePercentController.text =
                                              imagePercentDraft;
                                        }
                                        errorText = null;
                                      });
                                    },
                              itemBuilder: (_) =>
                                  PresentationPanelPreset.values
                                      .map(
                                        (
                                          PresentationPanelPreset value,
                                        ) =>
                                            PopupMenuItem<
                                              PresentationPanelPreset
                                            >(
                                              value: value,
                                              child: Text(
                                                presentationPanelPresetName(
                                                  value,
                                                ),
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
                                  child: TextFormField(
                                    key: const ValueKey<String>(
                                      'edit-card-cue-font-field',
                                    ),
                                    controller: fontController,
                                      enabled: !panel.hasErrors,
                                      decoration: const InputDecoration(
                                        labelText: 'Font family',
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
                                      fontController.text = value;
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
                      SizedBox(height: sc(10)),
                      Row(
                        children: [
                          Expanded(
                            child: TextFormField(
                              key: const ValueKey<String>(
                                'edit-card-cue-heading-size-field',
                              ),
                              controller: headingSizeController,
                                enabled: !panel.hasErrors,
                                keyboardType:
                                    const TextInputType.numberWithOptions(
                                  decimal: true,
                                ),
                                decoration: const InputDecoration(
                                  labelText: 'Heading size',
                                  suffixText: 'ref',
                                ),
                                style: widget.theme.value,
                                onChanged: (String value) {
                                  setDialogState(() {
                                    headingSizeDraft = value;
                                    headingSizeTouched = true;
                                    errorText = null;
                                  });
                                },
                            ),
                          ),
                          SizedBox(width: sc(10)),
                          Expanded(
                            child: TextFormField(
                              key: const ValueKey<String>(
                                'edit-card-cue-body-size-field',
                              ),
                              controller: bodySizeController,
                                enabled: !panel.hasErrors,
                                keyboardType:
                                    const TextInputType.numberWithOptions(
                                  decimal: true,
                                ),
                                decoration: const InputDecoration(
                                  labelText: 'Body size',
                                  suffixText: 'ref',
                                ),
                                style: widget.theme.value,
                                onChanged: (String value) {
                                  setDialogState(() {
                                    bodySizeDraft = value;
                                    bodySizeTouched = true;
                                    errorText = null;
                                  });
                                },
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: sc(16)),
                      Text('STYLE', style: widget.theme.microAccent),
                      SizedBox(height: sc(8)),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Presentation',
                              style: widget.theme.micro,
                            ),
                          ),
                          PopupMenuButton<bool>(
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
                            itemBuilder: (_) =>
                                const <PopupMenuEntry<bool>>[
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
                              width: sc(220),
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
                        ],
                      ),
                      SizedBox(height: sc(10)),
                      Row(
                        children: [
                          Expanded(
                            child: InkWell(
                              key: const ValueKey<String>(
                                'edit-card-cue-color-picker',
                              ),
                              borderRadius: BorderRadius.circular(3),
                              onTap: () async {
                                final Color? picked = await showR3ColorPicker(
                                  context: context,
                                  initialColor: draftPanelColor(),
                                  theme: widget.theme,
                                  title: 'BACKGROUND COLOR',
                                );
                                if (picked == null || !context.mounted) return;
                                final int value = picked.toARGB32();
                                final int pickedRed = (value >> 16) & 0xFF;
                                final int pickedGreen = (value >> 8) & 0xFF;
                                final int pickedBlue = value & 0xFF;
                                setDialogState(() {
                                  rgbDraft =
                                      '$pickedRed,$pickedGreen,$pickedBlue';
                                  errorText = null;
                                });
                              },
                              child: Container(
                                padding: EdgeInsets.symmetric(
                                  horizontal: sc(10),
                                  vertical: sc(9),
                                ),
                                decoration: BoxDecoration(
                                  color: R3Theme.bg,
                                  border: Border.all(
                                    color: R3Theme.hairline,
                                  ),
                                  borderRadius: BorderRadius.circular(3),
                                ),
                                child: Row(
                                  children: [
                                    Container(
                                      key: const ValueKey<String>(
                                        'edit-card-cue-color-swatch',
                                      ),
                                      width: sc(30),
                                      height: sc(30),
                                      decoration: BoxDecoration(
                                        color: draftPanelColor(),
                                        border: Border.all(
                                          color: R3Theme.textDim,
                                        ),
                                        borderRadius:
                                            BorderRadius.circular(3),
                                      ),
                                    ),
                                    SizedBox(width: sc(9)),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text(
                                            'BACKGROUND COLOR',
                                            style: widget.theme.micro,
                                          ),
                                          SizedBox(height: sc(2)),
                                          Text(
                                            r3ColorHex(draftPanelColor()),
                                            key: const ValueKey<String>(
                                              'edit-card-cue-color-hex',
                                            ),
                                            style: widget.theme.value,
                                          ),
                                          Text(
                                            'RGB $rgbDraft',
                                            key: const ValueKey<String>(
                                              'edit-card-cue-color-rgb',
                                            ),
                                            style: widget.theme.fine.copyWith(
                                              color: R3Theme.textMid,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    const Icon(
                                      Icons.colorize_outlined,
                                      size: 17,
                                      color: R3Theme.textMid,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          SizedBox(width: sc(10)),
                          Expanded(
                            child: TextFormField(
                              key: const ValueKey<String>(
                                'edit-card-cue-image-percent-field',
                              ),
                              controller: imagePercentController,
                                enabled: !panel.hasErrors,
                                keyboardType:
                                    const TextInputType.numberWithOptions(
                                  decimal: true,
                                ),
                                decoration: const InputDecoration(
                                  labelText: 'Hero height',
                                  suffixText: '%',
                                  helperText: '> 0 and < 100',
                                ),
                                style: widget.theme.value,
                                onChanged: (String value) {
                                  setDialogState(() {
                                    imagePercentDraft = value;
                                    imagePercentTouched = true;
                                    errorText = null;
                                  });
                                },
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: sc(16)),
                      Text('TIMING', style: widget.theme.microAccent),
                      SizedBox(height: sc(8)),
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
                        onChanged: (String value) => holdDraft = value,
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

    final ModalRoute<dynamic>? completedRoute = dialogRoute;
    if (completedRoute != null) {
      await completedRoute.completed;
    }
    imageController.dispose();
    kickerController.dispose();
    fontController.dispose();
    headingSizeController.dispose();
    bodySizeController.dispose();
    imagePercentController.dispose();
    return result;
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
