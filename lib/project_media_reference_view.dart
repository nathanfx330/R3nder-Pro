// ./lib/project_media_reference_view.dart
//
// Small reference/offline controls shared by the project media browser.
// These widgets are navigation only. They never relink, replace, or rewrite a
// CLIP source.

import 'package:flutter/material.dart';

import 'project_media_references.dart';
import 'ui_theme.dart';

class ProjectMediaOfflineTile extends StatelessWidget {
  final String authoredSource;
  final List<ProjectMediaReference> references;
  final R3Theme theme;
  final ValueChanged<ProjectMediaReference>? onReferencePressed;

  const ProjectMediaOfflineTile({
    super.key,
    required this.authoredSource,
    required this.references,
    required this.theme,
    required this.onReferencePressed,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: sc(160),
      child: Container(
        padding: EdgeInsets.all(sc(7)),
        decoration: BoxDecoration(
          color: R3Theme.bg,
          border: Border.all(color: R3Theme.danger),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(
              Icons.broken_image_outlined,
              size: sc(26),
              color: R3Theme.danger,
            ),
            const Spacer(),
            Text(
              'OFFLINE',
              style: theme.micro.copyWith(
                color: R3Theme.danger,
                fontSize: sc(8),
                letterSpacing: sc(1),
              ),
            ),
            SizedBox(height: sc(2)),
            Text(
              authoredSource,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.fine.copyWith(color: R3Theme.textMid),
            ),
            SizedBox(height: sc(3)),
            Row(
              children: <Widget>[
                Text(
                  '${references.length} ${references.length == 1 ? 'REF' : 'REFS'}',
                  style: theme.micro.copyWith(
                    fontSize: sc(8),
                    letterSpacing: sc(1),
                  ),
                ),
                const Spacer(),
                ProjectMediaReferenceButton(
                  authoredSource: authoredSource,
                  references: references,
                  theme: theme,
                  onPressed: onReferencePressed,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class ProjectMediaReferenceButton extends StatelessWidget {
  final String authoredSource;
  final List<ProjectMediaReference> references;
  final R3Theme theme;
  final ValueChanged<ProjectMediaReference>? onPressed;

  const ProjectMediaReferenceButton({
    super.key,
    required this.authoredSource,
    required this.references,
    required this.theme,
    required this.onPressed,
  });

  String get _referenceSummary => references
      .map(
        (ProjectMediaReference reference) =>
            '${reference.structuralSource} · ${reference.laneId} · ${reference.clipId}',
      )
      .join('\n');

  @override
  Widget build(BuildContext context) {
    if (references.isEmpty) return const SizedBox.shrink();
    if (onPressed == null) {
      return Tooltip(
        message: _referenceSummary,
        child: Text(
          'REF',
          style: theme.micro.copyWith(fontSize: sc(8), letterSpacing: sc(0.8)),
        ),
      );
    }

    if (references.length == 1) {
      final ProjectMediaReference reference = references.single;
      return Tooltip(
        message: _referenceSummary,
        child: InkWell(
          key: ValueKey<String>(
            'project-media-reference-open:$authoredSource:'
            '${reference.structuralSource}:${reference.clipId}',
          ),
          onTap: () => onPressed!(reference),
          child: Text(
            'OPEN',
            style: theme.microAccent.copyWith(
              fontSize: sc(8),
              letterSpacing: sc(0.8),
            ),
          ),
        ),
      );
    }

    return PopupMenuButton<ProjectMediaReference>(
      key: ValueKey<String>('project-media-reference-menu:$authoredSource'),
      tooltip: 'Open media reference',
      color: R3Theme.panelHi,
      padding: EdgeInsets.zero,
      onSelected: onPressed,
      itemBuilder: (BuildContext context) =>
          <PopupMenuEntry<ProjectMediaReference>>[
            for (final ProjectMediaReference reference in references)
              PopupMenuItem<ProjectMediaReference>(
                value: reference,
                child: Text(
                  '${reference.structuralSource} · ${reference.laneId} · ${reference.clipId}',
                  style: theme.fine,
                ),
              ),
          ],
      child: Text(
        'OPEN',
        style: theme.microAccent.copyWith(
          fontSize: sc(8),
          letterSpacing: sc(0.8),
        ),
      ),
    );
  }
}
