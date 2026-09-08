// ./test/render_naming_test.dart

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/render_naming.dart';

void main() {
  test('sanitizeRenderName produces portable stable stems', () {
    expect(sanitizeRenderName(' Documentary Cut '), 'Documentary_Cut');
    expect(sanitizeRenderName('paper/trail:final?.mp4'), 'paper_trail_final');
    expect(sanitizeRenderName('...'), 'output');
    expect(sanitizeRenderName('  ', fallback: 'my render'), 'my_render');
  });

  test('first render starts at v001', () {
    final Directory root =
        Directory.systemTemp.createTempSync('r3_render_name_first_');
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    final RenderOutputPlan plan = planNextRenderOutput(
      directoryPath: root.path,
      renderName: 'documentary_cut',
      resolutionLabel: '1080p',
      extension: 'mp4',
    );

    expect(plan.version, 1);
    expect(plan.versionLabel, 'v001');
    expect(plan.fileName, 'documentary_cut_1080p_v001.mp4');
    expect(plan.mattePath, isNull);
  });

  test('versioning is monotonic and does not reuse deleted holes', () {
    final Directory root =
        Directory.systemTemp.createTempSync('r3_render_name_monotonic_');
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    File('${root.path}/cut_1080p_v001.mp4').writeAsStringSync('1');
    File('${root.path}/cut_1080p_v003.mp4').writeAsStringSync('3');

    final RenderOutputPlan plan = planNextRenderOutput(
      directoryPath: root.path,
      renderName: 'cut',
      resolutionLabel: '1080p',
      extension: 'mp4',
    );

    expect(plan.version, 4);
    expect(plan.fileName, 'cut_1080p_v004.mp4');
  });

  test('versions continue across container format changes', () {
    final Directory root =
        Directory.systemTemp.createTempSync('r3_render_name_format_');
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    File('${root.path}/master_4K_v007.mp4').writeAsStringSync('7');

    final RenderOutputPlan plan = planNextRenderOutput(
      directoryPath: root.path,
      renderName: 'master',
      resolutionLabel: '4K',
      extension: 'mov',
    );

    expect(plan.version, 8);
    expect(plan.fileName, 'master_4K_v008.mov');
  });

  test('fill and matte reserve one version family together', () {
    final Directory root =
        Directory.systemTemp.createTempSync('r3_render_name_matte_');
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    File('${root.path}/comp_1080p_v002_matte.mp4').writeAsStringSync('matte');

    final RenderOutputPlan plan = planNextRenderOutput(
      directoryPath: root.path,
      renderName: 'comp',
      resolutionLabel: '1080p',
      extension: '.mp4',
      includeMatteCompanion: true,
    );

    expect(plan.version, 3);
    expect(plan.fileName, 'comp_1080p_v003.mp4');
    expect(plan.matteFileName, 'comp_1080p_v003_matte.mp4');
  });

  test('preroll and ordinary bakes keep separate version families', () {
    final Directory root =
        Directory.systemTemp.createTempSync('r3_render_name_preroll_');
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    File('${root.path}/cut_1080p_v004.mp4').writeAsStringSync('normal');
    File('${root.path}/preroll_cut_1080p_v002.mp4')
        .writeAsStringSync('preroll');

    final RenderOutputPlan normal = planNextRenderOutput(
      directoryPath: root.path,
      renderName: 'cut',
      resolutionLabel: '1080p',
      extension: 'mp4',
    );
    final RenderOutputPlan preroll = planNextRenderOutput(
      directoryPath: root.path,
      renderName: 'cut',
      resolutionLabel: '1080p',
      extension: 'mp4',
      preroll: true,
    );

    expect(normal.fileName, 'cut_1080p_v005.mp4');
    expect(preroll.fileName, 'preroll_cut_1080p_v003.mp4');
  });

  test('last non-empty RENDERNAME config wins', () {
    const String document = '''
[CONFIG:RENDERNAME:first_cut]
[CONFIG:SIZE:48]
[CONFIG:RENDERNAME:   ]
[CONFIG:RENDERNAME:Documentary Cut]
''';

    expect(renderNameFromDocument(document), 'Documentary Cut');
    expect(renderNameFromDocument('[CONFIG:SIZE:48]'), isNull);
    expect(renderNameFromDocument(null), isNull);
  });

  test('dashboard output path adopts custom render name and version', () {
    final Directory root =
        Directory.systemTemp.createTempSync('r3_render_name_dashboard_');
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    final RenderOutputPlan first = planVersionedDashboardOutput(
      requestedOutputPath: '${root.path}/output_1080p.mp4',
      renderNameOverride: 'Documentary Cut',
    );
    expect(first.fileName, 'Documentary_Cut_1080p_v001.mp4');

    File(first.outputPath).writeAsStringSync('first');
    final RenderOutputPlan second = planVersionedDashboardOutput(
      requestedOutputPath: '${root.path}/output_1080p.mp4',
      renderNameOverride: 'Documentary Cut',
    );
    expect(second.fileName, 'Documentary_Cut_1080p_v002.mp4');
  });

  test('dashboard preroll path preserves its separate version family', () {
    final Directory root =
        Directory.systemTemp.createTempSync('r3_render_name_dash_preroll_');
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    File('${root.path}/preroll_master_4K_v003.mov').writeAsStringSync('3');

    final RenderOutputPlan plan = planVersionedDashboardOutput(
      requestedOutputPath: '${root.path}/preroll_output_4K.mov',
      renderNameOverride: 'master',
    );

    expect(plan.fileName, 'preroll_master_4K_v004.mov');
  });

  test('dashboard recognition leaves direct exporter filenames distinct', () {
    expect(isDashboardBakeOutputPath('/tmp/output_1080p.mp4'), isTrue);
    expect(isDashboardBakeOutputPath('/tmp/preroll_output_4K.mov'), isTrue);
    expect(isDashboardBakeOutputPath('/tmp/test_bake.mp4'), isFalse);
    expect(isDashboardBakeOutputPath('/tmp/final.mp4'), isFalse);
  });
}
