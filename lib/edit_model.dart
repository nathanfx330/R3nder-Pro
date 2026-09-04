// ./lib/edit_model.dart
//
// Canonical EDIT / TRACK / CLIP and MOSAIC / PANE / CLIP source model.
//
// ScriptCstDocument owns source spans and nesting. This file gives those
// structural blocks meaning without introducing a parallel project database.
// The script remains canonical. Clip duration is authored in project frames and
// never inferred from media or from another structural source. Missing or
// replaced media may change what can be decoded, but it cannot change how many
// project frames the authored container owns.

import 'script_cst.dart';

class EditLanguageFormatException implements Exception {
  final String message;
  final int offset;

  const EditLanguageFormatException(this.message, this.offset);

  @override
  String toString() => 'EditLanguageFormatException at $offset: $message';
}

enum StructuralSourceKind {
  edit,
  mosaic,
}

/// A CLIP source that points back into the canonical script instead of to a
/// filesystem media resource.
///
/// The source spelling is intentionally explicit. `EDIT.foo` and `MOSAIC.foo`
/// occupy separate namespaces, so an EDIT and a MOSAIC may share the same id
/// without becoming ambiguous.
class StructuralSourceRef {
  final StructuralSourceKind kind;
  final String id;

  const StructuralSourceRef._(this.kind, this.id);

  static StructuralSourceRef? tryParse(String source) {
    final String value = source.trim();
    if (value.startsWith('EDIT.')) {
      return StructuralSourceRef._(
        StructuralSourceKind.edit,
        value.substring('EDIT.'.length).trim(),
      );
    }
    if (value.startsWith('MOSAIC.')) {
      return StructuralSourceRef._(
        StructuralSourceKind.mosaic,
        value.substring('MOSAIC.'.length).trim(),
      );
    }
    return null;
  }

  String get canonicalSource {
    switch (kind) {
      case StructuralSourceKind.edit:
        return 'EDIT.$id';
      case StructuralSourceKind.mosaic:
        return 'MOSAIC.$id';
    }
  }

  String get graphLabel {
    switch (kind) {
      case StructuralSourceKind.edit:
        return 'EDIT.$id';
      case StructuralSourceKind.mosaic:
        return 'MOSAIC.$id';
    }
  }

  @override
  bool operator ==(Object other) =>
      other is StructuralSourceRef && other.kind == kind && other.id == id;

  @override
  int get hashCode => Object.hash(kind, id);

  @override
  String toString() => canonicalSource;
}

class ExactClipSpeed {
  final int numerator;
  final int denominator;

  const ExactClipSpeed._(this.numerator, this.denominator);

  factory ExactClipSpeed(int numerator, [int denominator = 1]) {
    if (numerator <= 0 || denominator <= 0) {
      throw ArgumentError('Clip speed numerator and denominator must be > 0.');
    }
    final int divisor = _gcd(numerator, denominator);
    return ExactClipSpeed._(
      numerator ~/ divisor,
      denominator ~/ divisor,
    );
  }

  factory ExactClipSpeed.parse(String source) {
    final String value = source.trim();
    if (value.isEmpty) {
      throw const FormatException('Clip speed cannot be empty.');
    }

    final int slash = value.indexOf('/');
    if (slash >= 0) {
      if (slash == 0 ||
          slash == value.length - 1 ||
          value.indexOf('/', slash + 1) >= 0) {
        throw FormatException('Invalid rational clip speed: $source');
      }
      final int? numerator = int.tryParse(value.substring(0, slash));
      final int? denominator = int.tryParse(value.substring(slash + 1));
      if (numerator == null ||
          denominator == null ||
          numerator <= 0 ||
          denominator <= 0) {
        throw FormatException('Invalid rational clip speed: $source');
      }
      return ExactClipSpeed(numerator, denominator);
    }

    final RegExpMatch? decimal =
        RegExp(r'^(?<whole>\d+)(?:\.(?<fraction>\d+))?$').firstMatch(value);
    if (decimal == null) {
      throw FormatException('Invalid clip speed: $source');
    }

    final String whole = decimal.namedGroup('whole')!;
    final String fraction = decimal.namedGroup('fraction') ?? '';
    if (fraction.isEmpty) {
      final int parsed = int.parse(whole);
      if (parsed <= 0) throw FormatException('Clip speed must be > 0.');
      return ExactClipSpeed(parsed);
    }

    int denominator = 1;
    for (int i = 0; i < fraction.length; i++) {
      denominator *= 10;
    }
    final int numerator = int.parse('$whole$fraction');
    if (numerator <= 0) throw FormatException('Clip speed must be > 0.');
    return ExactClipSpeed(numerator, denominator);
  }

  String get canonicalMarkup =>
      denominator == 1 ? '$numerator' : '$numerator/$denominator';

  @override
  bool operator ==(Object other) =>
      other is ExactClipSpeed &&
      other.numerator == numerator &&
      other.denominator == denominator;

  @override
  int get hashCode => Object.hash(numerator, denominator);

  @override
  String toString() => canonicalMarkup;
}

class EditDocumentModel {
  final ScriptCstDocument cst;
  final List<EditSequence> edits;
  final List<MosaicSequence> mosaics;

  EditDocumentModel._(this.cst, this.edits, this.mosaics);

  factory EditDocumentModel.parse(String source) {
    final ScriptCstDocument cst = ScriptCstDocument.parse(source);
    final List<EditSequence> edits = <EditSequence>[];
    final List<MosaicSequence> mosaics = <MosaicSequence>[];
    final Set<String> editIds = <String>{};
    final Set<String> mosaicIds = <String>{};

    for (final ScriptCstBlock root in cst.roots) {
      switch (root.type) {
        case 'EDIT':
          final EditSequence edit = _parseEditSequence(root);
          if (!editIds.add(edit.id)) {
            throw EditLanguageFormatException(
              'Duplicate EDIT id "${edit.id}".',
              root.startOffset,
            );
          }
          edits.add(edit);
          break;
        case 'MOSAIC':
          final MosaicSequence mosaic = _parseMosaicSequence(root);
          if (!mosaicIds.add(mosaic.id)) {
            throw EditLanguageFormatException(
              'Duplicate MOSAIC id "${mosaic.id}".',
              root.startOffset,
            );
          }
          mosaics.add(mosaic);
          break;
        default:
          throw EditLanguageFormatException(
            'Unsupported structural root ${root.type}.',
            root.startOffset,
          );
      }
    }

    return EditDocumentModel._(
      cst,
      List<EditSequence>.unmodifiable(edits),
      List<MosaicSequence>.unmodifiable(mosaics),
    );
  }

  String get source => cst.source;

  EditSequence edit(String id) => edits.singleWhere(
        (EditSequence edit) => edit.id == id,
        orElse: () => throw StateError('No EDIT named "$id".'),
      );

  MosaicSequence mosaic(String id) => mosaics.singleWhere(
        (MosaicSequence mosaic) => mosaic.id == id,
        orElse: () => throw StateError('No MOSAIC named "$id".'),
      );

  bool containsStructuralSource(StructuralSourceRef ref) {
    switch (ref.kind) {
      case StructuralSourceKind.edit:
        return edits.any((EditSequence edit) => edit.id == ref.id);
      case StructuralSourceKind.mosaic:
        return mosaics.any((MosaicSequence mosaic) => mosaic.id == ref.id);
    }
  }

  int structuralSourceFrameCount(StructuralSourceRef ref) {
    switch (ref.kind) {
      case StructuralSourceKind.edit:
        return edit(ref.id).projectFrameCount;
      case StructuralSourceKind.mosaic:
        return mosaic(ref.id).projectFrameCount;
    }
  }

  Iterable<EditClip> clipsForStructuralSource(StructuralSourceRef ref) sync* {
    switch (ref.kind) {
      case StructuralSourceKind.edit:
        for (final EditTrack track in edit(ref.id).tracks) {
          yield* track.clips;
        }
        break;
      case StructuralSourceKind.mosaic:
        for (final MosaicPane pane in mosaic(ref.id).panes) {
          yield* pane.clips;
        }
        break;
    }
  }

  EditDryRun dryRun(
    String editId, {
    required bool Function(String source) mediaExists,
  }) {
    final EditSequence sequence = edit(editId);
    final List<String> offline = <String>[];
    for (final EditTrack track in sequence.tracks) {
      for (final EditClip clip in track.clips) {
        if (StructuralSourceRef.tryParse(clip.source) != null) continue;
        if (!mediaExists(clip.source)) offline.add(clip.source);
      }
    }
    return EditDryRun(
      frameCount: sequence.projectFrameCount,
      offlineSources: List<String>.unmodifiable(offline),
    );
  }

  /// Rewrites only one CLIP opening tag. The enclosing TRACK/PANE and root
  /// source, the CLIP body, and every untouched header field remain
  /// byte-for-byte as authored. Callers reparse the returned source to obtain
  /// fresh spans.
  String rewriteClip(
    EditClip clip, {
    String? source,
    int? atFrame,
    int? inFrame,
    int? durationFrames,
    ExactClipSpeed? speed,
  }) {
    _checkClipOwned(clip);

    final List<String> segments = List<String>.from(clip.headerSegments);
    if (source != null) {
      _validateSource(source, clip.block.startOffset);
      segments[1] = source.trim();
    }
    if (atFrame != null) {
      _validateNonNegative('at', atFrame, clip.block.startOffset);
      segments[2] = '$atFrame';
    }
    if (inFrame != null) {
      _validateNonNegative('in', inFrame, clip.block.startOffset);
      segments[3] = '$inFrame';
    }
    if (durationFrames != null) {
      if (durationFrames <= 0) {
        throw ArgumentError.value(
          durationFrames,
          'durationFrames',
          'CLIP duration must be > 0 project frames.',
        );
      }
      segments[4] = '$durationFrames';
    }
    if (speed != null) {
      segments[5] = speed.canonicalMarkup;
    }

    return cst.replaceOpeningTag(clip.block, '[CLIP:${segments.join(':')}]');
  }

  void _checkClipOwned(EditClip clip) {
    for (final EditSequence edit in edits) {
      for (final EditTrack track in edit.tracks) {
        if (track.clips.any((EditClip candidate) => identical(candidate, clip))) {
          return;
        }
      }
    }
    for (final MosaicSequence mosaic in mosaics) {
      for (final MosaicPane pane in mosaic.panes) {
        if (pane.clips.any((EditClip candidate) => identical(candidate, clip))) {
          return;
        }
      }
    }
    throw ArgumentError('The CLIP does not belong to this structural document.');
  }
}

class EditSequence {
  final String id;
  final ScriptCstBlock block;
  final List<EditTrack> tracks;

  EditSequence._({
    required this.id,
    required this.block,
    required this.tracks,
  });

  int get projectFrameCount {
    int end = 0;
    for (final EditTrack track in tracks) {
      final int trackEnd = track.projectFrameCount;
      if (trackEnd > end) end = trackEnd;
    }
    return end;
  }

  EditTrack track(String id) => tracks.singleWhere(
        (EditTrack track) => track.id == id,
        orElse: () =>
            throw StateError('No TRACK named "$id" in EDIT "${this.id}".'),
      );
}

class EditTrack {
  final String id;
  final ScriptCstBlock block;
  final List<EditClip> clips;

  EditTrack._({
    required this.id,
    required this.block,
    required this.clips,
  });

  int get projectFrameCount {
    int end = 0;
    for (final EditClip clip in clips) {
      if (clip.endFrameExclusive > end) end = clip.endFrameExclusive;
    }
    return end;
  }

  EditClip clip(String id) => clips.singleWhere(
        (EditClip clip) => clip.id == id,
        orElse: () =>
            throw StateError('No CLIP named "$id" in TRACK "${this.id}".'),
      );
}

/// One frame-producing Metro composition.
///
/// Pane order owns layout. One pane fills the frame, two split 56/44, and
/// three use the same hero-plus-stack geometry as APP:MOSAIC. A MOSAIC is one
/// composition, not a paged presentation, so more than three panes are
/// rejected rather than silently moved to another page.
class MosaicSequence {
  final String id;
  final ScriptCstBlock block;
  final List<MosaicPane> panes;

  MosaicSequence._({
    required this.id,
    required this.block,
    required this.panes,
  });

  int get projectFrameCount {
    int end = 0;
    for (final MosaicPane pane in panes) {
      final int paneEnd = pane.projectFrameCount;
      if (paneEnd > end) end = paneEnd;
    }
    return end;
  }

  MosaicPane pane(String id) => panes.singleWhere(
        (MosaicPane pane) => pane.id == id,
        orElse: () =>
            throw StateError('No PANE named "$id" in MOSAIC "${this.id}".'),
      );
}

class MosaicPane {
  final String id;
  final ScriptCstBlock block;
  final List<EditClip> clips;

  MosaicPane._({
    required this.id,
    required this.block,
    required this.clips,
  });

  int get projectFrameCount {
    int end = 0;
    for (final EditClip clip in clips) {
      if (clip.endFrameExclusive > end) end = clip.endFrameExclusive;
    }
    return end;
  }

  EditClip clip(String id) => clips.singleWhere(
        (EditClip clip) => clip.id == id,
        orElse: () =>
            throw StateError('No CLIP named "$id" in PANE "${this.id}".'),
      );
}

class EditClip {
  final String id;
  final String source;
  final int atFrame;
  final int inFrame;
  final int durationFrames;
  final ExactClipSpeed speed;
  final ScriptCstBlock block;
  final List<String> headerSegments;

  EditClip._({
    required this.id,
    required this.source,
    required this.atFrame,
    required this.inFrame,
    required this.durationFrames,
    required this.speed,
    required this.block,
    required this.headerSegments,
  });

  int get endFrameExclusive => atFrame + durationFrames;

  /// Returns the integer source frame sampled at one project-frame offset.
  /// The mapping is exact rational arithmetic. Fractional source positions are
  /// floored here because authored source sampling is frame-exact.
  int sourceFrameAtProjectOffset(int projectOffset) {
    if (projectOffset < 0 || projectOffset >= durationFrames) {
      throw RangeError.range(
        projectOffset,
        0,
        durationFrames - 1,
        'projectOffset',
      );
    }
    return inFrame +
        (projectOffset * speed.numerator) ~/ speed.denominator;
  }
}

class EditDryRun {
  final int frameCount;
  final List<String> offlineSources;

  const EditDryRun({
    required this.frameCount,
    required this.offlineSources,
  });

  bool get allMediaOnline => offlineSources.isEmpty;
}

EditSequence _parseEditSequence(ScriptCstBlock editBlock) {
  final String editId = _parseSingleIdHeader(editBlock, 'EDIT');
  final List<EditTrack> tracks = <EditTrack>[];
  final Set<String> trackIds = <String>{};

  for (final ScriptCstBlock trackBlock in editBlock.children) {
    final String trackId = _parseSingleIdHeader(trackBlock, 'TRACK');
    if (!trackIds.add(trackId)) {
      throw EditLanguageFormatException(
        'Duplicate TRACK id "$trackId" inside EDIT "$editId".',
        trackBlock.startOffset,
      );
    }

    tracks.add(
      EditTrack._(
        id: trackId,
        block: trackBlock,
        clips: _parseOwnedClips(
          trackBlock,
          ownerType: 'TRACK',
          ownerId: trackId,
        ),
      ),
    );
  }

  return EditSequence._(
    id: editId,
    block: editBlock,
    tracks: List<EditTrack>.unmodifiable(tracks),
  );
}

MosaicSequence _parseMosaicSequence(ScriptCstBlock mosaicBlock) {
  final String mosaicId = _parseSingleIdHeader(mosaicBlock, 'MOSAIC');
  final List<MosaicPane> panes = <MosaicPane>[];
  final Set<String> paneIds = <String>{};

  for (final ScriptCstBlock paneBlock in mosaicBlock.children) {
    final String paneId = _parseSingleIdHeader(paneBlock, 'PANE');
    if (!paneIds.add(paneId)) {
      throw EditLanguageFormatException(
        'Duplicate PANE id "$paneId" inside MOSAIC "$mosaicId".',
        paneBlock.startOffset,
      );
    }

    panes.add(
      MosaicPane._(
        id: paneId,
        block: paneBlock,
        clips: _parseOwnedClips(
          paneBlock,
          ownerType: 'PANE',
          ownerId: paneId,
        ),
      ),
    );
  }

  if (panes.length > 3) {
    throw EditLanguageFormatException(
      'MOSAIC "$mosaicId" has ${panes.length} panes; one MOSAIC supports at most 3.',
      mosaicBlock.startOffset,
    );
  }

  return MosaicSequence._(
    id: mosaicId,
    block: mosaicBlock,
    panes: List<MosaicPane>.unmodifiable(panes),
  );
}

List<EditClip> _parseOwnedClips(
  ScriptCstBlock owner, {
  required String ownerType,
  required String ownerId,
}) {
  final List<EditClip> clips = <EditClip>[];
  final Set<String> clipIds = <String>{};
  for (final ScriptCstBlock clipBlock in owner.children) {
    final EditClip clip = _parseClip(clipBlock);
    if (!clipIds.add(clip.id)) {
      throw EditLanguageFormatException(
        'Duplicate CLIP id "${clip.id}" inside $ownerType "$ownerId".',
        clipBlock.startOffset,
      );
    }
    clips.add(clip);
  }
  return List<EditClip>.unmodifiable(clips);
}

String _parseSingleIdHeader(ScriptCstBlock block, String type) {
  final String id = block.header.trim();
  if (!_idPattern.hasMatch(id)) {
    throw EditLanguageFormatException(
      '$type header must be one id using letters, numbers, underscore, or hyphen.',
      block.startOffset,
    );
  }
  return id;
}

EditClip _parseClip(ScriptCstBlock block) {
  final List<String> segments = block.header.split(':');
  if (segments.length != 6) {
    throw EditLanguageFormatException(
      'CLIP requires exactly id:source:at:in:duration:speed. '
      'There is no canonical out field.',
      block.startOffset,
    );
  }

  final String id = segments[0].trim();
  if (!_idPattern.hasMatch(id)) {
    throw EditLanguageFormatException('Invalid CLIP id "$id".', block.startOffset);
  }

  final String source = segments[1].trim();
  _validateSource(source, block.startOffset);

  final int atFrame = _parseFrameField('at', segments[2], block.startOffset);
  final int inFrame = _parseFrameField('in', segments[3], block.startOffset);
  final int durationFrames =
      _parseFrameField('duration', segments[4], block.startOffset);
  if (durationFrames <= 0) {
    throw EditLanguageFormatException(
      'CLIP duration must be > 0 project frames.',
      block.startOffset,
    );
  }

  ExactClipSpeed speed;
  try {
    speed = ExactClipSpeed.parse(segments[5]);
  } on FormatException catch (error) {
    throw EditLanguageFormatException('${error.message}', block.startOffset);
  }

  return EditClip._(
    id: id,
    source: source,
    atFrame: atFrame,
    inFrame: inFrame,
    durationFrames: durationFrames,
    speed: speed,
    block: block,
    headerSegments: List<String>.unmodifiable(segments),
  );
}

int _parseFrameField(String name, String source, int offset) {
  final int? value = int.tryParse(source.trim());
  if (value == null || value < 0) {
    throw EditLanguageFormatException(
      'CLIP $name must be a non-negative integer project/source frame.',
      offset,
    );
  }
  return value;
}

void _validateNonNegative(String name, int value, int offset) {
  if (value < 0) {
    throw EditLanguageFormatException(
      'CLIP $name must be non-negative.',
      offset,
    );
  }
}

void _validateSource(String source, int offset) {
  final String value = source.trim();
  if (value.isEmpty ||
      value.contains(':') ||
      value.contains('\n') ||
      value.contains('\r')) {
    throw EditLanguageFormatException(
      'CLIP source must be one non-empty path segment without colon or newline.',
      offset,
    );
  }
}

final RegExp _idPattern = RegExp(r'^[A-Za-z0-9_-]+$');

int _gcd(int a, int b) {
  a = a.abs();
  b = b.abs();
  while (b != 0) {
    final int next = a % b;
    a = b;
    b = next;
  }
  return a == 0 ? 1 : a;
}
