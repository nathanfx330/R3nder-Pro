// ./test/audio_mix_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/audio_mix.dart';

void main() {
  test('legacy voice plus music graph keeps its exact spelling', () {
    expect(
      bedMixGraph(
        voiceGainDb: -3.0,
        musicGainDb: -6.5,
        voiceChain: 'adelay=120:all=1',
        musicChain: 'adelay=120:all=1',
        voiceInput: '1:a',
        musicInput: '2:a',
      ),
      '[1:a]adelay=120:all=1,volume=-3.00dB[bedvo];'
      '[2:a]adelay=120:all=1,volume=-6.50dB[bedmus];'
      '[bedvo][bedmus]'
      'amix=inputs=2:normalize=0:dropout_transition=0:duration=longest'
      '[bedmix]',
    );
  });

  test('three-way BAKE graph delays beds but not program STRUCT audio', () {
    final String graph = audioMixGraph(
      tracks: const <AudioMixTrack>[
        AudioMixTrack(
          input: '1:a',
          label: 'bedvo',
          gainDb: -2.0,
          chain: 'adelay=250:all=1',
        ),
        AudioMixTrack(
          input: '2:a',
          label: 'bedmus',
          gainDb: -8.0,
          chain: 'adelay=250:all=1',
        ),
        AudioMixTrack(
          input: '3:a',
          label: 'bedstruct',
          gainDb: 0.0,
        ),
      ],
      outputLabel: 'bedout',
      postMixChain: 'apad',
    );

    expect(
      graph,
      '[1:a]adelay=250:all=1,volume=-2.00dB[bedvo];'
      '[2:a]adelay=250:all=1,volume=-8.00dB[bedmus];'
      '[3:a]volume=0.00dB[bedstruct];'
      '[bedvo][bedmus][bedstruct]'
      'amix=inputs=3:normalize=0:dropout_transition=0:duration=longest'
      '[r3mixpre];[r3mixpre]apad[bedout]',
    );
    expect(graph, contains('[3:a]volume=0.00dB[bedstruct]'));
    expect(graph, isNot(contains('[3:a]adelay=')));
  });

  test('one contributor skips amix but still receives gain and post chain', () {
    expect(
      audioMixGraph(
        tracks: const <AudioMixTrack>[
          AudioMixTrack(
            input: '1:a',
            label: 'bedstruct',
            gainDb: 0.0,
          ),
        ],
        outputLabel: 'bedout',
        postMixChain: 'apad',
      ),
      '[1:a]volume=0.00dB,apad[bedout]',
    );
  });

  test('generic graph rejects empty and duplicate contributor sets', () {
    expect(
      () => audioMixGraph(
        tracks: const <AudioMixTrack>[],
        outputLabel: 'bedout',
      ),
      throwsArgumentError,
    );

    expect(
      () => audioMixGraph(
        tracks: const <AudioMixTrack>[
          AudioMixTrack(input: '1:a', label: 'same', gainDb: 0.0),
          AudioMixTrack(input: '2:a', label: 'same', gainDb: 0.0),
        ],
        outputLabel: 'bedout',
      ),
      throwsArgumentError,
    );
  });
}
