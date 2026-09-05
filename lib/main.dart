// ./lib/main.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import 'engine.dart';
import 'project_clock.dart';
import 'parser.dart';
import 'scene_engine.dart';
import 'scene_evaluator.dart';
import 'program_preview_surface.dart';
import 'exporter.dart';
import 'editor_screen.dart';
import 'app_info.dart';
import 'asset_manager.dart';
import 'audio_bed.dart';
import 'session_store.dart';
import 'diag.dart';
import 'script_pipeline.dart';
import 'editor_warmup.dart';
import 'ui_theme.dart';

/// The active phosphor color, lifted to app level so the MaterialApp theme
/// (dialogs, snackbars, text fields, chips) re-tints when the preset
/// changes. R3nderHome writes to it; R3nderApp listens.
final ValueNotifier<Color> phosphorNotifier =
    ValueNotifier(const Color(0xFF00FF00));

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  WindowOptions windowOptions = const WindowOptions(
    size: Size(1280, 720),
    center: true,
    title: 'R3nder : Terminal Engine',
  );

  windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    await windowManager.focus();
  });

  runApp(const R3nderApp());
}

class R3nderApp extends StatelessWidget {
  const R3nderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Color>(
      valueListenable: phosphorNotifier,
      builder: (context, phosphor, _) {
        return MaterialApp(
          title: 'R3nder',
          theme: R3Theme.of(phosphor).materialTheme(),
          home: const R3nderHome(),
          debugShowCheckedModeBanner: false,
        );
      },
    );
  }
}

/// Placeholder occupying the template dropdown when templates/ is empty.
/// A constant rather than four string literals: three of the four call
/// sites compared against it, and a typo in any of them would read as a
/// real filename.
const String kNoTemplates = "No .txt files found";

enum AppState { menu, settings, preview, baking, editor, assets }

class R3nderHome extends StatefulWidget {
  const R3nderHome({super.key});

  @override
  State<R3nderHome> createState() => _R3nderHomeState();
}

class _R3nderHomeState extends State<R3nderHome> with SingleTickerProviderStateMixin, WindowListener {
  // --- UI State ---
  AppState _currentState = AppState.menu;
  String _selectedRes = "1080p";
  int _idxTemplate = 0;
  int _idxFont = 0;
  bool _isLoadingScene = false;

  // R3nder specific defaults
  double _customFontSize = 48.0;
  double _customLineSpacing = 60.0;
  double _customTracking = 0.0;
  double _customMarginTop = 100.0;
  double _customMarginSide = 100.0;

  String _settingFolderName = "output_frames";

  /// Which container and alpha strategy BAKE produces. Was a boolean when
  /// there were only two options; a third made the boolean a lie.
  VideoExportFormat _exportFormat = VideoExportFormat.h264Solid;

  /// True for any format that needs the scene rendered on a transparent
  /// background rather than composited over the script's bg color. Both
  /// alpha formats need it, which is precisely what the old boolean could
  /// no longer express.
  bool get _rendersAlpha => _exportFormat != VideoExportFormat.h264Solid;

  /// Preroll stays available under every format. It bundles two things: a
  /// solid chroma plate, and the wipe-on plus zoom-up reveal. Only the plate
  /// is redundant under alpha, and ScenePainter simply omits it there, so
  /// the reveal plays over transparency instead of over green.
  ///
  /// An earlier version of this disabled preroll entirely for alpha formats.
  /// That threw away the choreography to avoid the plate, which is the wrong
  /// trade: the wipe is the interesting half.
  bool _settingIncludePreroll = false;
  Color _settingPrerollColor = const Color(0xFF00FF00); // Green or Magenta

  Color _fontColor = const Color(0xFF00FF00);
  Color _bgColor = const Color(0xFF0A0F0A);

  /// Design system built from the active phosphor. Rebuilt in build();
  /// cheap (pure color math).
  R3Theme get _t => R3Theme.of(_fontColor);

  /// Pushes the phosphor to the app-level notifier so the MaterialApp
  /// theme re-tints. Call after any change to _fontColor.
  void _syncPhosphor() {
    phosphorNotifier.value = _fontColor;
  }

  // --- Engine State ---
  late final SceneEngine _scene;

  /// Authoritative realtime project clock.
  ///
  /// The Flutter Ticker is only a polling cadence. It samples this clock,
  /// asks the scene to evaluate toward that explicit ProjectTime, then asks
  /// the preview subtree to repaint when scene state actually advances.
  late final NativeRealtimeProjectClock _projectClock;
  late final Ticker _ticker;

  List<String> _availableTemplates = [];
  List<String> _availableFonts = ["monospace"];

  /// Currently selected template filename, clamped.
  ///
  /// Both lists are rescanned asynchronously (fonts) or on workspace
  /// switch (templates), so an index held across one of those can briefly
  /// point past the end. Indexing directly, which five call sites used to
  /// do, turns that window into a range crash rather than a stale label.
  String get _activeTemplate => _availableTemplates.isEmpty
      ? kNoTemplates
      : _availableTemplates[
          _idxTemplate.clamp(0, _availableTemplates.length - 1)];

  String get _activeFont => _availableFonts.isEmpty
      ? "monospace"
      : _availableFonts[_idxFont.clamp(0, _availableFonts.length - 1)];

  String _docText = "";

  // --- Editor warm-up ---
  //
  // The dashboard is idle while you read it and the document is already
  // loaded, so the simulation the editor would otherwise make you wait for
  // happens here instead, against time that was going to be spent anyway.
  //
  // HELD, NEVER SHARED. _buildEditor hands this over and nulls it in the
  // same breath, after which the editor owns it outright. See the
  // ownership note on EditorScreen.warmup: this is the opposite of the bed
  // player's rule, because a warm holds a decoded asset library that leaks
  // if nobody takes responsibility for it.

  /// A finished simulation, or null when none is prepared or the last one
  /// went stale. Null is always safe: it means a cold open, which is what
  /// every open cost before this existed.
  EditorWarmup? _warm;

  /// Bumped by everything that invalidates a warm. A build in flight
  /// compares against this on completion and throws itself away rather
  /// than storing a result derived from superseded inputs.
  int _warmGeneration = 0;

  Timer? _warmDebounce;

  /// The bundle handed to the editor. Split from [_warm] because
  /// _buildEditor runs on every rebuild while the editor is open, and
  /// ownership must transfer exactly once, at the moment of opening.
  /// EditorScreen.initState consumes it on its first frame; later rebuilds
  /// pass the same spent object, which the isSpent check ignores.
  EditorWarmup? _pendingWarm;

  /// True while a build is in flight, so the scheduler cannot stack
  /// several full asset decodes on top of each other.
  bool _warmBuilding = false;

  String? _desktopWallpaper; // From [CONFIG:DESKTOP:...], null = classic mode
  String? _windowTitle; // From [CONFIG:WINTITLE:...], null = default title
  // Parsed macro declarations used to be cached here for _setupScene to
  // hand to injectMacros. compileScript does its own parse now, so these
  // were write-only: assigned on every template load and read by nothing.

  /// Latest asset scan of the loaded template against the active workspace.
  /// Null until the first template loads. Refreshed on template load/apply,
  /// on workspace switch, and when the asset manager closes — so the menu
  /// badge is always current without ever scanning during playback.
  AssetScanResult? _assetScan;

  // --- Audio Bed State ---
  //
  // The bed is a workspace property, not a script property: audio is an
  // ingredient, so the same template pointed at a different workspace picks
  // up that workspace's voiceover. Nothing about the bed appears in the
  // markup, and neither engine ever learns it exists.

  /// Null when no playback backend (paplay/aplay) exists on this machine.
  /// Playback is disabled in that case; export is not, because baking needs
  /// no sink.
  AudioBedPlayer? _bedPlayer;

  /// Sinks present right now. Re-enumerated on demand, not cached forever:
  /// USB interfaces and Bluetooth sinks come and go while the app is open.
  List<PlaybackDevice> _bedDevices = const [];

  /// Selected sink id. Persisted at app level, NOT in the workspace: a sink
  /// name is a property of this machine, so carrying it between workspaces
  /// is right and carrying it between boxes is not.
  String? _bedDeviceId;

  /// Bed filename relative to `<workspace>/audio/`. Empty means no bed.
  String _bedFileName = "";

  /// Files currently sitting in `<workspace>/audio/`, for the picker.
  List<String> _availableBedFiles = const [];

  /// Probe of the selected bed. Null when nothing is selected.
  AudioBedInfo? _bedInfo;

  /// Preview and export gain in dB. Applied by ffmpeg in both paths, so the
  /// level you hear scrubbing is the level that lands in the mux.
  double _bedGainDb = 0.0;

  /// Guards one-shot playback start inside _onTick. The bed begins when the
  /// terminal engine takes its first tick, which is after the preroll wipe
  /// with preroll on and immediately without it, so the same test covers
  /// both paths.
  bool _bedStartedThisRun = false;

  /// Debounce for workspace.json writes while the gain slider is dragging.
  Timer? _bedGainSaveTimer;

  // --- Music bed ---
  //
  // A second track, summed with the voice bed rather than replacing it, and
  // deliberately NOT its peer. The voice bed owns the length of the piece: a
  // trailing voiceover line is content, and the end hold stretches to let it
  // finish. Music is trimmed to picture instead, because no amount of score
  // is a reason to hold on a settled terminal, and because dropping a four
  // minute track onto a forty second cut must not produce a four minute
  // render.
  //
  // The consequence lives in _reprobeMusic: it never calls _scheduleWarm.
  // The voice bed does, because its length moves the total frame count and
  // therefore belongs in ScriptWarmKey. Music cannot move a frame boundary,
  // so attaching, swapping, or re-gaining a score costs no re-simulation at
  // all. If that call is ever added here for symmetry, it is wrong.

  /// Music filename relative to `<workspace>/audio/`. Empty means no score.
  ///
  /// Picked from the same folder and the same scanned list as the bed. They
  /// are two roles, not two libraries, and nothing stops the same file being
  /// chosen for both, which is a mix decision and not an error.
  String _musicFileName = "";

  /// Probe of the selected music file. Null when nothing is selected.
  ///
  /// Read for the status line and to decide whether to hand the file to
  /// ffmpeg. Its frame count reaches no arithmetic that decides how long
  /// anything runs.
  AudioBedInfo? _musicInfo;

  /// Music gain in dB, applied before the sum.
  ///
  /// This and [_bedGainDb] are the only controls over the balance, on
  /// purpose. The sum does not renormalize (see audio_mix.dart), so riding
  /// these two faders IS the mix, and what you hear auditioning is
  /// arithmetically what lands in the file.
  double _musicGainDb = 0.0;

  /// Repeat the score until the picture ends.
  ///
  /// The one music setting that changes what is heard rather than how loudly.
  /// It still cannot change how LONG anything is: the loop is infinite at the
  /// input and finite at the output trim, so it fills the silence after a
  /// short track instead of adding time to the piece. Which is why it stays
  /// out of ScriptWarmKey along with everything else about music.
  bool _musicLoop = false;

  // --- Export & Path State ---
  int _exportDone = 0;
  int _exportTotal = 0;
  String? _exportStatus;
  ExportCancelToken? _cancelToken;
  late final String _baseDir;

  /// The active session directory. Every asset a template references
  /// (wallpapers, gallery folders, fonts) and every bake output resolves
  /// inside this folder. Templates themselves stay at $_baseDir/templates/
  /// so the same recipe can be pointed at different workspaces to produce
  /// different finished pieces.
  ///
  /// Always valid before the menu paints: initState calls _initWorkspace(),
  /// which loads the persisted path or auto-creates default_workspace/.
  late String _workspace;

  String get _imagesDir => '$_workspace/images';
  String get _fontsDir => '$_workspace/fonts';
  String get _spritesDir => '$_workspace/sprites';
  String get _audioDir => '$_workspace/audio';

  /// Absolute path to the selected bed, or null when none is selected.
  String? get _bedPath =>
      _bedFileName.isEmpty ? null : '$_audioDir/$_bedFileName';

  /// Absolute path to the selected music file, or null when none.
  String? get _musicPath =>
      _musicFileName.isEmpty ? null : '$_audioDir/$_musicFileName';

  /// Bed path only when the probe succeeded, which is what the preview and
  /// the bake actually want.
  String? get _usableBedPath => (_bedInfo?.ok ?? false) ? _bedPath : null;

  /// Music path only when the probe succeeded. Both the preview and the bake
  /// gate on this: handing ffmpeg a file it could not read would fail a whole
  /// render over a score, which is exactly the wrong trade. An unreadable
  /// music file is an amber row, never a failed bake.
  String? get _usableMusicPath =>
      (_musicInfo?.ok ?? false) ? _musicPath : null;

  /// Music length in frames. Reported, never used to decide a duration.
  ///
  /// The ribbon draws a lane with it and the readout prints it. Deliberately
  /// absent from every place [_bedFrames] appears.
  int get _musicFrames {
    final AudioBedInfo? info = _musicInfo;
    if (info == null || !info.ok) return 0;
    return info.framesAt(engineFps);
  }

  /// What the app remembers between launches: the active workspace, the
  /// output sink, and the template plus font last used with each
  /// workspace. Lives in the portable app folder beside the executable,
  /// so it cannot be lost by launching from a different directory.
  ///
  /// This replaces two single-line dotfiles, and it fixes them as much as
  /// it consolidates them: they were written relative to a base directory
  /// resolved by walking up from the CURRENT WORKING DIRECTORY, which is
  /// not a property of the install. See session_store.dart.
  late final SessionStore _session;

  /// Per-workspace settings, sitting inside the workspace so they travel
  /// with the assets they describe. Currently just the bed; JSON because
  /// this will grow and a one-line text file will not.
  ///
  /// Distinct from [_session] on purpose. This one belongs to the
  /// workspace and moves with it when the folder is copied to another
  /// machine; the session belongs to this install and does not.
  String get _workspaceConfigPath => '$_workspace/workspace.json';

  final Map<String, Map<String, dynamic>> _resolutions = {
    "1080p": {"w": 1920.0, "h": 1080.0, "scale": 1.0},
    "4K": {"w": 3840.0, "h": 2160.0, "scale": 2.0},
  };

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    windowManager.setPreventClose(true);

    _baseDir = resolvePortableBaseDir();

    // Trace to a file so tracing survives a release build. See diag.dart:
    // reading these under `flutter run` means wading through debug-only
    // assertions that release has always tolerated.
    diagLogPath = '$_baseDir/r3nder_trace.log';

    // Session before workspace: _initWorkspace reads the remembered path
    // out of it, and _scanTemplates / _scanAndLoadFonts read the template
    // and font remembered for whichever workspace that turns out to be.
    _session = SessionStore(baseDir: _baseDir, onError: _logError);
    _session.load();

    _scene = SceneEngine();
    _projectClock = NativeRealtimeProjectClock(RationalFrameRate(engineFps));
    _ticker = createTicker(_onTick);

    // Workspace next: every path lookup below depends on it.
    _initWorkspace();
    _scanTemplates();
    _scanAndLoadFonts();

    // Audio last: it is the only subsystem the app can run entirely without,
    // so a failure here must never block the menu from painting.
    _loadAudioDeviceState();
    _loadWorkspaceConfig();
    _scanBedFiles();
    _initAudioBackend();
    _reprobeBed();
    _reprobeMusic();

    // Sync the app-level theme to whatever phosphor the template set.
    // Post-frame: the notifier triggers a MaterialApp rebuild, which isn't
    // legal mid-initState.
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncPhosphor());
  }

  // Base directory resolution moved to resolvePortableBaseDir() in
  // session_store.dart. The version that lived here walked up from
  // Directory.current, which meant the app folder was wherever you
  // happened to be standing when you launched: the project root under
  // `flutter run`, and anything at all for a built binary. Session state
  // was written to one resolution and looked for under another, so the
  // workspace appeared never to persist. The executable's own directory
  // does not move.

  // -------------------------------------------------------------------
  // Workspace
  // -------------------------------------------------------------------

  /// Loads the persisted workspace path, or auto-creates default_workspace/
  /// next to the app if none exists (or the persisted one has vanished).
  /// Guarantees _workspace is set to a real, existing directory with all
  /// three subfolders scaffolded before it returns.
  void _initWorkspace() {
    String? loaded;
    final String? remembered = _session.workspace;
    if (remembered != null) {
      bool exists = false;
      try {
        exists = Directory(remembered).existsSync();
      } catch (e) {
        _logError('Failed to stat remembered workspace: $e');
      }
      if (exists) {
        loaded = remembered;
      } else {
        _logError(
            'Persisted workspace missing, will fall back to default: $remembered');
      }
    }

    if (loaded != null) {
      _workspace = loaded;
      _ensureWorkspaceSubdirs();
      return;
    }

    // Auto-create the default. Silent on first launch — this is the
    // expected path, not a fallback.
    _workspace = '$_baseDir/default_workspace';
    try {
      Directory(_workspace).createSync(recursive: true);
    } catch (e) {
      _logError('Failed to create default workspace: $e');
    }
    _ensureWorkspaceSubdirs();
    _persistWorkspace();
  }

  /// Creates images/, fonts/, sprites/, audio/, and output_frames/ inside the
  /// active workspace if they don't exist. Called on init, on workspace
  /// switch, and after creating a new workspace. Safe to call repeatedly.
  void _ensureWorkspaceSubdirs() {
    try {
      Directory(_imagesDir).createSync(recursive: true);
      Directory(_fontsDir).createSync(recursive: true);
      Directory(_spritesDir).createSync(recursive: true);
      Directory(_audioDir).createSync(recursive: true);
      Directory('$_workspace/output_frames').createSync(recursive: true);
    } catch (e) {
      _logError('Failed to scaffold workspace subfolders in $_workspace: $e');
    }
  }

  void _persistWorkspace() {
    _session.workspace = _workspace;
    _session.save();
  }

  /// Records the template now selected as this workspace's template.
  ///
  /// By FILENAME, never by index. The list is rebuilt from disk on every
  /// launch and sorted, so an index saved today addresses a different
  /// file the moment one is added or renamed. A name either resolves or
  /// it does not, and when it does not the fallback is visible.
  void _rememberTemplate() {
    final String name = _activeTemplate;
    _session.setTemplateFor(
        _workspace, name == kNoTemplates ? null : name);
    _session.save();
  }

  /// Records the font family now selected as this workspace's font.
  /// Fonts live inside the workspace, so the pairing is the only scope
  /// the selection is meaningful at.
  void _rememberFont() {
    _session.setFontFor(_workspace, _activeFont);
    _session.save();
  }

  /// Sets [path] as the active workspace, re-scaffolds its subfolders,
  /// persists the choice, rescans fonts (workspace-scoped), and rescans
  /// assets — the same script resolves completely differently against a
  /// different workspace.
  void _activateWorkspace(String path) {
    // Kill anything auditioning against the outgoing workspace before the
    // paths under it stop meaning anything.
    _bedPlayer?.stop();

    setState(() {
      _workspace = path;
      // The bed is a workspace ingredient, so the outgoing selection is
      // meaningless here. _loadWorkspaceConfig below replaces it with
      // whatever this workspace declares.
      _bedFileName = "";
      _bedInfo = null;
      _musicFileName = "";
      _musicInfo = null;
      _musicLoop = false;
    });
    _ensureWorkspaceSubdirs();
    _persistWorkspace();

    // The decoded asset cache is keyed by absolute path, so a different
    // workspace simply misses rather than collides. Clearing is about
    // memory, not correctness: the outgoing workspace's library is not
    // coming back and there is no reason to hold it.
    SceneEngine.clearAssetCache();

    // Template and font are remembered per workspace, so switching is not
    // just a path change: it restores the pairing this workspace was last
    // worked on with. Both fall back to the first entry when the
    // remembered one is gone, which is what the old unconditional
    // _idxFont = 0 did for every switch.
    _scanTemplates();
    _scanAndLoadFonts(); // async; has its own setState guarded by mounted
    _rescanAssets();
    _loadWorkspaceConfig();
    _scanBedFiles();
    _reprobeBed();
    _reprobeMusic();
    // Different workspace, different assets, different timing.
    _scheduleWarm();
  }

  // -------------------------------------------------------------------
  // Audio bed
  //
  // Everything here is authoring-side. The bed never enters the render
  // path: the engines receive exactly one integer (the bed's length in
  // frames) so the end hold can stretch under a trailing line, and the
  // exporter receives a file path it hands to ffmpeg as a second input.
  // -------------------------------------------------------------------

  /// Probes for paplay/aplay and enumerates sinks. A machine with neither
  /// is a legitimate configuration (a render box with no sound card), so
  /// this failing quietly disables the transport rather than erroring.
  Future<void> _initAudioBackend() async {
    final AudioBedPlayer? player = await createAudioBedPlayer();
    if (player == null) {
      _logError('No audio playback backend found (paplay/aplay). '
          'Bed preview disabled; export is unaffected.');
      return;
    }
    final List<PlaybackDevice> devices = await player.listDevices();
    if (!mounted) {
      player.dispose();
      return;
    }
    setState(() {
      _bedPlayer = player;
      _bedDevices = devices;
      // A sink stored on another machine will not be here. Fall back rather
      // than silently playing into a device that does not exist.
      _bedDeviceId = resolveDevice(devices, _bedDeviceId).id;
    });
  }

  /// Re-enumerates sinks. Bound to the refresh control, because plugging in
  /// an interface after launch is the common case.
  Future<void> _refreshAudioDevices() async {
    final AudioBedPlayer? player = _bedPlayer;
    if (player == null) return;
    final List<PlaybackDevice> devices = await player.listDevices();
    if (!mounted) return;
    setState(() {
      _bedDevices = devices;
      _bedDeviceId = resolveDevice(devices, _bedDeviceId).id;
    });
  }

  PlaybackDevice get _activeDevice =>
      resolveDevice(_bedDevices, _bedDeviceId);

  void _loadAudioDeviceState() {
    final String? id = _session.audioDeviceId;
    if (id != null && id.isNotEmpty) _bedDeviceId = id;
  }

  void _persistAudioDevice() {
    _session.audioDeviceId = _bedDeviceId;
    _session.save();
  }

  /// Reads workspace.json. Absent or malformed is not an error: an old
  /// workspace predating this feature simply has no bed.
  ///
  /// The two tracks are two sibling keys rather than one list of tracks.
  /// That shape is what lets a build predating the music bed read this file,
  /// find the `audioBed` it knows, ignore the `musicBed` it does not, and
  /// preserve it on write (see [_saveWorkspaceConfig]). A restructure into
  /// `tracks: [...]` would have been tidier and would have silently dropped
  /// the voice bed on any older build that opened the workspace.
  void _loadWorkspaceConfig() {
    try {
      final f = File(_workspaceConfigPath);
      if (!f.existsSync()) return;
      final dynamic raw = jsonDecode(f.readAsStringSync());
      if (raw is! Map) return;

      final dynamic bed = raw['audioBed'];
      if (bed is Map) {
        final String file = (bed['file'] as String?) ?? '';
        final double gain = (bed['gainDb'] as num?)?.toDouble() ?? 0.0;
        _bedFileName = file;
        _bedGainDb = gain.clamp(-40.0, 12.0);
      }

      // Read independently of the bed. A workspace can legitimately carry a
      // score and no voiceover, and an early return on a missing audioBed
      // would have made that combination unloadable.
      final dynamic music = raw['musicBed'];
      if (music is Map) {
        final String file = (music['file'] as String?) ?? '';
        final double gain = (music['gainDb'] as num?)?.toDouble() ?? 0.0;
        _musicFileName = file;
        _musicGainDb = gain.clamp(-40.0, 12.0);
        // Absent means off, so a workspace written before looping existed
        // reads with the behavior it was authored against.
        _musicLoop = (music['loop'] as bool?) ?? false;
      }
    } catch (e) {
      _logError('Failed to read ${_workspaceConfigPath.split('/').last}: $e');
    }
  }

  /// Writes workspace.json, preserving any keys this build does not know
  /// about so a newer version's settings survive a round trip through an
  /// older one.
  void _saveWorkspaceConfig() {
    try {
      Map<String, dynamic> root = <String, dynamic>{};
      final f = File(_workspaceConfigPath);
      if (f.existsSync()) {
        final dynamic raw = jsonDecode(f.readAsStringSync());
        if (raw is Map) root = Map<String, dynamic>.from(raw);
      }
      root['audioBed'] = <String, dynamic>{
        'file': _bedFileName,
        'gainDb': _bedGainDb,
      };
      root['musicBed'] = <String, dynamic>{
        'file': _musicFileName,
        'gainDb': _musicGainDb,
        'loop': _musicLoop,
      };
      f.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(root));
    } catch (e) {
      _logError('Failed to write workspace config: $e');
    }
  }

  /// Lists candidate bed files in `<workspace>/audio/`. Extension filtering
  /// is deliberately loose: ffmpeg reads far more than this list, and a file
  /// it cannot open reports as a failed probe rather than being hidden.
  void _scanBedFiles() {
    const Set<String> exts = {
      '.wav', '.flac', '.mp3', '.m4a', '.aac', '.ogg', '.opus', '.aif', '.aiff'
    };
    List<String> found = const [];
    try {
      final dir = Directory(_audioDir);
      if (dir.existsSync()) {
        found = dir
            .listSync()
            .whereType<File>()
            .map((f) => f.path.split(Platform.pathSeparator).last)
            .where((n) => exts.any((e) => n.toLowerCase().endsWith(e)))
            .toList()
          ..sort();
      }
    } catch (e) {
      _logError('Failed to scan audio folder: $e');
    }
    if (mounted) {
      setState(() => _availableBedFiles = found);
    } else {
      _availableBedFiles = found;
    }
  }

  /// Re-probes the selected bed for duration, rate, and channels. Runs on
  /// init, on workspace switch, and on every bed selection change. Cheap:
  /// one ffprobe, no decode.
  Future<void> _reprobeBed() async {
    final String? path = _bedPath;
    if (path == null) {
      if (mounted) setState(() => _bedInfo = null);
      return;
    }
    final AudioBedInfo info = await AudioBedProbe.probe(path);
    if (!mounted) return;
    final int before = _bedFrames;
    setState(() => _bedInfo = info);
    if (!info.ok) _logError('Audio bed unreadable: $path (${info.error})');

    // Bed length is the one audio value that crosses into the engine: it
    // stretches the end hold, so it moves the total frame count. Only
    // rebuild when it actually changed, since this also runs on init and on
    // workspace switch, both of which have already scheduled one.
    if (_bedFrames != before) _scheduleWarm();
  }

  void _selectBed(String fileName) {
    _bedPlayer?.stop();
    setState(() {
      _bedFileName = fileName;
      _bedInfo = null;
    });
    _saveWorkspaceConfig();
    _reprobeBed();
  }

  /// Re-probes the selected music file. Same cost and same shape as
  /// [_reprobeBed], with one deliberate omission.
  ///
  /// IT NEVER CALLS _scheduleWarm, and that absence is the feature. The bed
  /// reprobe does, because a bed's length stretches the end hold and so
  /// moves the total frame count, which is why bed length sits in
  /// ScriptWarmKey. Music is trimmed to picture and cannot move a frame
  /// boundary, so there is nothing to re-simulate: swapping a score or
  /// riding its fader costs no rebuild at all. Adding the call here for
  /// symmetry would throw away that property and quietly make every music
  /// edit as expensive as a script edit.
  Future<void> _reprobeMusic() async {
    final String? path = _musicPath;
    if (path == null) {
      if (mounted) setState(() => _musicInfo = null);
      return;
    }
    final AudioBedInfo info = await AudioBedProbe.probe(path);
    if (!mounted) return;
    setState(() => _musicInfo = info);
    if (!info.ok) _logError('Music bed unreadable: $path (${info.error})');
  }

  void _selectMusic(String fileName) {
    _bedPlayer?.stop();
    setState(() {
      _musicFileName = fileName;
      _musicInfo = null;
    });
    _saveWorkspaceConfig();
    _reprobeMusic();
  }

  /// Bed length in engine frames, zero when no usable bed is attached.
  /// This is the single value that crosses into the engine.
  int get _bedFrames {
    final AudioBedInfo? info = _bedInfo;
    if (info == null || !info.ok) return 0;
    return info.framesAt(engineFps);
  }

  /// Starts both tracks as one pipeline.
  ///
  /// The player's first argument is "the track that is definitely there",
  /// not "the voiceover". A workspace with a score and no narration is an
  /// ordinary configuration, so music takes the primary slot with its own
  /// gain when it is alone, exactly as the exporter derives its input index
  /// rather than hardcoding one.
  ///
  /// Every consumer routes through here so none of them can start one track
  /// and forget the other, and so the balance is assembled in one place.
  Future<void> _playMix(
    AudioBedPlayer player, {
    required String? bed,
    required String? music,
    double startSec = 0.0,
    double? durationSec,
  }) async {
    final String? primary = bed ?? music;
    if (primary == null) return;
    final bool bedIsPrimary = bed != null;
    await player.play(
      primary,
      startSec: startSec,
      gainDb: bedIsPrimary ? _bedGainDb : _musicGainDb,
      device: _activeDevice,
      loop: bedIsPrimary ? false : _musicLoop,
      musicPath: bedIsPrimary ? music : null,
      musicGainDb: _musicGainDb,
      musicLoop: _musicLoop,
      // Phase, not position. A loop scrubbed to frame N is at N modulo the
      // track length, and only the caller knows that length.
      musicSeekSec: _musicLoop
          ? loopedSeek(startSec, _musicInfo?.durationSec ?? 0.0)
          : null,
      durationSec: durationSec,
    );
  }

  /// Auditions the mix from the menu so a sink and a balance can both be
  /// checked without launching a full preview.
  ///
  /// The whole point of a second track is the relationship between the two,
  /// so this plays them together rather than offering a per-track preview.
  /// Soloing is what the gain sliders do at -40.
  ///
  /// Deliberately keyed on the raw paths rather than the probed ones: this
  /// is reachable the instant a file is picked, and a probe that has not
  /// come back yet should not read as a dead button. An absent file is a
  /// no-op inside the player.
  Future<void> _auditionBed() async {
    final AudioBedPlayer? player = _bedPlayer;
    if (player == null) return;
    if (_bedPath == null && _musicPath == null) return;

    if (player.isPlaying) {
      await player.stop();
      if (mounted) setState(() {});
      return;
    }
    try {
      await _playMix(player, bed: _bedPath, music: _musicPath);
    } catch (e) {
      _snack('Playback failed: $e', Colors.red);
      _logError('Bed audition failed: $e');
    }
    if (mounted) setState(() {});
  }

  /// Debounces workspace.json writes while either gain slider is being
  /// dragged. R3Slider fires continuously on drag, and writing JSON per
  /// pixel would hammer the disk for no benefit.
  ///
  /// One debounce serves both faders. They write the same file and restart
  /// the same pipeline, and two timers racing to respawn one audition is
  /// precisely the interleaving this design exists to avoid.
  void _scheduleGainSave() {
    _bedGainSaveTimer?.cancel();
    _bedGainSaveTimer = Timer(const Duration(milliseconds: 400), () {
      _saveWorkspaceConfig();
      // Gain is applied by ffmpeg at spawn time, so a change mid-audition is
      // inaudible until the pipeline restarts. Restart explicitly rather
      // than round-tripping _auditionBed's toggle, which would be two racing
      // async calls sharing one generation counter.
      final AudioBedPlayer? player = _bedPlayer;
      if (player != null && player.isPlaying) {
        unawaited(_playMix(player, bed: _bedPath, music: _musicPath)
            .catchError((e) => _logError('Gain restart failed: $e')));
      }
    });
  }

  Future<void> _playTestTone() async {
    final AudioBedPlayer? player = _bedPlayer;
    if (player == null) return;
    try {
      await player.testTone(device: _activeDevice);
    } catch (e) {
      _snack('No output on ${_activeDevice.description}', Colors.red);
      _logError('Test tone failed: $e');
    }
  }

  Future<void> _showCreateWorkspaceDialog() async {
    final parentCtrl = TextEditingController(text: _baseDir);
    final nameCtrl = TextEditingController();

    try {
      final bool? proceed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text("CREATE WORKSPACE", style: _t.value.copyWith(letterSpacing: 2)),
          content: SizedBox(
            width: 500,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "Creates a new folder to hold this project's images/, "
                  "fonts/, sprites/, and bake output. Templates stay at the app's "
                  "templates/ folder.",
                  style: _t.fine,
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: parentCtrl,
                  style: _t.value,
                  decoration: const InputDecoration(
                    labelText: "Parent folder",
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: nameCtrl,
                  autofocus: true,
                  style: _t.value,
                  decoration: const InputDecoration(
                    labelText: "Workspace name",
                    hintText: "my_project",
                    isDense: true,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            R3Button("Cancel", theme: _t, compact: true,
                onPressed: () => Navigator.of(ctx).pop(false)),
            R3Button("Create", theme: _t, compact: true,
                kind: R3ButtonKind.primary,
                onPressed: () => Navigator.of(ctx).pop(true)),
          ],
        ),
      );

      if (proceed != true) return;

      final parent = parentCtrl.text.trim();
      final name = nameCtrl.text.trim();

      if (name.isEmpty || name.contains('/') || name.contains('\\')) {
        _snack('Workspace name cannot be empty or contain path separators', Colors.red);
        return;
      }
      if (parent.isEmpty || !Directory(parent).existsSync()) {
        _snack('Parent folder does not exist: $parent', Colors.red);
        return;
      }
      final target = '$parent/$name';
      if (Directory(target).existsSync()) {
        _snack('Already exists: $target', Colors.red);
        return;
      }

      try {
        Directory(target).createSync(recursive: true);
      } catch (e) {
        _snack('Failed to create workspace: $e', Colors.red);
        return;
      }

      _activateWorkspace(target);
      _snack('Workspace created: $target', Colors.green.shade700);
    } finally {
      parentCtrl.dispose();
      nameCtrl.dispose();
    }
  }

  Future<void> _showOpenWorkspaceDialog() async {
    final pathCtrl = TextEditingController(text: _workspace);

    try {
      final bool? proceed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text("OPEN WORKSPACE", style: _t.value.copyWith(letterSpacing: 2)),
          content: SizedBox(
            width: 500,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "Absolute path to an existing workspace folder. Any "
                  "missing images/, fonts/, sprites/, or output_frames/ subfolders "
                  "will be created inside it.",
                  style: _t.fine,
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: pathCtrl,
                  autofocus: true,
                  style: _t.value,
                  decoration: const InputDecoration(
                    labelText: "Workspace path",
                    isDense: true,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            R3Button("Cancel", theme: _t, compact: true,
                onPressed: () => Navigator.of(ctx).pop(false)),
            R3Button("Open", theme: _t, compact: true,
                kind: R3ButtonKind.primary,
                onPressed: () => Navigator.of(ctx).pop(true)),
          ],
        ),
      );

      if (proceed != true) return;

      final path = pathCtrl.text.trim();
      if (path.isEmpty || !Directory(path).existsSync()) {
        _snack('Not a directory: $path', Colors.red);
        return;
      }

      _activateWorkspace(path);
      _snack('Workspace opened: $path', Colors.green.shade700);
    } finally {
      pathCtrl.dispose();
    }
  }

  void _snack(String msg, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: color),
    );
  }

  /// Appends error messages to a persistent log file in the project root.
  /// Stays at _baseDir (not per-workspace) because finding it shouldn't
  /// depend on which workspace was open when it wrote.
  void _logError(String message) {
    try {
      final logFile = File('$_baseDir/r3nder_error.log');
      final timestamp = DateTime.now().toIso8601String();
      logFile.writeAsStringSync('[$timestamp] $message\n', mode: FileMode.append);
      debugPrint('Logged Error: $message');
    } catch (e) {
      debugPrint('Failed to write to log: $e');
    }
  }

  @override
  void onWindowClose() async {
    if (_currentState == AppState.baking && _cancelToken != null) {
      _cancelToken!.cancel();
      await Future.delayed(const Duration(milliseconds: 500));
    }
    // Subprocess sinks are not our children's children: if we exit without
    // killing them they keep the pipeline alive and hold the device.
    _bedPlayer?.dispose();
    _scene.disposeImages();
    await windowManager.destroy();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    _warmDebounce?.cancel();
    _warm?.dispose();
    _bedGainSaveTimer?.cancel();
    _bedPlayer?.dispose();
    _ticker.dispose();
    _projectClock.dispose();
    super.dispose();
  }

  // -------------------------------------------------------------------
  // Template & font scanning
  // -------------------------------------------------------------------

  /// Rebuilds the template list and restores the one this workspace was
  /// last worked on with.
  ///
  /// SORTED, which it was not before. Directory.listSync() returns
  /// filesystem order, so "the first template" was not even the same file
  /// between two boots of the same install once you had edited a few.
  /// Nothing could be restored reliably on top of an unstable list, so the
  /// sort is a precondition rather than a nicety.
  void _scanTemplates() {
    // Templates stay at the app root regardless of workspace. They are the
    // recipes; they do not move with the assets.
    final dir = Directory('$_baseDir/templates');
    if (!dir.existsSync()) dir.createSync(recursive: true);

    final List<String> found = dir
        .listSync()
        .whereType<File>()
        .map((f) => f.path.split(Platform.pathSeparator).last)
        .where((name) => name.toLowerCase().endsWith('.txt'))
        .toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

    if (found.isEmpty) {
      _apply(() {
        _availableTemplates = [kNoTemplates];
        _idxTemplate = 0;
      });
      return;
    }

    // Resolve the remembered filename against what is actually on disk.
    // Missing means it was deleted or renamed since last launch, which is
    // a fallback to the first entry, not an error worth interrupting for.
    final String? remembered = _session.templateFor(_workspace);
    final int at = remembered == null ? -1 : found.indexOf(remembered);

    _apply(() {
      _availableTemplates = found;
      _idxTemplate = at >= 0 ? at : 0;
    });

    _loadActiveTemplate();

    // Fell back. Write down what we actually landed on, so the next launch
    // is not still chasing a file that no longer exists.
    if (at < 0) _rememberTemplate();
  }

  /// setState while this State is alive, plain assignment once it is not.
  ///
  /// The font scan is async and can land after the widget is gone, and
  /// the same is true of any scanner that grows an await later. Same
  /// idiom _rescanAssets and _scanBedFiles already use, factored out so
  /// the three cannot drift.
  void _apply(VoidCallback mutate) {
    if (mounted) {
      setState(mutate);
    } else {
      mutate();
    }
  }

  Future<void> _scanAndLoadFonts() async {
    // Fonts come from the active workspace, so each project can ship its
    // own typography.
    final dir = Directory(_fontsDir);
    if (!dir.existsSync()) dir.createSync(recursive: true);

    final fontFiles = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.ttf') || f.path.toLowerCase().endsWith('.otf'))
        .toList();

    List<String> loadedFonts = [];

    for (var file in fontFiles) {
      final fileName = file.path.split(Platform.pathSeparator).last;
      final familyName = fileName.split('.').first; // Strip extension for family name

      final fontLoader = FontLoader(familyName);
      fontLoader.addFont(() async {
        final bytes = await file.readAsBytes();
        return ByteData.view(bytes.buffer);
      }());

      try {
        await fontLoader.load();
        loadedFonts.add(familyName);
      } catch (e) {
        _logError("Failed to load font $fileName: $e");
      }
    }

    if (loadedFonts.isEmpty) {
      loadedFonts.add("monospace");
    } else {
      // Sorted for the same reason templates are: listSync() returns
      // filesystem order, so an unsorted dropdown reshuffles itself for
      // no visible reason after you touch a file in fonts/.
      loadedFonts.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    }

    // Resolve the remembered family against what actually loaded, same
    // rule as templates: by name, falling back to the first entry.
    //
    // This overrides the selection unconditionally rather than only when
    // the index is out of range. Both callers (initState and a workspace
    // switch) are points where the font list is being replaced wholesale,
    // so there is no user choice to preserve, and the family a workspace
    // is remembered with is the one it should come back up in.
    final String? remembered = _session.fontFor(_workspace);
    final int at = remembered == null ? -1 : loadedFonts.indexOf(remembered);

    _apply(() {
      _availableFonts = loadedFonts;
      _idxFont = at >= 0 ? at : 0;
    });

    // THE FONT ARRIVES LATE, AND IT IS IN THE WARM KEY.
    //
    // initState runs _scanTemplates() synchronously, which schedules a
    // warm while _availableFonts is still the initial ["monospace"]. This
    // method is async, so by the time the real family loads the warm has
    // either been built against the wrong font or is about to be. Either
    // way the editor asks for a key this can never match, and the warm
    // silently never lands.
    //
    // Same applies to a workspace switch, which rescans fonts for the
    // incoming workspace.
    _scheduleWarm();
  }

  void _loadActiveTemplate() {
    final selFile = _activeTemplate;
    if (selFile == kNoTemplates) return;

    final file = File('$_baseDir/templates/$selFile');
    if (!file.existsSync()) return;

    final text = file.readAsStringSync();
    _applyTemplateText(text);
  }

  /// Parses [text] and applies its CONFIG / menu / macro state to the UI.
  /// Shared by _loadActiveTemplate (from disk) and the editor's onClose
  /// (from the editor buffer, which may be newer than disk if unsaved).
  /// Also refreshes the asset scan, since the reference set may have changed.
  void _applyTemplateText(String text) {
    final data = ScriptParser.parseTemplateData(text);

    setState(() {
      _docText = text;

      // Apply CONFIG Overrides
      if (data.configs.containsKey("SIZE")) {
        _customFontSize = double.tryParse(data.configs["SIZE"]!) ?? _customFontSize;
      }
      if (data.configs.containsKey("FG")) {
        final parts = data.configs["FG"]!.split(',');
        if (parts.length == 3) {
          _fontColor = Color.fromARGB(255, int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]));
        }
      }
      if (data.configs.containsKey("BG")) {
        final parts = data.configs["BG"]!.split(',');
        if (parts.length == 3) {
          _bgColor = Color.fromARGB(255, int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]));
        }
      }

      // Desktop wallpaper (null = classic fullscreen terminal mode)
      _desktopWallpaper = data.configs["DESKTOP"];

      // Terminal window title bar text (null = default)
      _windowTitle = data.configs["WINTITLE"];

    });

    _rescanAssets();
    // The document moved, so any prepared simulation describes a script
    // that no longer exists. Debounced, because this method also fires the
    // config apply and asset rescan above in the same turn.
    _scheduleWarm();
    // The template's CONFIG:FG may have re-tinted the phosphor.
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncPhosphor());
  }

  /// Re-resolves every asset reference in the loaded doc against the active
  /// workspace. Cheap (regex pass + existsSync calls), so it's fine to run
  /// on every template load and workspace switch.
  void _rescanAssets() {
    if (_docText.isEmpty) {
      setState(() => _assetScan = null);
      return;
    }
    final result = AssetScanner.scan(
      docText: _docText,
      imagesDir: _imagesDir,
      spritesDir: _spritesDir,
    );
    if (mounted) {
      setState(() => _assetScan = result);
    } else {
      _assetScan = result;
    }
  }

  // The MACRO_CFG autosave used to live here, folding the dashboard's
  // Macro Menu Controller state back into the document on preview, bake,
  // asset scan, and editor close. With the controller gone the document is
  // the only writer, so there is nothing to fold and nothing to reconcile,
  // and macro resolution now happens inside compileScript on the way to
  // the engine rather than being cached on this State.


  // -------------------------------------------------------------------
  // Editor warm-up
  // -------------------------------------------------------------------

  /// Throws away any prepared simulation and cancels one in flight.
  ///
  /// Called by everything that could move a frame boundary: a document
  /// change, a workspace switch, a font or resolution change, an asset
  /// import. Over-invalidating is the cheap direction. The key check in
  /// the editor would catch a stale warm anyway, but releasing the asset
  /// library promptly matters more than the odd wasted rebuild.
  void _invalidateWarm() {
    _warmGeneration++;
    _warmDebounce?.cancel();
    _warm?.dispose();
    _warm = null;
  }

  /// Queues a warm build after a quiet period.
  ///
  /// Debounced because the invalidating events arrive in clusters: loading
  /// a template fires a config apply, an asset rescan, and a phosphor sync
  /// in the same turn. Building on each would decode the library three
  /// times to throw two away.
  ///
  /// Deliberately NOT called on entering the editor, only on returning to
  /// the dashboard. Warming while the editor is open would decode a second
  /// asset library alongside the one the editor is already using, to
  /// prepare an open that is not going to happen.
  void _scheduleWarm() {
    _invalidateWarm();

    if (_docText.isEmpty) return;

    // NOT WHILE THE EDITOR IS OPEN. Checked at schedule time as well as at
    // fire time, because leaving the editor calls _applyTemplateText (which
    // schedules) BEFORE flipping the state back to menu, so the fire-time
    // check alone let a timer armed in the editor survive. The trace caught
    // one doing a full 1029ms asset decode alongside the library the editor
    // was already holding, to prepare an open that was not going to happen.
    //
    // Nothing is lost by refusing: returning to the dashboard schedules a
    // warm anyway, through _applyTemplateText on close.
    if (_currentState == AppState.editor) return;
    if (kProfileWarm) {
      diag('warm', 'scheduled (gen $_warmGeneration, state $_currentState)');
    }

    // Long enough to sit past a burst of template-load work, short enough
    // that clicking EDIT after a glance at the menu still finds it ready.
    _warmDebounce = Timer(const Duration(milliseconds: 400), _buildWarm);
  }

  /// Schedules a warm ONLY if none exists.
  ///
  /// For returning to an unchanged dashboard, where _scheduleWarm would be
  /// wrong: it invalidates first, so it would throw away a perfectly good
  /// warm and pay for a full asset decode to rebuild something identical.
  /// This covers the gap where the debounce fired while the user was in
  /// preview or bake, so _buildWarm bailed on the state check and nothing
  /// rescheduled it.
  void _ensureWarm() {
    if (_warm != null || _warmBuilding) return;
    if (_docText.isEmpty) return;
    if (kProfileWarm) diag('warm', 'ensure (none held)');
    _warmDebounce?.cancel();
    _warmDebounce = Timer(const Duration(milliseconds: 400), _buildWarm);
  }

  /// Runs the editor's simulation ahead of time, on the dashboard's idle
  /// time, and holds the result.
  ///
  /// Failure here is not an error condition. A warm is an optimization
  /// with a correct fallback (simulate on open), so anything that goes
  /// wrong just leaves _warm null and costs a cold open.
  Future<void> _buildWarm() async {
    if (_docText.isEmpty) {
      if (kProfileWarm) diag('warm', 'skip: no document');
      return;
    }

    if (_warmBuilding) {
      // A build is already decoding assets. Re-arm rather than dropping
      // this request: an invalidation landing mid-build would otherwise
      // leave no warm at all until some unrelated change happened to
      // schedule another one.
      if (kProfileWarm) diag('warm', 'busy, re-arming');
      _warmDebounce =
          Timer(const Duration(milliseconds: 400), _buildWarm);
      return;
    }

    // Only warm from the dashboard. Building while the editor is open
    // would decode a second asset library beside the one the editor is
    // already using, to prepare an open that is not going to happen.
    //
    // RE-ARMS RATHER THAN GIVING UP. This was the one exit with no
    // recovery, and it is reachable in ordinary use: leaving the editor
    // schedules a warm from _applyTemplateText and only then flips the
    // state back to menu, so a timer landing in that window found the
    // wrong state and abandoned the warm permanently. A dashboard you are
    // just sitting on generates no further events to reschedule it, which
    // is exactly the shape of "worked once, then never again".
    if (_currentState != AppState.menu) {
      if (kProfileWarm) {
        diag('warm', 'not on dashboard ($_currentState), re-arming');
      }
      _warmDebounce =
          Timer(const Duration(milliseconds: 400), _buildWarm);
      return;
    }

    final int gen = _warmGeneration;
    _warmBuilding = true;
    if (kProfileWarm) diag('warm', 'building (gen $gen)...');

    // Its own engine, not the preview scene. _scene belongs to preview and
    // bake, gets re-setup with UNMARKED text on every Preview, and sharing
    // it would put two features in a fight over one object's lifecycle.
    final SceneEngine scene = SceneEngine();

    try {
      final EditorSimRequest req = _editorSimRequest();
      final CompiledScript compiled = req.compile();
      final EditorSimResult result =
          await runEditorSimulation(scene, req, compiled: compiled);

      // Superseded while assets were decoding, or the user moved on. Either
      // way this result describes inputs that no longer apply, so it is
      // released rather than stored: a stale warm is worse than none.
      if (gen != _warmGeneration || !mounted) {
        if (kProfileWarm) {
          diag('warm', 'DISCARDED mid-build (gen $gen -> $_warmGeneration)');
        }
        scene.disposeImages();
        return;
      }

      final ScriptWarmKey key = req.warmKey(compiled);
      if (kProfileWarm) {
        diag('warm', 'BUILT key=${key.value} frames=${result.totalFrames} '
            'font=${req.fontFamily} bed=${req.bedTargetFrames}');
      }
      _warm = EditorWarmup(key: key, result: result, scene: scene);
      // No setState. Nothing on screen reflects this, and rebuilding the
      // dashboard to announce a background optimization would be the one
      // visible cost of a feature whose whole purpose is to be invisible.
    } catch (e) {
      scene.disposeImages();
      _logError('Editor warm-up failed (falling back to cold open): $e');
    } finally {
      _warmBuilding = false;
    }
  }

  /// The exact request the editor will assemble from the props it is
  /// handed. Every field here has a counterpart in _buildEditor below, and
  /// they have to stay in step: a key built from different values than the
  /// editor uses would never match, and the warm would silently never
  /// apply.
  EditorSimRequest _editorSimRequest() {
    final res = _resolutions[_selectedRes]!;
    return EditorSimRequest(
      docText: _docText,
      fontColor: _fontColor,
      bgColor: _bgColor,
      engineWidth: res["w"] as double,
      engineHeight: res["h"] as double,
      engineScale: res["scale"] as double,
      fontFamily: _activeFont,
      fontSize: _customFontSize,
      lineSpacing: _customLineSpacing,
      tracking: _customTracking,
      marginTop: _customMarginTop,
      marginSide: _customMarginSide,
      imagesDir: _imagesDir,
      spritesDir: _spritesDir,
      bedTargetFrames: _bedFrames,
    );
  }

  /// Runs the full pipeline (macros -> scene setup with image preloading).
  /// Shared by preview and bake so the two can never diverge.
  Future<void> _setupScene({bool withPreroll = false}) async {
    // Same compile the editor and the warm use, minus the line markers:
    // preview and bake run the document as written. One implementation of
    // the document-to-engine-text transformation, so the frames you scrub
    // are the frames that export.
    final compiled = compileScript(_docText, lineMarkers: false);
    final finalText = compiled.engineText;

    final res = _resolutions[_selectedRes]!;
    final w = res["w"] as double;
    final h = res["h"] as double;
    final scale = res["scale"] as double;
    final selectedFont = _activeFont;

    await _scene.setup(
      templateText: finalText,
      fontColor: _fontColor,
      bgColor: _bgColor,
      width: w,
      height: h,
      scale: scale,
      fontPath: selectedFont,
      fontSize: _customFontSize,
      lineSpacing: _customLineSpacing,
      tracking: _customTracking,
      marginTop: _customMarginTop,
      marginSide: _customMarginSide,
      imagesDir: _imagesDir,
      spritesDir: _spritesDir,
      desktopWallpaper: _desktopWallpaper,
      windowTitle: _windowTitle,
      paneLifeConfig: compiled.paneLife,
      captionConfig: compiled.caption,
      appSwitchConfig: compiled.appSwitch,
      withPreroll: withPreroll,
      prerollBgColor: _settingPrerollColor,
      // Alpha describes what is NOT terminal. The terminal keeps its own
      // background (above), and the backdrop behind it paints nothing, so
      // the preroll window materializes as a solid object and the
      // transparent region shrinks away as it grows to fill the frame.
      transparentBackdrop: _rendersAlpha,
      // The only thing the engine ever learns about audio: how many frames
      // the bed occupies. When the script exhausts first, the terminal's end
      // hold stretches to cover the remainder so a trailing line plays out
      // over a live blinking cursor instead of a frozen still. A fixed
      // integer known before frame 0, so determinism is untouched: reset()
      // plus N ticks still reproduces any frame.
      bedTargetFrames: _bedFrames,
    );

    if (_scene.warnings.isNotEmpty) {
      for (final warning in _scene.warnings) {
        _logError("Scene warning: $warning");
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Scene warning: ${_scene.warnings.first}'),
          backgroundColor: Colors.orange,
        ));
      }
    }
  }

  void _openEditor() {
    String selFile = _activeTemplate;

    // Automatically create a new file if no templates exist
    if (selFile == kNoTemplates) {
      String newFileName = "untitled.txt";
      int counter = 1;
      File newFile = File('$_baseDir/templates/$newFileName');
      
      while (newFile.existsSync()) {
        newFileName = "untitled_$counter.txt";
        newFile = File('$_baseDir/templates/$newFileName');
        counter++;
      }

      final starterText = "[SPEED:2]SYSTEM INITIALIZED...\n[PAUSE:30]\nREADY.";
      try {
        newFile.writeAsStringSync(starterText);
        setState(() {
          if (_availableTemplates.length == 1 &&
              _availableTemplates[0] == kNoTemplates) {
            _availableTemplates.clear();
          }
          _availableTemplates.add(newFileName);
          // Re-sort rather than append. The list is sorted everywhere else
          // now, and one appended entry would put the dropdown's order out
          // of step with the order the next _scanTemplates rebuilds.
          _availableTemplates
              .sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
          _idxTemplate = _availableTemplates.indexOf(newFileName);
          selFile = newFileName;
        });
        _rememberTemplate();
        _applyTemplateText(starterText);
      } catch (e) {
        _snack('Failed to create new template: $e', Colors.red);
        return;
      }
    }

    // OWNERSHIP TRANSFERS HERE, once, on the way in. _warm is nulled in the
    // same breath so nothing on the dashboard can dispose an engine the
    // editor is now ticking.
    _warmDebounce?.cancel();
    _pendingWarm = _warm;
    _warm = null;
    if (kProfileWarm) {
      diag('warm', 'handing over: '
          '${_pendingWarm == null ? "NOTHING (cold open)" : "key=${_pendingWarm!.key.value}"}');
    }

    setState(() => _currentState = AppState.editor);
  }

  void _openAssetManager() {
    if (_docText.isEmpty) {
      _snack('No template loaded to scan', Colors.orange);
      return;
    }
    // Fold macro state into the doc first, same as the editor, so the scan
    // sees exactly the text the scene would run.
    setState(() => _currentState = AppState.assets);
  }

  Future<void> _startPreview({bool withPreroll = false}) async {
    if (_isLoadingScene) return;

    setState(() => _isLoadingScene = true);
    await _setupScene(withPreroll: withPreroll);
    if (!mounted) return;

    setState(() {
      _isLoadingScene = false;
      _currentState = AppState.preview;
    });
    // Not started here: with preroll on, the bed must wait for the wipe to
    // finish. _onTick starts it on the terminal engine's first tick, which
    // is the same instant in both preroll and classic runs.
    _bedStartedThisRun = false;
    await _bedPlayer?.stop();

    // Reset authoritative project time immediately before polling begins.
    _projectClock.seekMonotonic(ProjectTime.zero());
    _ticker.start();
  }

  /// Ends a preview run: stops the clock, silences the bed, returns to menu.
  /// Every exit path routes through here so none of them can leave a sink
  /// playing into an empty screen.
  void _endPreview() {
    _ticker.stop();
    _bedPlayer?.stop();
    _bedStartedThisRun = false;
    if (mounted) setState(() => _currentState = AppState.menu);
    // Nothing changed, so any existing warm still stands. This only fills
    // the hole where the debounce fired mid-preview and was refused.
    _ensureWarm();
  }

  Future<void> _startBake({bool withPreroll = false}) async {
    if (_isLoadingScene) return;

    setState(() => _isLoadingScene = true);
    await _setupScene(withPreroll: withPreroll);
    if (!mounted) return;

    final res = _resolutions[_selectedRes]!;
    final w = res["w"] as double;
    final h = res["h"] as double;
    final selectedFont = _activeFont;

    final token = ExportCancelToken();
    setState(() {
      _isLoadingScene = false;
      _currentState = AppState.baking;
      _exportDone = 0;
      _exportTotal = 1;
      _exportStatus = 'Initializing...';
      _cancelToken = token;
    });

    final String ext =
        _exportFormat == VideoExportFormat.proresAlpha ? "mov" : "mp4";
    final String prefix = withPreroll ? "preroll_" : "";
    // Bake lands inside the active workspace, next to the assets that
    // produced it.
    final String outPath = "$_workspace/$_settingFolderName/${prefix}output_$_selectedRes.$ext";

    final result = await SceneExporter.export(
      scene: _scene,
      fontFamily: selectedFont,
      outputPath: outPath,
      format: _exportFormat,
      // The engine simulates at a fixed engineFps; the container framerate
      // must match or playback speed lies. Locked, not user-configurable.
      fps: engineFps,
      width: w.toInt(),
      height: h.toInt(),
      // Export never touches the preview player. ffmpeg takes the original
      // file as a second input and muxes it, so the bake gets full source
      // quality and full channel count regardless of what the preview pipe
      // resampled to. Gain matches the preview because both apply the same
      // ffmpeg volume filter.
      //
      // Only muxed when the probe succeeded: handing ffmpeg a file it could
      // not read would fail the whole bake over a missing voiceover, or over
      // a score, which is worse still.
      audioPath: _usableBedPath,
      audioGainDb: _bedGainDb,
      // The score. Summed with the bed, and trimmed to the picture the
      // engine already decided the length of. See exporter.dart.
      musicPath: _usableMusicPath,
      musicGainDb: _musicGainDb,
      musicLoop: _musicLoop,
      cancelToken: token,
      onProgress: (done, total) {
        if (mounted) setState(() { _exportDone = done; _exportTotal = total; });
      },
      onStatus: (status) {
        if (mounted) setState(() => _exportStatus = status);
      },
    );

    if (!mounted) return;

    setState(() {
      _currentState = AppState.menu;
      _cancelToken = null;
      if (result.success) {
        // A pair writes two files. Naming only one would leave the matte
        // sitting there unmentioned, which is exactly how someone ends up
        // compositing the fill alone and wondering why there is no alpha.
        final String msg = result.mattePath != null
            ? 'Export Complete: ${result.outputPath}'
                '  +  ${result.mattePath!.split('/').last}'
            : 'Export Complete: ${result.outputPath}';
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
      } else if (!result.cancelled) {
        _logError("Export Failed: ${result.error}");
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Export Failed. See r3nder_error.log'), backgroundColor: Colors.red));
      }
    });
  }

  /// Vsync callback for the live preview.
  ///
  /// Flutter decides when we look. Native ProjectClock decides what project
  /// time it is. SceneEngine is still mutable, so explicit-time evaluation is
  /// bounded to one second of scene work per callback. A badly stalled window
  /// therefore catches up in honest chunks: it never blocks on an arbitrary
  /// backlog, and it never pretends skipped mutable state was evaluated.
  void _onTick(Duration _) {
    if (_currentState != AppState.preview) {
      return;
    }

    if (_scene.isFinished) {
      _endPreview();
      return;
    }

    final ProjectTime now = _projectClock.sample();
    final int before = _scene.frameCount;

    _scene.evaluate(now, maxForwardFrames: engineFps);

    if (_scene.frameCount == before) {
      return;
    }

    // Audio remains the existing ffmpeg -> paplay/aplay path for now.
    // AUDIO clock authority comes later when the native sink reports played
    // samples and device latency.
    if (!_bedStartedThisRun &&
        _bedPlayer != null &&
        (_usableBedPath != null || _usableMusicPath != null) &&
        _scene.terminal.frameCount > 0) {
      _bedStartedThisRun = true;
      // Probed paths here, unlike the audition: a preview is a rehearsal for
      // the bake, so it should carry exactly the tracks the bake would and
      // nothing ffmpeg would have refused.
      unawaited(_playMix(_bedPlayer!,
              bed: _usableBedPath, music: _usableMusicPath)
          .catchError((e) => _logError('Bed playback failed: $e')));
    }

    // The preview subtree listens to ProjectClock directly. No whole-home
    // setState is needed just to paint the next evaluated scene frame.
    _projectClock.signalRepaint();
  }

  // --- WIDGET BUILDERS ---

  Widget _buildMenu() {
    final t = _t;

    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 1000),
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // --- Header: title + workspace actions ---
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Text(kAppName.toUpperCase(), style: t.header),
                const SizedBox(width: 12),
                Container(width: 1, height: 20, color: R3Theme.hairline),
                const SizedBox(width: 12),
                R3MicroLabel(kAppTagline, theme: t, accent: true),
                const SizedBox(width: 10),
                // Version doubles as the About affordance. A dedicated
                // ABOUT button would cost a slot in a header that is
                // already the busiest row in the app, and the version is
                // the thing someone is looking for when they go looking
                // for an about box anyway.
                Tooltip(
                  message: 'About $kAppName',
                  child: InkWell(
                    onTap: () => showAboutR3nder(context, t),
                    borderRadius: BorderRadius.circular(3),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      child: Text(kVersionLabel, style: t.fine),
                    ),
                  ),
                ),
                const Spacer(),
                R3Button("Create WS", theme: t, compact: true,
                    onPressed: _showCreateWorkspaceDialog),
                const SizedBox(width: 8),
                R3Button("Open WS", theme: t, compact: true,
                    onPressed: _showOpenWorkspaceDialog),
              ],
            ),
            const SizedBox(height: 16),

            // --- Status strip: what am I working on ---
            R3Panel(
              theme: t,
              accentBorder: true,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                children: [
                  R3MicroLabel("WS", theme: t),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 3,
                    child: Tooltip(
                      message: _workspace,
                      child: Text(
                        _workspace,
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                        style: t.valueDim.copyWith(fontSize: 12),
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Container(width: 1, height: 22, color: R3Theme.hairline),
                  const SizedBox(width: 14),
                  Expanded(
                    flex: 3,
                    child: R3Dropdown<int>(
                      theme: t,
                      label: "Doc",
                      // Failsafe in case the list is empty/reloading
                      value: _idxTemplate < _availableTemplates.length ? _idxTemplate : 0,
                      items: List.generate(_availableTemplates.length, (index) => index),
                      itemLabel: (index) => _availableTemplates[index],
                      onChanged: (newIdx) {
                        if (newIdx != null && newIdx != _idxTemplate) {
                          setState(() { _idxTemplate = newIdx; });
                          _rememberTemplate();
                          _loadActiveTemplate();
                        }
                      },
                    ),
                  ),
                  const SizedBox(width: 14),
                  Container(width: 1, height: 22, color: R3Theme.hairline),
                  const SizedBox(width: 14),
                  _buildAssetsStatus(t),
                ],
              ),
            ),
            const SizedBox(height: 14),

            // --- TYPE and FRAME panels side by side ---
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // TYPE: everything about the glyphs.
                        Expanded(
                          child: R3Panel(
                            theme: t,
                            label: "Type",
                            child: Column(
                              children: [
                                R3Dropdown<int>(
                                  theme: t,
                                  label: "Font",
                                  value: _idxFont < _availableFonts.length ? _idxFont : 0,
                                  items: List.generate(_availableFonts.length, (index) => index),
                                  itemLabel: (index) => _availableFonts[index],
                                  onChanged: (newIdx) {
                                    if (newIdx != null && newIdx != _idxFont) {
                                      setState(() { _idxFont = newIdx; });
                                      _rememberFont();
                                      // Font metrics decide where lines
                                      // wrap, wrapping decides line count,
                                      // line count moves frame boundaries.
                                      _scheduleWarm();
                                    }
                                  },
                                ),
                                const SizedBox(height: 6),
                                R3Slider(theme: t, label: "Size", value: _customFontSize, min: 10, max: 200,
                                    onChanged: (v) => setState(() => _customFontSize = v)),
                                R3Slider(theme: t, label: "Leading", value: _customLineSpacing, min: 10, max: 300,
                                    onChanged: (v) => setState(() => _customLineSpacing = v)),
                                R3Slider(theme: t, label: "Tracking", value: _customTracking, min: -20, max: 100,
                                    onChanged: (v) => setState(() => _customTracking = v)),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 14),

                        // FRAME: the canvas.
                        Expanded(
                          child: R3Panel(
                            theme: t,
                            label: "Frame",
                            trailing: _buildResToggle(t),
                            child: Column(
                              children: [
                                R3Slider(theme: t, label: "Top Margin", value: _customMarginTop, min: 0, max: 1000,
                                    onChanged: (v) => setState(() => _customMarginTop = v)),
                                R3Slider(theme: t, label: "Side Margin", value: _customMarginSide, min: 0, max: 1000,
                                    onChanged: (v) => setState(() => _customMarginSide = v)),
                                const SizedBox(height: 10),
                                // Wrap, not a plain Row. Five swatches plus
                                // the label is close to this panel's width,
                                // and an overflowing Row does not just look
                                // wrong: Flutter paints outside the parent
                                // but hit-tests against its bounds, so the
                                // last swatch would render normally and
                                // silently refuse clicks.
                                Row(
                                  children: [
                                    R3MicroLabel("Phosphor", theme: t),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Wrap(
                                        alignment: WrapAlignment.end,
                                        spacing: 8,
                                        runSpacing: 6,
                                        children: [
                                          _phosphorSwatch("GRN", const Color(0xFF00FF00), const Color(0xFF0A0F0A)),
                                          _phosphorSwatch("AMB", const Color(0xFFFFB000), const Color(0xFF140A00)),
                                          _phosphorSwatch("CYN", const Color(0xFF00FFFF), const Color(0xFF000A14)),
                                          _phosphorSwatch("WHT", const Color(0xFFFFFFFF), const Color(0xFF000000)),
                                          // Ubuntu / GNOME Terminal defaults:
                                          // aubergine background with Tango
                                          // Aluminium 1 text. The background
                                          // is the same value as
                                          // _kTerminalBody in scene_painter,
                                          // so the preroll window body and
                                          // the terminal interior match and
                                          // the reveal reads as a real
                                          // Ubuntu terminal.
                                          //
                                          // Foreground is deliberately not
                                          // pure white: _phosphorSwatch marks
                                          // itself active by comparing
                                          // _fontColor to fg, so sharing
                                          // 0xFFFFFFFF with WHT would light
                                          // both swatches at once.
                                          _phosphorSwatch("UBU", const Color(0xFFEEEEEC), const Color(0xFF300A24)),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),

                    // The Macro Menu Controller used to live here. It was
                    // built before the script editor had a live preview, back
                    // when menus were authored in an external text editor and
                    // the dashboard was the only place to set a highlight
                    // color. The node editor now owns that job: DEF_MENU,
                    // CALL, MENU_STATE, and MACRO_CFG are typed nodes with
                    // cross-referenced pickers, and the document is the single
                    // source of truth. Two writers for one block of markup was
                    // the actual problem, not the UI.

                    const SizedBox(height: 14),
                    _buildAudioPanel(t),

                  ],
                ),
              ),
            ),

            const SizedBox(height: 14),

            // --- Transport row ---
            //
            // The left group is Expanded and clipped rather than sized by its
            // content, with no Spacer. A plain Row here overflowed the menu's
            // 1000px max width, and Flutter paints overflow but does not
            // hit-test it: every ancestor's hitTest begins with a
            // size.contains(position) check, so BAKE rendered perfectly,
            // styled as enabled, actually was enabled, and silently could not
            // be clicked. Buttons now always get their natural width first
            // and the preroll controls absorb whatever is left.
            Row(
              children: [
                Expanded(
                  child: ClipRect(
                    child: Row(
                      children: [
                      // Preroll toggle, restyled as a quiet inline control.
                      InkWell(
                        onTap: () => setState(
                            () => _settingIncludePreroll = !_settingIncludePreroll),
                        borderRadius: BorderRadius.circular(4),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                          child: Row(
                            children: [
                              Icon(
                                _settingIncludePreroll
                                    ? Icons.check_box_outlined
                                    : Icons.check_box_outline_blank,
                                size: 16,
                                color: _settingIncludePreroll ? t.accent : R3Theme.textDim,
                              ),
                              const SizedBox(width: 6),
                              R3MicroLabel("Preroll Wipe",
                                  theme: t, accent: _settingIncludePreroll),
                            ],
                          ),
                        ),
                      ),
                      if (_settingIncludePreroll) ...[
                        const SizedBox(width: 10),
                        // Under an alpha format there is no plate to key: the
                        // backdrop is simply transparent and the terminal
                        // materializes as a solid object over whatever it is
                        // composited onto. Nothing to pick a color for.
                        if (_rendersAlpha)
                          R3MicroLabel("materializes over alpha", theme: t)
                        else ...[
                          _keyColorSwatch("GRN KEY", const Color(0xFF00FF00)),
                          const SizedBox(width: 6),
                          _keyColorSwatch("MAG KEY", const Color(0xFFFF00FF)),
                        ],
                      ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                R3Button("Settings", theme: t,
                    onPressed: () => setState(() => _currentState = AppState.settings)),
                const SizedBox(width: 10),
                R3Button("Assets", theme: t,
                    onPressed: _openAssetManager,
                    badge: _assetsBadge()),
                const SizedBox(width: 10),
                R3Button("Edit", theme: t, onPressed: _openEditor),
                const SizedBox(width: 10),
                R3Button(_isLoadingScene ? "Loading..." : "Preview", theme: t,
                    kind: R3ButtonKind.primary,
                    onPressed: _isLoadingScene ? null : () => _startPreview(withPreroll: _settingIncludePreroll)),
                const SizedBox(width: 10),
                R3Button("Bake", theme: t,
                    kind: R3ButtonKind.hot,
                    onPressed: _isLoadingScene ? null : () => _startBake(withPreroll: _settingIncludePreroll)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// AUDIO panel: bed selection, gain, output sink, and audition.
  ///
  /// The bed lives here rather than in Settings because it is workspace
  /// state you change while authoring, not an export preference you set
  /// once. The sink dropdown sits alongside it despite being machine-scoped
  /// because this is where you look when nothing is coming out.
  Widget _buildAudioPanel(R3Theme t) {
    final bool hasBackend = _bedPlayer != null;
    final bool hasBed = _bedFileName.isNotEmpty;
    final bool hasMusic = _musicFileName.isNotEmpty;
    final bool playing = _bedPlayer?.isPlaying ?? false;

    // "None" is index -1 so the picker has a way to detach a bed without a
    // separate clear button.
    final List<int> bedItems = <int>[
      -1,
      ...List.generate(_availableBedFiles.length, (i) => i),
    ];
    final int bedIdx = _availableBedFiles.indexOf(_bedFileName);
    final int musicIdx = _availableBedFiles.indexOf(_musicFileName);

    return R3Panel(
      theme: t,
      label: "Audio",
      trailing: _buildBedStatus(t),
      child: Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                flex: 3,
                child: R3Dropdown<int>(
                  theme: t,
                  label: "Bed",
                  value: bedIdx >= 0 ? bedIdx : -1,
                  items: bedItems,
                  itemLabel: (i) =>
                      i < 0 ? "None" : _availableBedFiles[i],
                  onChanged: (i) {
                    if (i == null) return;
                    _selectBed(i < 0 ? "" : _availableBedFiles[i]);
                  },
                ),
              ),
              const SizedBox(width: 8),
              R3Button("Rescan", theme: t, compact: true,
                  onPressed: _scanBedFiles),
              const SizedBox(width: 8),
              R3Button(playing ? "Stop" : "Audition",
                  theme: t,
                  compact: true,
                  kind: playing ? R3ButtonKind.hot : R3ButtonKind.normal,
                  onPressed:
                      (hasBackend && (hasBed || hasMusic)) ? _auditionBed : null),
            ],
          ),
          const SizedBox(height: 6),
          R3Slider(
            theme: t,
            label: "Gain dB",
            value: _bedGainDb,
            min: -40,
            max: 12,
            format: (v) => v >= 0
                ? "+${v.toStringAsFixed(1)}"
                : v.toStringAsFixed(1),
            onChanged: (v) {
              setState(() => _bedGainDb = v);
              _scheduleGainSave();
            },
          ),
          const SizedBox(height: 8),

          // Music: the same folder, the same list, a different role. Placed
          // under the bed rather than beside it so the two faders stack, and
          // the balance reads as a balance instead of as two settings.
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                flex: 3,
                child: R3Dropdown<int>(
                  theme: t,
                  label: "Music",
                  value: musicIdx >= 0 ? musicIdx : -1,
                  items: bedItems,
                  itemLabel: (i) => i < 0 ? "None" : _availableBedFiles[i],
                  onChanged: (i) {
                    if (i == null) return;
                    _selectMusic(i < 0 ? "" : _availableBedFiles[i]);
                  },
                ),
              ),
              const SizedBox(width: 8),
              // Loop toggle, styled as the quiet inline checkbox the preroll
              // control already uses. It sits on the music row rather than
              // near the transport because it is a property of this track,
              // not of this render.
              InkWell(
                onTap: () {
                  setState(() => _musicLoop = !_musicLoop);
                  _saveWorkspaceConfig();
                  // Restart an audition in flight: the loop is decided when
                  // ffmpeg spawns, so a toggle mid-play is otherwise inaudible
                  // until the next start.
                  final AudioBedPlayer? player = _bedPlayer;
                  if (player != null && player.isPlaying) {
                    unawaited(_playMix(player, bed: _bedPath, music: _musicPath)
                        .catchError((e) => _logError('Loop restart failed: $e')));
                  }
                },
                borderRadius: BorderRadius.circular(4),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _musicLoop
                            ? Icons.check_box_outlined
                            : Icons.check_box_outline_blank,
                        size: 16,
                        color: _musicLoop ? t.accent : R3Theme.textDim,
                      ),
                      const SizedBox(width: 6),
                      R3MicroLabel("Loop", theme: t, accent: _musicLoop),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // No second Rescan and no second Audition on purpose. The
              // folder is one folder, and the audition is one mix: soloing a
              // track is what pulling the other fader to -40 does.
              Expanded(flex: 2, child: _buildMusicStatus(t)),
            ],
          ),
          const SizedBox(height: 6),
          R3Slider(
            theme: t,
            label: "Music dB",
            value: _musicGainDb,
            min: -40,
            max: 12,
            format: (v) =>
                v >= 0 ? "+${v.toStringAsFixed(1)}" : v.toStringAsFixed(1),
            onChanged: (v) {
              setState(() => _musicGainDb = v);
              // Shares the bed's debounce: one file, one pipeline, one timer.
              _scheduleGainSave();
            },
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                flex: 3,
                child: R3Dropdown<String?>(
                  theme: t,
                  label: hasBackend
                      ? "Output (${_bedPlayer!.backendName})"
                      : "Output",
                  value: _activeDevice.id,
                  items: hasBackend
                      ? _bedDevices.map((d) => d.id).toList()
                      : <String?>[null],
                  itemLabel: (id) => hasBackend
                      ? resolveDevice(_bedDevices, id).description
                      : "No backend",
                  onChanged: (id) {
                    if (!hasBackend) return;
                    setState(() => _bedDeviceId = id);
                    _persistAudioDevice();
                  },
                ),
              ),
              const SizedBox(width: 8),
              R3Button("Refresh", theme: t, compact: true,
                  onPressed: hasBackend ? _refreshAudioDevices : null),
              const SizedBox(width: 8),
              R3Button("Test", theme: t, compact: true,
                  onPressed: hasBackend ? _playTestTone : null),
            ],
          ),
        ],
      ),
    );
  }

  /// Bed readout for the AUDIO panel header. Reports the four states that
  /// actually change what you should do next: no backend, no bed, unreadable
  /// file, and a good bed with its length.
  Widget _buildBedStatus(R3Theme t) {
    R3TallyState state;
    String text;

    if (_bedPlayer == null && _bedFileName.isEmpty) {
      state = R3TallyState.off;
      text = "NO BACKEND";
    } else if (_bedFileName.isEmpty) {
      state = R3TallyState.off;
      text = "NO BED";
    } else if (_bedInfo == null) {
      state = R3TallyState.off;
      text = "PROBING";
    } else if (!_bedInfo!.ok) {
      state = R3TallyState.error;
      text = "UNREADABLE";
    } else {
      state = R3TallyState.ok;
      final int ch = _bedInfo!.channels;
      final String chLabel =
          ch == 1 ? "MONO" : (ch == 2 ? "STEREO" : (ch > 0 ? "${ch}CH" : ""));
      text = "${_bedInfo!.durationLabel}"
          "${chLabel.isEmpty ? "" : "  $chLabel"}"
          "  ${_bedFrames}F";
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        R3Tally(state: state),
        const SizedBox(width: 8),
        Text(text, style: t.micro.copyWith(
          color: state == R3TallyState.error
              ? R3Theme.danger
              : R3Theme.textDim,
        )),
      ],
    );
  }

  /// Music readout for the music row.
  ///
  /// Reports the same states the bed does, and deliberately does NOT report
  /// how much of the score will be trimmed. That figure needs the piece's
  /// total length, which lives in a warm simulation that is nulled the
  /// moment the editor takes ownership of it. A trim number that appeared,
  /// vanished on opening the editor, and came back a second later would be
  /// worse than no number: it would read as the trim itself changing. The
  /// script ribbon knows totalFrames unconditionally, so the overhang is
  /// reported there instead.
  Widget _buildMusicStatus(R3Theme t) {
    R3TallyState state;
    String text;

    if (_musicFileName.isEmpty) {
      state = R3TallyState.off;
      text = "NO MUSIC";
    } else if (_musicInfo == null) {
      state = R3TallyState.off;
      text = "PROBING";
    } else if (!_musicInfo!.ok) {
      state = R3TallyState.error;
      text = "UNREADABLE";
    } else {
      state = R3TallyState.ok;
      final int ch = _musicInfo!.channels;
      final String chLabel =
          ch == 1 ? "MONO" : (ch == 2 ? "STEREO" : (ch > 0 ? "${ch}CH" : ""));
      text = "${_musicInfo!.durationLabel}"
          "${chLabel.isEmpty ? "" : "  $chLabel"}";
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        R3Tally(state: state),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            text,
            overflow: TextOverflow.ellipsis,
            style: t.micro.copyWith(
              color: state == R3TallyState.error
                  ? R3Theme.danger
                  : R3Theme.textDim,
            ),
          ),
        ),
      ],
    );
  }

  /// Asset status readout for the status strip: tally light + short text.
  Widget _buildAssetsStatus(R3Theme t) {
    final int missing = _assetScan?.missingCount ?? 0;
    final int total = _assetScan?.refs.length ?? 0;

    R3TallyState state;
    String text;
    if (total == 0) {
      state = R3TallyState.off;
      text = "NO ASSETS";
    } else if (missing == 0) {
      state = R3TallyState.ok;
      text = "$total OK";
    } else {
      state = R3TallyState.error;
      text = "$missing MISSING";
    }

    return InkWell(
      onTap: _openAssetManager,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            R3Tally(state: state),
            const SizedBox(width: 8),
            Text(text, style: t.micro.copyWith(
              color: state == R3TallyState.error ? R3Theme.danger : R3Theme.textDim,
            )),
          ],
        ),
      ),
    );
  }

  /// Badge for the ASSETS transport button (count only when problems exist).
  Widget? _assetsBadge() {
    final int missing = _assetScan?.missingCount ?? 0;
    if (missing == 0) return null;
    return R3Tally(state: R3TallyState.error, count: '$missing');
  }

  /// 1080p / 4K toggle in the FRAME panel header.
  Widget _buildResToggle(R3Theme t) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: _resolutions.keys.map((k) {
        final bool sel = _selectedRes == k;
        return Padding(
          padding: const EdgeInsets.only(left: 6),
          child: InkWell(
            onTap: () => setState(() => _selectedRes = k),
            borderRadius: BorderRadius.circular(3),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: sel ? t.accentFaint : Colors.transparent,
                borderRadius: BorderRadius.circular(3),
                border: Border.all(color: sel ? t.accentDim : R3Theme.hairline),
              ),
              child: Text(
                k,
                style: t.micro.copyWith(
                  color: sel ? t.accent : R3Theme.textDim,
                  letterSpacing: 1.4,
                ),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  /// Phosphor preset swatch: colored dot + label, accent ring when active.
  Widget _phosphorSwatch(String label, Color fg, Color bg) {
    final bool active = _fontColor == fg;
    return InkWell(
      onTap: () {
        setState(() { _fontColor = fg; _bgColor = bg; });
        _syncPhosphor();
      },
      borderRadius: BorderRadius.circular(3),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: active ? _t.accentFaint : Colors.transparent,
          borderRadius: BorderRadius.circular(3),
          border: Border.all(color: active ? fg.withValues(alpha: 0.7) : R3Theme.hairline),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8, height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: fg,
                boxShadow: active
                    ? [BoxShadow(color: fg.withValues(alpha: 0.6), blurRadius: 5)]
                    : null,
              ),
            ),
            const SizedBox(width: 6),
            Text(label, style: _t.micro.copyWith(
              color: active ? R3Theme.textBright : R3Theme.textDim,
              letterSpacing: 1.4,
            )),
          ],
        ),
      ),
    );
  }

  /// Preroll key color selector (green/magenta chips).
  Widget _keyColorSwatch(String label, Color c) {
    final bool active = _settingPrerollColor == c;
    return InkWell(
      onTap: () => setState(() => _settingPrerollColor = c),
      borderRadius: BorderRadius.circular(3),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(3),
          border: Border.all(color: active ? c.withValues(alpha: 0.8) : R3Theme.hairline),
        ),
        child: Text(label, style: _t.micro.copyWith(
          color: active ? c : R3Theme.textDim,
          letterSpacing: 1.2,
        )),
      ),
    );
  }

  Widget _buildSettings() {
    final t = _t;

    return Center(
      child: SizedBox(
        width: 600,
        child: R3Panel(
          theme: t,
          label: "Export Settings",
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 8),
              TextField(
                style: t.value,
                decoration: const InputDecoration(
                  labelText: "Output Folder (inside workspace)",
                  isDense: true,
                ),
                controller: TextEditingController(text: _settingFolderName)
                  ..selection = TextSelection.collapsed(offset: _settingFolderName.length),
                onChanged: (v) => _settingFolderName = v,
              ),
              const SizedBox(height: 8),
              Text("Bakes to: $_workspace/$_settingFolderName/", style: t.fine),
              const SizedBox(height: 20),

              // The engine simulates at a fixed engineFps; exposing a framerate
              // slider only changed playback speed while claiming otherwise.
              Row(
                children: [
                  const Icon(Icons.lock_outline, size: 15, color: R3Theme.textDim),
                  const SizedBox(width: 8),
                  Text("FRAMERATE: $engineFps FPS (ENGINE-LOCKED)", style: t.micro),
                ],
              ),
              const SizedBox(height: 20),
              Container(height: 1, color: R3Theme.hairline),
              const SizedBox(height: 16),

              R3MicroLabel("Output Format", theme: t, accent: true),
              const SizedBox(height: 10),

              _formatOption(
                t,
                VideoExportFormat.h264Solid,
                "H.264 SOLID (.MP4)",
                "Opaque, one file. Fast and small. No alpha.",
              ),
              const SizedBox(height: 10),
              _formatOption(
                t,
                VideoExportFormat.lumaMatte,
                "FILL + MATTE PAIR (.MP4 x2)",
                "Two H.264 files: color, plus alpha as a luma matte. "
                    "Multiply fill by matte in the comp. Far smaller than "
                    "ProRes on terminal content.",
              ),
              const SizedBox(height: 10),
              _formatOption(
                t,
                VideoExportFormat.proresAlpha,
                "PRORES 4444 (.MOV)",
                "True alpha channel, 12-bit, near-lossless. The mastering "
                    "file. Very large: it barely compresses this content.",
              ),

              // Alpha describes what is NOT terminal, so a fullscreen script
              // with no preroll has nothing transparent to describe and bakes
              // fully opaque. That is correct under this model, but it is not
              // obvious, and finding out by baking a 4K ProRes and opening it
              // in an NLE is an expensive way to learn it.
              if (_rendersAlpha && !_settingIncludePreroll) ...[
                const SizedBox(height: 16),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.info_outline,
                        size: 15, color: R3Theme.textDim),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        "Alpha covers the area outside the terminal. With no "
                        "Preroll Wipe the terminal fills every frame, so this "
                        "bakes fully opaque. Enable Preroll to get the "
                        "materialize-over-footage reveal.",
                        style: t.fine,
                      ),
                    ),
                  ],
                ),
              ],

              const SizedBox(height: 28),
              Center(
                child: R3Button("Back to Menu", theme: t,
                    kind: R3ButtonKind.primary,
                    onPressed: () {
                      setState(() => _currentState = AppState.menu);
                      // Size, leading, tracking, margins, and resolution all
                      // decide where lines wrap and therefore how many
                      // frames the script runs. Scheduling once on the way
                      // out beats firing on every slider pixel.
                      _scheduleWarm();
                    }),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// One row of the export format selector. Radio semantics rather than
  /// checkbox: the three options are mutually exclusive containers, not
  /// independent toggles.
  Widget _formatOption(
    R3Theme t,
    VideoExportFormat fmt,
    String title,
    String blurb,
  ) {
    final bool active = _exportFormat == fmt;
    return InkWell(
      onTap: () => setState(() => _exportFormat = fmt),
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              active ? Icons.radio_button_checked : Icons.radio_button_unchecked,
              size: 16,
              color: active ? t.accent : R3Theme.textDim,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: t.micro.copyWith(
                        color: active ? t.accent : R3Theme.textMid,
                      )),
                  const SizedBox(height: 2),
                  Text(blurb, style: t.fine),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPreview() {
    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape) {
          _endPreview();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Stack(
        children: [
          // The Actual Scene Render (terminal fullscreen, or desktop + windows)
          Positioned.fill(
            child: ProgramPreviewSurface(
              repaint: _projectClock,
              scene: _scene,
              rawDocument: _docText,
              fontFamily: _activeFont,
              theme: _t,
            ),
          ),

          // HUD overlay
          Positioned(
            top: 16, left: 16,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xCC0C0C10),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: R3Theme.hairline),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const R3Tally(state: R3TallyState.error),
                  const SizedBox(width: 8),
                  Text("PREVIEW  $engineFps FPS  —  ESC TO RETURN", style: _t.micro),
                ],
              ),
            ),
          )
        ],
      ),
    );
  }

  Widget _buildEditor() {
    final selFile = _activeTemplate;
    final res = _resolutions[_selectedRes]!;

    return EditorScreen(
      // Rebuild the editor from scratch if the target file changes.
      key: ValueKey(selFile),
      templatePath: '$_baseDir/templates/$selFile',
      initialText: _docText,
      fontFamily: _activeFont,
      // Every family that actually LOADED, not every file in fonts/. A
      // corrupt .ttf sits in the folder and is not registered, and
      // offering it in a picker would produce a caption set in nothing.
      availableFonts: _availableFonts,
      fontColor: _fontColor,
      bgColor: _bgColor,
      engineWidth: res["w"] as double,
      engineHeight: res["h"] as double,
      engineScale: res["scale"] as double,
      fontSize: _customFontSize,
      lineSpacing: _customLineSpacing,
      tracking: _customTracking,
      marginTop: _customMarginTop,
      marginSide: _customMarginSide,
      // Editor previews resolve assets against the active workspace too,
      // so what you see typing matches what the main preview and bake produce.
      imagesDir: _imagesDir,
      spritesDir: _spritesDir,
      // The editor borrows the player rather than making its own: two
      // pipelines would race for the same sink and the sink would interleave
      // them. It stops the bed on close and dispose, never disposes it.
      bedPlayer: _bedPlayer,
      bedPath: _usableBedPath,
      bedGainDb: _bedGainDb,
      bedDevice: _activeDevice,
      bedTargetFrames: _bedFrames,
      // Music reaches the editor for two unrelated reasons: so scrubbing
      // hears the mix rather than the voiceover alone, and so the ribbon can
      // draw a lane for it. Neither is a timing input. bedTargetFrames above
      // is the only audio value that changes how long anything runs, which
      // is why it is the only one in ScriptWarmKey.
      musicPath: _usableMusicPath,
      musicGainDb: _musicGainDb,
      musicFrames: _musicFrames,
      musicLoop: _musicLoop,
      musicDurationSec: _musicInfo?.durationSec ?? 0.0,
      // Prepared while the dashboard was idle, or null for a cold open.
      // The editor adopts it only if its key matches, and disposes it
      // otherwise; either way it owns it from here.
      warmup: _pendingWarm,
      onClose: (latestText) {
        // Adopt the editor buffer (even if unsaved) so the menu's macro
        // controller and CONFIG-derived settings reflect what was written.
        // _applyTemplateText also rescans assets — new tags typed in the
        // editor show up on the menu badge immediately, and it schedules a
        // fresh warm against whatever was just written.
        _pendingWarm = null; // Spent; the editor owns whatever it adopted.
        _applyTemplateText(latestText);
        setState(() => _currentState = AppState.menu);
      },
    );
  }

  Widget _buildAssets() {
    return AssetManagerScreen(
      // Rebuild if the doc or workspace changes underneath it.
      key: ValueKey('$_workspace|$_activeTemplate'),
      docText: _docText,
      imagesDir: _imagesDir,
      spritesDir: _spritesDir,
      onClose: () {
        setState(() => _currentState = AppState.menu);
        // Imports may have fixed things — refresh the menu badge.
        _rescanAssets();
        // A reference that now resolves runs on real asset timing instead
        // of dud timing, so the frame count can have moved.
        _scheduleWarm();
      },
    );
  }

  Widget _buildBaking() {
    final t = _t;
    final double? progress =
        _exportTotal > 0 ? _exportDone / _exportTotal : null;

    return Center(
      child: SizedBox(
        width: 460,
        child: R3Panel(
          theme: t,
          label: "Baking $_selectedRes Video",
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 6),
              // Thin accent progress bar in the mixer style.
              Stack(
                children: [
                  Container(height: 3, color: R3Theme.hairline),
                  FractionallySizedBox(
                    widthFactor: (progress ?? 0).clamp(0.001, 1.0),
                    child: Container(height: 3, color: t.accent),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Text("FRAME $_exportDone / $_exportTotal", style: t.micro),
                  const Spacer(),
                  if (_exportStatus != null)
                    Text(_exportStatus!.toUpperCase(), style: t.microAccent),
                ],
              ),
              const SizedBox(height: 24),
              Center(
                child: R3Button("Cancel", theme: t,
                    onPressed: () => _cancelToken?.cancel()),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    Widget child;
    switch (_currentState) {
      case AppState.menu: child = _buildMenu(); break;
      case AppState.settings: child = _buildSettings(); break;
      case AppState.preview: child = _buildPreview(); break;
      case AppState.baking: child = _buildBaking(); break;
      case AppState.editor: child = _buildEditor(); break;
      case AppState.assets: child = _buildAssets(); break;
    }
    return Scaffold(body: child);
  }
}