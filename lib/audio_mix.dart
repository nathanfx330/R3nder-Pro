// ./lib/audio_mix.dart

// =====================================================================
// WHY THIS EXISTS
//
// Preview and BAKE deliberately own different audio plumbing. Preview decodes
// to a raw pipe and one realtime sink. BAKE hands files to ffmpeg and muxes
// them beside rendered video. They should not share process state, playback
// state, or timing authority.
//
// They do need one spelling for arithmetic that must agree. Voice and music
// already share their gain and sum here. M21 adds a third possible BAKE input:
// program-aligned STRUCT clip audio. The mixer therefore has to describe one,
// two, or three inputs without teaching either consumer about the other's
// plumbing.
//
// This file remains a registry, not a player. It holds no mutable state, spawns
// no process, imports nothing, and owns no clock.
//
// =====================================================================
// WHY normalize=0
//
// amix defaults to normalize=1, which divides the sum by the number of inputs.
// Attaching another track would therefore change the level of tracks that were
// already authored, with no fader moved and nothing said. R3nder refuses that
// hidden opinion. The authored gains are the mix.
//
// The cost is real and intentional. Hot tracks can sum past full scale. Both
// preview and BAKE may then clip at their eventual integer/codec boundary.
// Automatic limiting or normalization here would be another invisible mix
// decision, so neither is applied.
//
// dropout_transition is pinned rather than left at ffmpeg's default. Under
// normalize=0 it has no level to renormalize today, but pinning it prevents a
// future normalize change from silently adding a two-second level ramp.

const String _kMixTail =
    'normalize=0:dropout_transition=0:duration=longest';

/// Historical two-bed spelling retained because Preview already consumes it.
const String kBedMixFilter = 'amix=inputs=2:$_kMixTail';

/// Returns the deterministic amix spelling for [inputCount] contributors.
///
/// One contributor does not need amix and is therefore rejected here. Callers
/// that use [audioMixGraph] may still supply one track; that function bypasses
/// the sum and preserves the same per-track gain chain.
String audioMixFilter(int inputCount) {
  if (inputCount < 2) {
    throw ArgumentError.value(
      inputCount,
      'inputCount',
      'amix requires at least two contributors.',
    );
  }
  return inputCount == 2
      ? kBedMixFilter
      : 'amix=inputs=$inputCount:$_kMixTail';
}

/// Per-track gain, spelled once so Preview and BAKE attenuate identically.
///
/// Always emitted, including at unity. A graph whose shape changes with the
/// value is a graph that is only exercised at some values, and 0.00dB is a
/// no-op that costs nothing to carry.
String bedVolumeFilter(double gainDb) =>
    'volume=${gainDb.toStringAsFixed(2)}dB';

/// One contributor to a deterministic ffmpeg audio graph.
///
/// [chain] contains caller-owned filters that must run before gain, comma
/// separated, or empty. BAKE uses this for preroll delay on workspace beds.
/// Program STRUCT audio deliberately supplies an empty chain because its WAV
/// is already expressed in absolute program time.
class AudioMixTrack {
  final String input;
  final String label;
  final double gainDb;
  final String chain;

  const AudioMixTrack({
    required this.input,
    required this.label,
    required this.gainDb,
    this.chain = '',
  });
}

String _trackFilterChain(AudioMixTrack track) {
  final String gain = bedVolumeFilter(track.gainDb);
  return track.chain.isEmpty ? gain : '${track.chain},$gain';
}

/// Builds one deterministic audio graph from one or more contributors.
///
/// Every contributor receives its own pre-gain [AudioMixTrack.chain] followed
/// by the shared gain spelling. With two or more contributors those labelled
/// streams are summed with normalize disabled. [postMixChain], when non-empty,
/// runs after the sum. BAKE uses `apad` there so padding cannot influence amix
/// duration semantics.
///
/// For a single contributor there is no amix. The same contributor chain,
/// gain, and optional post-mix chain are emitted directly onto [outputLabel].
String audioMixGraph({
  required List<AudioMixTrack> tracks,
  required String outputLabel,
  String postMixChain = '',
}) {
  if (tracks.isEmpty) {
    throw ArgumentError.value(
      tracks,
      'tracks',
      'At least one audio contributor is required.',
    );
  }
  if (outputLabel.trim().isEmpty) {
    throw ArgumentError.value(
      outputLabel,
      'outputLabel',
      'Output label cannot be empty.',
    );
  }

  final Set<String> labels = <String>{};
  for (final AudioMixTrack track in tracks) {
    if (track.input.trim().isEmpty) {
      throw ArgumentError('Audio contributor input cannot be empty.');
    }
    if (track.label.trim().isEmpty) {
      throw ArgumentError('Audio contributor label cannot be empty.');
    }
    if (!labels.add(track.label)) {
      throw ArgumentError('Duplicate audio contributor label "${track.label}".');
    }
    if (track.label == outputLabel) {
      throw ArgumentError(
        'Audio contributor label "${track.label}" cannot equal the output label.',
      );
    }
  }

  String appendPostMix(String chain) {
    return postMixChain.isEmpty ? chain : '$chain,$postMixChain';
  }

  if (tracks.length == 1) {
    final AudioMixTrack track = tracks.single;
    return '[${track.input}]'
        '${appendPostMix(_trackFilterChain(track))}'
        '[$outputLabel]';
  }

  final StringBuffer graph = StringBuffer();
  for (int i = 0; i < tracks.length; i++) {
    final AudioMixTrack track = tracks[i];
    if (i > 0) graph.write(';');
    graph.write(
      '[${track.input}]${_trackFilterChain(track)}[${track.label}]',
    );
  }

  graph.write(';');
  for (final AudioMixTrack track in tracks) {
    graph.write('[${track.label}]');
  }
  graph.write(audioMixFilter(tracks.length));
  if (postMixChain.isEmpty) {
    graph.write('[$outputLabel]');
  } else {
    const String mixedLabel = 'r3mixpre';
    if (labels.contains(mixedLabel) || mixedLabel == outputLabel) {
      throw ArgumentError(
        'Audio contributor/output labels reserve "$mixedLabel" for post-mix routing.',
      );
    }
    graph.write('[$mixedLabel];[$mixedLabel]$postMixChain[$outputLabel]');
  }

  return graph.toString();
}

/// The historical voice/music graph used by Preview and existing BAKE paths.
///
/// Keeping this wrapper preserves the exact two-bed graph while the generic
/// mixer becomes available for M21's third structural contributor.
String bedMixGraph({
  required double voiceGainDb,
  required double musicGainDb,
  String voiceChain = '',
  String musicChain = '',
  String voiceInput = '0:a',
  String musicInput = '1:a',
}) {
  return audioMixGraph(
    tracks: <AudioMixTrack>[
      AudioMixTrack(
        input: voiceInput,
        label: 'bedvo',
        gainDb: voiceGainDb,
        chain: voiceChain,
      ),
      AudioMixTrack(
        input: musicInput,
        label: 'bedmus',
        gainDb: musicGainDb,
        chain: musicChain,
      ),
    ],
    outputLabel: kBedMixOutLabel,
  );
}

/// Label the historical two-bed stream lands on. Preview maps this by name.
const String kBedMixOutLabel = 'bedmix';
