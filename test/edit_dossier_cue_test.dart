// ./test/edit_dossier_cue_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/dossier_overlay_state.dart';
import 'package:r3nder/edit_cue.dart';
import 'package:r3nder/edit_model.dart';
import 'package:r3nder/presentation_requests.dart';

const String _source = '''[EDIT:main]
  [TRACK:V1]
    [CLIP:shot:video/shot.mp4:0:0:300:1]
      [CUE:90]
        [DOSSIER:evidence:person.png:10:20:0:MOSAIC:24,32,40:JOHN SMITH]
          Biography text.
        [/DOSSIER]
      [/CUE]
      [CUE:260]
        [CARD:overlay.png:10:30,30,38:FULL CARD]
          Fullscreen text.
        [/CARD]
      [/CUE]
    [/CLIP]
  [/TRACK]
[/EDIT]
''';

void main() {
  test('DOSSIER is a valid CUE without becoming a CARD-family cue', () {
    final EditDocumentModel model = EditDocumentModel.parse(_source);
    final EditClip clip = model.edit('main').tracks.single.clips.single;

    final List<EditDossierCue> dossiers = parseClipDossierCues(clip);
    final List<EditCardCue> cards = parseClipCardCues(clip);

    expect(dossiers, hasLength(1));
    expect(cards, hasLength(1));

    final EditDossierCue cue = dossiers.single;
    expect(cue.sourceFrame, 90);
    expect(cue.dossier.folder, 'evidence');
    expect(cue.dossier.image, 'person.png');
    expect(cue.dossier.holdSplit, 10);
    expect(cue.dossier.holdFull, 20);
    expect(cue.dossier.cardLead, 0);
    expect(cue.dossier.centerMode, DossierCenterMode.mosaic);
    expect(cue.dossier.heading, 'JOHN SMITH');
    expect(cue.dossier.body, 'Biography text.');

    expect(cards.single.sourceFrame, 260);
    expect(cards.single.card.heading, 'FULL CARD');
  });

  test('structural DOSSIER projects exact timing after source-relative trigger', () {
    final EditDocumentModel model = EditDocumentModel.parse(_source);
    final StructuralSourceRef root = StructuralSourceRef.tryParse('EDIT.main')!;

    StructuralDossierOverlayPlacement? at(int projectFrame) =>
        structuralDossierPlacement(
          model,
          root,
          projectFrame,
          centerPageCountFor: (_) => 3,
        );

    final StructuralDossierOverlayPlacement first = at(90)!;
    expect(first.localFrame, 0);
    expect(first.presentationFrame.stage, DossierPresentationStage.opening);
    expect(structuralDossierShellSlide(first), 0.0);

    final StructuralDossierOverlayPlacement lastOpening = at(105)!;
    expect(lastOpening.presentationFrame.stage, DossierPresentationStage.opening);
    expect(structuralDossierShellSlide(lastOpening), closeTo(15 / 16, 0.000001));

    final StructuralDossierOverlayPlacement split = at(106)!;
    expect(split.presentationFrame.stage, DossierPresentationStage.splitShowing);
    expect(structuralDossierShellSlide(split), 1.0);

    final StructuralDossierOverlayPlacement center = at(128)!;
    expect(center.presentationFrame.stage, DossierPresentationStage.centerShowing);
    expect(center.presentationFrame.centerPageIndex, 0);

    final StructuralDossierOverlayPlacement pan = at(148)!;
    expect(pan.presentationFrame.stage, DossierPresentationStage.centerPanning);
    expect(pan.presentationFrame.centerPageIndex, 0);

    final StructuralDossierOverlayPlacement last = at(243)!;
    expect(last.presentationFrame.stage, DossierPresentationStage.closing);
    expect(structuralDossierShellSlide(last), closeTo(1 / 12, 0.000001));

    expect(at(244), isNull);
  });

  test('source end keeps exact DOSSIER shell displacement for STRUCT close', () {
    final EditDocumentModel model = EditDocumentModel.parse(_source);
    final StructuralSourceRef root = StructuralSourceRef.tryParse('EDIT.main')!;

    final StructuralDossierOverlayPlacement? end =
        structuralDossierPlacementAtSourceEnd(
      model,
      root,
      200,
      centerPageCountFor: (_) => 3,
    );

    expect(end, isNotNull);
    expect(end!.localFrame, 109);
    expect(end.presentationFrame.stage, DossierPresentationStage.centerPanning);
    expect(structuralDossierShellSlide(end), 1.0);
  });
}
