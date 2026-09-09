// ./test/structural_audio_plan_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/edit_model.dart';
import 'package:r3nder/structural_audio_plan.dart';

void main() {
  group('M21 StructuralAudioPlan', () {
    test('project frames map to exact 48k sample positions', () {
      expect(kStructuralAudioSampleRate, 48000);
      expect(kStructuralAudioProjectFps, 30);
      expect(kStructuralAudioSamplesPerProjectFrame, 1600);
      expect(structuralAudioSampleAtProjectFrame(0), 0);
      expect(structuralAudioSampleAtProjectFrame(1), 1600);
      expect(structuralAudioSampleAtProjectFrame(75), 120000);
      expect(structuralAudioSampleAtProjectFrame(90), 144000);
      expect(structuralAudioSamplesForProjectFrames(165), 264000);
    });

    test('equal-power fade uses midpoint samples with no silent endpoint', () {
      final StructuralAudioFade oneIn = StructuralAudioFade(
        direction: StructuralAudioFadeDirection.fadeIn,
        startSample: 0,
        sampleCount: 1,
      );
      final StructuralAudioFade oneOut = StructuralAudioFade(
        direction: StructuralAudioFadeDirection.fadeOut,
        startSample: 0,
        sampleCount: 1,
      );

      final double oneInGain = oneIn.gainAtOffset(0);
      final double oneOutGain = oneOut.gainAtOffset(0);
      expect(oneInGain, greaterThan(0.0));
      expect(oneOutGain, greaterThan(0.0));
      expect(
        oneInGain * oneInGain + oneOutGain * oneOutGain,
        closeTo(1.0, 1e-12),
      );

      final StructuralAudioFade twoIn = StructuralAudioFade(
        direction: StructuralAudioFadeDirection.fadeIn,
        startSample: 100,
        sampleCount: 2,
      );
      final StructuralAudioFade twoOut = StructuralAudioFade(
        direction: StructuralAudioFadeDirection.fadeOut,
        startSample: 100,
        sampleCount: 2,
      );

      for (int i = 0; i < 2; i++) {
        final double inGain = twoIn.gainAtOffset(i);
        final double outGain = twoOut.gainAtOffset(i);
        expect(inGain, greaterThan(0.0));
        expect(outGain, greaterThan(0.0));
        expect(inGain, lessThan(1.0));
        expect(outGain, lessThan(1.0));
        expect(
          inGain * inGain + outGain * outGain,
          closeTo(1.0, 1e-12),
        );
      }
    });

    test('two-clip EDIT plans exact overlap fades and rational speed', () {
      const String source = '''[EDIT:main]
[TRACK:V1]
[CLIP:A:a.mp4:0:30:90:1]
[#EDIT_TRANSITION_OUT:CROSSFADE:15]
[/CLIP]
[CLIP:B:b.mp4:75:0:90:4/5]
[#EDIT_TRANSITION:CROSSFADE:15]
[/CLIP]
[/TRACK]
[/EDIT]
''';

      final StructuralAudioPlan plan =
          StructuralAudioPlanner.parse(source).plan('EDIT.main');
      final StructuralAudioLanePlan v1 = plan.lane('V1');
      final StructuralAudioSegment a = v1.segment('A');
      final StructuralAudioSegment b = v1.segment('B');

      expect(plan.durationFrames, 165);
      expect(plan.durationSamples, 264000);

      expect(a.projectStartSample, 0);
      expect(a.projectEndSampleExclusive, 144000);
      expect(a.outgoingFade, isNotNull);
      expect(a.outgoingFade!.startSample, 120000);
      expect(a.outgoingFade!.sampleCount, 24000);
      expect(a.outgoingFade!.endSampleExclusive, 144000);

      expect(b.projectStartSample, 120000);
      expect(b.projectEndSampleExclusive, 264000);
      expect(b.incomingFade, isNotNull);
      expect(b.incomingFade!.startSample, 120000);
      expect(b.incomingFade!.sampleCount, 24000);
      expect(b.speed, ExactClipSpeed(4, 5));
      expect(b.sourceFrameAtProjectOffset(89), 71);
      expect(b.sourceBoundaryNumeratorAtProjectOffset(90), 360);
      expect(b.sourceBoundaryDenominator, 5);
    });

    test('every authored V-track clip is planned before audio probing', () {
      const String source = '''[EDIT:main]
[TRACK:V2]
[CLIP:overlay:overlay.mp4:12:0:10:1]
[/CLIP]
[/TRACK]
[TRACK:V1]
[CLIP:picture_only:picture_only.mp4:0:0:30:1]
[/CLIP]
[/TRACK]
[/EDIT]
''';

      final StructuralAudioPlan plan =
          StructuralAudioPlanner.parse(source).plan('EDIT.main');

      // Planner order follows picture depth, not declaration order.
      expect(plan.lanes.map((StructuralAudioLanePlan lane) => lane.id),
          <String>['V1', 'V2']);
      expect(plan.segments.length, 2);
      expect(plan.lane('V1').segment('picture_only').isLeafMedia, isTrue);
      expect(plan.lane('V2').segment('overlay').isLeafMedia, isTrue);
    });

    test('MOSAIC keeps pane-local geometry and recurses into EDIT plans', () {
      const String source = '''[EDIT:main]
[TRACK:V1]
[CLIP:talk:talk.mp4:0:0:40:1]
[/CLIP]
[/TRACK]
[/EDIT]
[MOSAIC:wall]
[PANE:pane1]
[CLIP:primary:EDIT.main:10:5:20:1]
[/CLIP]
[/PANE]
[PANE:pane2]
[CLIP:secondary:EDIT.main:0:0:10:1]
[/CLIP]
[/PANE]
[/MOSAIC]
''';

      final StructuralAudioPlan plan =
          StructuralAudioPlanner.parse(source).plan('MOSAIC.wall');
      final StructuralAudioSegment primary =
          plan.lane('pane1').segment('primary');
      final StructuralAudioSegment secondary =
          plan.lane('pane2').segment('secondary');

      expect(plan.durationFrames, 30);
      expect(plan.durationSamples, 48000);
      expect(plan.lanes.length, 2);

      expect(primary.projectStartSample, 16000);
      expect(primary.sourceInFrame, 5);
      expect(primary.isStructural, isTrue);
      expect(primary.nestedPlan!.sourceRef.canonicalSource, 'EDIT.main');
      expect(primary.nestedPlan!.durationFrames, 40);

      expect(secondary.projectStartSample, 0);
      expect(secondary.isStructural, isTrue);
      expect(secondary.nestedPlan!.sourceRef.canonicalSource, 'EDIT.main');
    });

    test('graph errors fail before a recursive audio plan is built', () {
      const String source = '''[EDIT:a]
[TRACK:V1]
[CLIP:to_b:EDIT.b:0:0:10:1]
[/CLIP]
[/TRACK]
[/EDIT]
[EDIT:b]
[TRACK:V1]
[CLIP:to_a:EDIT.a:0:0:10:1]
[/CLIP]
[/TRACK]
[/EDIT]
''';

      expect(
        () => StructuralAudioPlanner.parse(source).plan('EDIT.a'),
        throwsA(isA<StructuralAudioPlanException>()),
      );
    });

    test('crossfade geometry cannot exceed the authored clip duration', () {
      const String source = '''[EDIT:main]
[TRACK:V1]
[CLIP:short:short.mp4:0:0:4:1]
[#EDIT_TRANSITION:CROSSFADE:5]
[/CLIP]
[/TRACK]
[/EDIT]
''';

      expect(
        () => StructuralAudioPlanner.parse(source).plan('EDIT.main'),
        throwsA(isA<StructuralAudioPlanException>()),
      );
    });
  });
}
