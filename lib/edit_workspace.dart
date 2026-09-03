// ./lib/edit_workspace.dart
//
// GUI entry point for source-backed video editing.
//
// EditSurface edits clips that already exist. This wrapper owns the missing
// authoring path: choose a video, import it into the active workspace, and
// serialize a real V1 or V2 CLIP into the same script document. There is no
// timeline database here. The only durable result of an import is new source.

import 'package:flutter/material.dart';

import 'edit_media_import.dart';
import 'edit_model.dart';
import 'edit_surface.dart';
import 'edit_surface_model.dart';
import 'native_file_dialog.dart';
import 'ui_theme.dart';

typedef EditVideoPicker = Future<String?> Function();
typedef EditVideoImporter = ImportedEditVideo Function(String pickedPath);

class EditWorkspace extends StatefulWidget {
  final String source;
  final int currentFrame;
  final int voiceFrames;
  final int musicFrames;
  final bool musicLoops;
  final R3Theme theme;
  final ValueChanged<String> onSourceChanged;
  final ValueChanged<int> onSeek;

  /// Test seams. Production uses the GTK chooser and workspace MLT import.
  final EditVideoPicker? pickVideo;
  final EditVideoImporter? importVideo;

  const EditWorkspace({
    super.key,
    required this.source,
    required this.currentFrame,
    required this.theme,
    required this.onSourceChanged,
    required this.onSeek,
    this.voiceFrames = 0,
    this.musicFrames = 0,
    this.musicLoops = false,
    this.pickVideo,
    this.importVideo,
  });

  @override
  State<EditWorkspace> createState() => _EditWorkspaceState();
}

class _EditWorkspaceState extends State<EditWorkspace> {
  late String _workingSource;
  bool _importing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _workingSource = widget.source;
  }

  @override
  void didUpdateWidget(covariant EditWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.source != oldWidget.source && widget.source != _workingSource) {
      _workingSource = widget.source;
      _error = null;
    }
  }

  Future<void> _addVideo(String trackId) async {
    if (_importing) return;
    setState(() {
      _importing = true;
      _error = null;
    });

    try {
      final String? picked = await (widget.pickVideo ?? pickNativeVideoFile)();
      if (picked == null) return;

      final ImportedEditVideo imported =
          (widget.importVideo ?? importVideoToWorkspace)(picked);
      final EditDocumentModel model = EditDocumentModel.parse(_workingSource);

      late final String next;
      if (model.edits.isEmpty) {
        next = createEditWithClip(
          source: _workingSource,
          editId: 'main',
          trackId: trackId,
          clipId: imported.clipBaseId,
          mediaSource: imported.authoredSource,
          atFrame: widget.currentFrame,
          durationFrames: imported.durationFrames,
        );
      } else {
        final String editId = model.edits.first.id;
        final EditSurfaceDocument document =
            EditSurfaceDocument.parse(_workingSource, editId);
        final String clipId =
            document.nextClipId(trackId, imported.clipBaseId);
        next = document.addClip(
          trackId: trackId,
          clipId: clipId,
          mediaSource: imported.authoredSource,
          atFrame: widget.currentFrame,
          durationFrames: imported.durationFrames,
        );
      }

      if (!mounted) return;
      setState(() {
        _workingSource = next;
        _error = null;
      });
      widget.onSourceChanged(next);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = '$error');
    } finally {
      if (mounted) {
        setState(() => _importing = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final EditDocumentModel? model = _parseModel();
    final EditSequence? edit =
        model == null || model.edits.isEmpty ? null : model.edits.first;

    // EditWorkspace is intentionally safe to mount as a complete workspace,
    // not only underneath EditorScreen. R3Button and EditSurface use InkWell
    // and Slider, both of which require a Material sheet. MaterialApp provides
    // theme/navigation but does not itself promise a Material ancestor around
    // arbitrary home content, so the workspace supplies its own transparent
    // sheet here.
    return Material(
      type: MaterialType.transparency,
      child: Column(
        children: [
          _buildImportBar(edit),
          if (_error != null)
            Container(
              width: double.infinity,
              padding: EdgeInsets.symmetric(
                horizontal: sc(12),
                vertical: sc(6),
              ),
              color: R3Theme.danger.withValues(alpha: 0.12),
              child: Text(
                _error!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: widget.theme.fine.copyWith(color: R3Theme.danger),
              ),
            ),
          Expanded(
            child: model == null
                ? _message('EDIT LANGUAGE ERROR')
                : edit == null
                    ? _message(
                        'NO VIDEO EDIT YET\n\nADD VIDEO creates the first V1 clip.',
                      )
                    : EditSurface(
                        key: ValueKey('edit:${edit.id}'),
                        source: _workingSource,
                        editId: edit.id,
                        currentFrame: widget.currentFrame.clamp(
                          0,
                          edit.projectFrameCount,
                        ),
                        voiceFrames: widget.voiceFrames,
                        musicFrames: widget.musicFrames,
                        musicLoops: widget.musicLoops,
                        theme: widget.theme,
                        onSourceChanged: (String next) {
                          if (_workingSource == next) return;
                          setState(() => _workingSource = next);
                          widget.onSourceChanged(next);
                        },
                        onSeek: widget.onSeek,
                      ),
          ),
        ],
      ),
    );
  }

  EditDocumentModel? _parseModel() {
    try {
      return EditDocumentModel.parse(_workingSource);
    } catch (error) {
      _error ??= '$error';
      return null;
    }
  }

  Widget _buildImportBar(EditSequence? edit) {
    final List<Widget> controls = <Widget>[
      R3MicroLabel('MEDIA', theme: widget.theme, accent: true),
      R3Button(
        'ADD VIDEO',
        theme: widget.theme,
        compact: true,
        kind: R3ButtonKind.primary,
        onPressed: _importing ? null : () => _addVideo('V1'),
      ),
      R3Button(
        'ADD OVERLAY',
        theme: widget.theme,
        compact: true,
        onPressed: _importing ? null : () => _addVideo('V2'),
      ),
      Text(
        'VIDEO = V1   OVERLAY = V2',
        style: widget.theme.micro,
      ),
      if (_importing) ...[
        SizedBox(
          width: sc(13),
          height: sc(13),
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: widget.theme.accentDim,
          ),
        ),
        Text('IMPORTING', style: widget.theme.micro),
      ] else if (edit != null)
        Text(
          'EDIT ${edit.id}   F${widget.currentFrame}',
          style: widget.theme.micro,
        ),
    ];

    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(horizontal: sc(10), vertical: sc(7)),
      decoration: const BoxDecoration(
        color: R3Theme.panel,
        border: Border(bottom: BorderSide(color: R3Theme.hairline)),
      ),
      child: Wrap(
        spacing: sc(8),
        runSpacing: sc(6),
        crossAxisAlignment: WrapCrossAlignment.center,
        children: controls,
      ),
    );
  }

  Widget _message(String text) {
    return Container(
      color: R3Theme.bg,
      alignment: Alignment.center,
      padding: EdgeInsets.all(sc(30)),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: widget.theme.value.copyWith(color: R3Theme.textMid),
      ),
    );
  }
}
