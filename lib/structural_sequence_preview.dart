// ./lib/structural_sequence_preview.dart
//
// Widget projection of one structural source placed into the main TEXT
// sequence. Source definitions remain owned by the EDIT/MOSAIC model; this
// widget is only the presentation of the sequence-side [STRUCT:...] reference.

import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'edit_video_preview.dart';
import 'structural_sequence.dart';
import 'ui_theme.dart';

class StructuralSequencePreview extends StatelessWidget {
  final String rawDocument;
  final StructuralSequencePlacement placement;
  final int localFrame;
  final bool isPlaying;
  final R3Theme theme;
  final ui.Image? wallpaper;

  const StructuralSequencePreview({
    super.key,
    required this.rawDocument,
    required this.placement,
    required this.localFrame,
    required this.isPlaying,
    required this.theme,
    required this.wallpaper,
  });

  @override
  Widget build(BuildContext context) {
    final String source = placement.sourceRef.canonicalSource;

    return ColoredBox(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (wallpaper != null)
            RawImage(
              image: wallpaper,
              fit: BoxFit.cover,
              filterQuality: FilterQuality.low,
            ),

          // Keep the desktop legible behind the active structural window.
          ColoredBox(color: Colors.black.withValues(alpha: 0.20)),

          Center(
            child: FractionallySizedBox(
              widthFactor: 0.88,
              heightFactor: 0.80,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: const Color(0xFF171717),
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(color: const Color(0xFF3B3938)),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x66000000),
                      blurRadius: 24,
                      offset: Offset(0, 12),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: Column(
                    children: [
                      Container(
                        height: 38,
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        decoration: const BoxDecoration(
                          color: Color(0xFF33302F),
                          border: Border(
                            bottom: BorderSide(color: Color(0xFF474341)),
                          ),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                source,
                                overflow: TextOverflow.ellipsis,
                                style: theme.value.copyWith(
                                  color: const Color(0xFFC7C3C0),
                                  fontSize: 12,
                                ),
                              ),
                            ),
                            Text(
                              'F$localFrame / ${placement.durationFrames}',
                              style: theme.micro.copyWith(
                                color: const Color(0xFF8E8884),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: ColoredBox(
                          color: Colors.black,
                          child: EditVideoPreview(
                            key: ValueKey<String>('sequence-preview:$source'),
                            source: rawDocument,
                            structuralSource: source,
                            currentFrame: localFrame,
                            theme: theme,
                            isPlaying: isPlaying,
                            fastPreview: isPlaying,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
