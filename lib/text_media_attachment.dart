// ./lib/text_media_attachment.dart
//
// Source-level TEXT -> STRUCT -> EDIT media attachment.
//
// A TEXT attachment does not invent a video cue. It creates one reusable EDIT
// through the shared media-placement primitive, then inserts one ordinary
// STRUCT placement immediately after the selected TEXT node. Existing source
// bytes are never regenerated to accomplish either operation.

import 'edit_media_import.dart';
import 'edit_media_placement.dart';
import 'edit_model.dart';
import 'script_nodes.dart';
import 'structural_chrome.dart';

class TextMediaAttachmentResult {
  final String document;
  final String editId;
  final String clipId;
  final String structuralSource;
  final int structuralStartOffset;

  const TextMediaAttachmentResult({
    required this.document,
    required this.editId,
    required this.clipId,
    required this.structuralSource,
    required this.structuralStartOffset,
  });
}

TextMediaAttachmentResult attachProjectMediaToText({
  required String source,
  required int textStartOffset,
  required int textEndOffset,
  required ImportedEditVideo media,
  String? preferredEditId,
}) {
  if (textStartOffset < 0 ||
      textEndOffset <= textStartOffset ||
      textEndOffset > source.length) {
    throw ArgumentError(
      'TEXT source span [$textStartOffset, $textEndOffset) is invalid.',
    );
  }

  final List<ScriptNode> nodes = parseScriptToNodes(source);
  assignNodeSourceSpans(nodes);
  final List<ScriptNode> matches = nodes
      .where(
        (ScriptNode node) =>
            node.type == 'TEXT' &&
            node.startOffset == textStartOffset &&
            node.endOffset == textEndOffset,
      )
      .toList(growable: false);
  if (matches.length != 1) {
    throw StateError(
      'The requested source span no longer identifies exactly one TEXT node.',
    );
  }

  final EditDocumentModel model = EditDocumentModel.parse(source);
  final String editId = uniqueEditId(
    model,
    preferredEditId ?? media.clipBaseId,
  );
  final MediaPlacementResult placed = placeMediaInEdit(
    source: source,
    media: media,
    editId: editId,
    trackId: 'V1',
    atFrame: 0,
  );

  // placeMediaInEdit appends a missing EDIT at the end of the document, so the
  // selected TEXT node's original end offset is still valid here.
  final int insertionOffset = textEndOffset;
  final String before = placed.document.substring(0, insertionOffset);
  final String after = placed.document.substring(insertionOffset);
  final String newline = source.contains('\r\n') ? '\r\n' : '\n';
  final String structuralSource = 'EDIT.$editId';
  final String tag = formatStructuralChromeTag(
    StructuralChromeSpec(source: structuralSource),
  );

  final bool alreadyAtLineStart =
      before.isEmpty || before.endsWith('\n') || before.endsWith('\r');
  final bool followingStartsNewLine =
      after.startsWith('\n') || after.startsWith('\r');
  final String leading = alreadyAtLineStart ? '' : newline;
  final String trailing = followingStartsNewLine ? '' : newline;
  final String insertion = '$leading$tag$trailing';
  final String document = '$before$insertion$after';
  final int structuralStartOffset = insertionOffset + leading.length;

  // Both parsers are used intentionally. The structural model proves the EDIT
  // still resolves, while the node parser proves the inserted placement is an
  // ordinary STRUCT node rather than literal terminal text.
  final EditDocumentModel reparsed = EditDocumentModel.parse(document);
  reparsed.edit(editId);
  final List<ScriptNode> reparsedNodes = parseScriptToNodes(document);
  assignNodeSourceSpans(reparsedNodes);
  final bool structFound = reparsedNodes.any(
    (ScriptNode node) =>
        node.type == 'STRUCT' &&
        node.startOffset == structuralStartOffset &&
        node.param('source') == structuralSource,
  );
  if (!structFound) {
    throw StateError('Attached STRUCT placement did not round-trip as markup.');
  }

  return TextMediaAttachmentResult(
    document: document,
    editId: editId,
    clipId: placed.clipId,
    structuralSource: structuralSource,
    structuralStartOffset: structuralStartOffset,
  );
}
