// ./lib/audio_mix.dart

// =====================================================================
// WHY THIS EXISTS
//
// Two beds have to be summed in two places: the preview pipeline in
// audio_bed.dart, and the mux in exporter.dart. Those two are deliberately
// unrelated code paths. The header of audio_bed.dart says so in as many
// words, and it is right to: preview decodes to a raw pipe and a sink,
// export hands the original files to ffmpeg at full quality, and neither
// should acquire a dependency on the other's plumbing.
//
// Which leaves one fact that has to be true in both: HOW the two tracks are
// summed. If the preview sums them one way and the bake sums them another,
// the balance you rode a fader to find is not the balance that lands on
// disk, and nothing on screen says so. That is the same class of silent
// defect the CONFIG key list produced when two surfaces enumerated it by
// hand, and it gets the same answer: one list, read by both.
//
// So this file is a registry, not a library. It holds no state, spawns no
// process, and imports nothing. audio_bed.dart may read it and exporter.dart
// may read it without either learning anything about the other.
//
// =====================================================================
// WHY normalize=0
//
// amix defaults to normalize=1, which divides the sum by the number of
// inputs. Attaching a music bed would therefore drop the voice by 6dB on
// its own, with no fader moved and nothing said. audio_bed.dart already
// refuses to peak-normalize the preview for exactly this reason: a level
// the tool quietly changed is a level the preview is lying about.
//
// The cost is real and is the honest one. With normalize=0 two hot tracks
// can sum past full scale, and both the s16le preview pipe and the encoder
// clip hard when they do. That is what the per-track gain controls are for.
// A limiter here would be an opinion about someone's mix, applied to every
// mix, and invisible in the one place the mix is supposed to be audible.
//
// dropout_transition is pinned rather than left default. Under normalize=0
// it has nothing to renormalize and so does nothing today. It is written
// down anyway because the day someone tries normalize=1 to chase a clip,
// the default would add a two second level ramp at the moment one track
// ends, which reads as a mix problem rather than as a flag that was set.

/// The sum itself. Two inputs, no automatic level change, longest wins.
///
/// Duration is bounded downstream in both consumers rather than here: the
/// preview trims with an output `-t` at the picture's remaining length, and
/// the bake trims with an output `-t` at the video duration. `longest` is
/// therefore the right input-side answer in both, because trimming is the
/// caller's fact and not the mixer's.
const String kBedMixFilter =
    'amix=inputs=2:normalize=0:dropout_transition=0:duration=longest';

/// Per-track gain, spelled once so preview and bake attenuate identically.
///
/// Always emitted, including at unity. A graph whose shape changes with the
/// value is a graph that is only exercised at some values, and 0.00dB is a
/// no-op that costs nothing to carry.
String bedVolumeFilter(double gainDb) =>
    'volume=${gainDb.toStringAsFixed(2)}dB';

/// The full two-track graph, ending on the label [kBedMixOutLabel].
///
/// [voiceChain] and [musicChain] are any extra per-track filters the caller
/// needs applied BEFORE the sum, comma separated, or empty. The preview has
/// none. The bake has adelay (parking both beds behind the preroll wipe in
/// real silence) and apad.
///
/// The gain filter is appended by this function rather than passed in, so
/// that neither caller can forget it and neither can put it on the wrong
/// side of a delay.
String bedMixGraph({
  required double voiceGainDb,
  required double musicGainDb,
  String voiceChain = '',
  String musicChain = '',
  String voiceInput = '0:a',
  String musicInput = '1:a',
}) {
  String chain(String extra, double gainDb) {
    final String g = bedVolumeFilter(gainDb);
    return extra.isEmpty ? g : '$extra,$g';
  }

  return '[$voiceInput]${chain(voiceChain, voiceGainDb)}[bedvo];'
      '[$musicInput]${chain(musicChain, musicGainDb)}[bedmus];'
      '[bedvo][bedmus]$kBedMixFilter[$kBedMixOutLabel]';
}

/// Label the mixed stream lands on. Both consumers map this by name, so it
/// is written once for the same reason the filter is.
const String kBedMixOutLabel = 'bedmix';