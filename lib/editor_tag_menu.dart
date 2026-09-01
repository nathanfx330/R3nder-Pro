// ./lib/editor_tag_menu.dart

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'script_lint.dart';
import 'config_keys.dart';
import 'ui_theme.dart';

/// Palette entries that cannot be a fixed string.
///
/// Everything else here is literal text with an optional placeholder to
/// select. These two need the playhead and the current simulation, which
/// the menu has no business knowing about, so they carry an action name
/// and the editor intercepts them before the literal insert path.
enum TagAction {
  /// Insert a [PAUSE] at the caret long enough that the content after it
  /// begins exactly at the playhead.
  pauseToPlayhead,

  /// Split the [PAUSE] the playhead sits inside into two pauses summing to
  /// the original, caret between them.
  splitPauseAtPlayhead,
}

class TagSnippet {
  final String label;
  final String description;
  final String insertText;
  final String? placeholder; // Dummy text to automatically highlight upon insertion

  /// Non-null for entries the editor computes rather than inserts. For
  /// those, [insertText] exists only so the palette self-check and the
  /// search box have something real to work with; it never reaches the
  /// document.
  final TagAction? action;

  const TagSnippet(this.label, this.description, this.insertText,
      [this.placeholder, this.action]);
}

// Full dictionary of R3nder Markup tags
// Not const: the CONFIG entries are generated from kConfigKeys rather than
// written out, and a spread of a map() cannot be evaluated at compile time.
// Nothing consumes this in a const context; it is read once to build the
// palette.
final List<TagSnippet> kAllTags = [
  TagSnippet('SPEED', 'Set typing speed (chars per frame)', '[SPEED:5]', '5'),
  TagSnippet('SPEED MAX', 'Instant typing speed', '[SPEED:MAX]'),
  TagSnippet('PAUSE', 'Hold the engine for N frames', '[PAUSE:30]', '30'),
  TagSnippet(
    'PAUSE TO PLAYHEAD',
    'Hold until the scrubber sits, for blocking out',
    '[PAUSE:30]',
    null,
    TagAction.pauseToPlayhead,
  ),
  TagSnippet(
    'SPLIT PAUSE AT PLAYHEAD',
    'Cut the pause under the playhead in two, to type between',
    '[PAUSE:30]',
    null,
    TagAction.splitPauseAtPlayhead,
  ),
  TagSnippet('WIPE', 'Clear the terminal screen', '[WIPE]'),
  
  // Colors
  TagSnippet('COLOR RED', 'Change text color to RED', '[RED]'),
  TagSnippet('COLOR GREEN', 'Change text color to GREEN', '[GREEN]'),
  TagSnippet('COLOR BLUE', 'Change text color to BLUE', '[BLUE]'),
  TagSnippet('COLOR YELLOW', 'Change text color to YELLOW', '[YELLOW]'),
  TagSnippet('COLOR WHITE', 'Change text color to WHITE', '[WHITE]'),
  TagSnippet('COLOR BLACK', 'Change text color to BLACK', '[BLACK]'),
  TagSnippet('COLOR NORMAL', 'Reset text color to default', '[NORMAL]'),
  
  // Effects
  TagSnippet('FLASH WAVE', 'Staggered color wave effect', '[FLASH:WAVE]'),
  TagSnippet('FLASH INVERT', 'Flashing inverted colors', '[FLASH:INVERT]'),
  TagSnippet('FLASH SPIKE', 'Bright white flash sequence', '[FLASH:SPIKE]'),
  TagSnippet('FLASH RED', 'Flash red', '[FLASH:RED]'),
  TagSnippet('FLASH GREEN', 'Flash green', '[FLASH:GREEN]'),
  TagSnippet('FLASH YELLOW', 'Flash yellow', '[FLASH:YELLOW]'),
  TagSnippet('FLASH OFF', 'Disable flash effect', '[FLASH:OFF]'),
  
  TagSnippet('REDACT', 'Censor text with solid blocks', '[REDACT]text[/REDACT]', 'text'),
  TagSnippet('SCRAMBLE ON', 'Simulate decryption/scrambling', '[SCRAMBLE:on]'),
  TagSnippet('SCRAMBLE OFF', 'Stop scrambling', '[SCRAMBLE:off]'),
  TagSnippet('INVERT ON', 'Swap foreground and background colors', '[INVERT:on]'),
  TagSnippet('INVERT OFF', 'Restore normal foreground/background colors', '[INVERT:off]'),
  TagSnippet('BAR', 'Progress bar (width:frames:fill:empty:brackets)', '[BAR:40:90:=:-:[]]', '40'),
  
  // Formatting
  TagSnippet('ALIGN CENTER', 'Center text alignment', '[ALIGN:CENTER]'),
  TagSnippet('ALIGN LEFT', 'Left text alignment', '[ALIGN:LEFT]'),
  TagSnippet('ALIGN RIGHT', 'Right text alignment', '[ALIGN:RIGHT]'),
  TagSnippet('VPAD', 'Vertical padding (pixels)', '[VPAD:80]', '80'),
  TagSnippet('SIZE', 'Change font size temporarily', '[SIZE:20]', '20'),
  TagSnippet('LEAD', 'Change line spacing temporarily', '[LEAD:15]', '15'),
  
  // Desktop & Presentations
  TagSnippet('GALLERY', 'Image viewer (folder:hold:transition:title)', '[GALLERY:folder:45:FADE:Title]', 'folder'),
  TagSnippet('BROWSER', 'Web browser window (folder:hold:title:scroll)', '[BROWSER:folder:150:Web Browser:SCROLL]', 'folder'),
  TagSnippet('BROWSER FULL', 'Browser window maximizes to full frame', '[BROWSER:folder:150:Web Browser:SCROLL_FULL]', 'folder'),
  TagSnippet('VIDEO', 'Image sequence player (folder:hold:name:fps)', '[VIDEO:folder:60:file.mp4:30]', 'folder'),
  TagSnippet('APP', 'Wii-style uniform image grid (folder:hold:title)', '[APP:folder:90:Title]', 'folder'),
  TagSnippet('APP MOSAIC', 'Metro photo panels in a window, 3 per page', '[APP:folder:90:Photos:MOSAIC]', 'folder'),
  TagSnippet('APP MOSAIC FULL', 'Metro panels, window maximizes to full frame', '[APP:folder:90:Photos:MOSAIC_FULL]', 'folder'),
  TagSnippet('CARD', 'Floating info card panel', '[CARD:image.png:120:180,40,50:HEADING]\nBody text\n[/CARD]', 'image.png'),
  TagSnippet('DOSSIER', 'Card + gallery with configurable center stage', '[DOSSIER:folder:image.png:90:90:0:GRID:180,40,50:HEADING]\nBody text\n[/DOSSIER]', 'folder'),
  TagSnippet('TIMELINE', 'Vertical timeline with events', '[TIMELINE:120:30,30,38:HEADING:folder:150:40:FOCUS]\n2025 | Event text\n[/TIMELINE]', 'HEADING'),
  
  // Terminal Graphics
  TagSnippet('SPRITE', 'ASCII frame animation', '[SPRITE:file.txt:15]', 'file.txt'),
  TagSnippet('SPRITE OFF', 'Freeze ASCII animation', '[SPRITE_OFF:file.txt]', 'file.txt'),
  TagSnippet('SVG', 'Vector stencil', '[SVG:logo.svg:90]', 'logo.svg'),
  TagSnippet('SVGFLASH', 'Glitch sequence from SVG folder', '[SVGFLASH:folder:4:3]', 'folder'),
  TagSnippet('IMG', 'Raster stencil (file:repeat:ch:cadence:release)', '[IMG:file.png:40:R:2:15]', 'file.png'),
  TagSnippet('PHOTO', 'Slow wirephoto scanline reveal', '[PHOTO:image.png:120]', 'image.png'),
  
  // Regions & selection
  TagSnippet('REGION START', 'Begin a named selectable text region', '[REGION:region]', 'region'),
  TagSnippet('REGION END', 'Close the current selectable text region', '[/REGION]'),
  TagSnippet('SELECT', 'Highlight a named region', '[SELECT:region:0,255,0]', 'region'),
  TagSnippet('SELECT CLEAR', 'Clear all region highlights', '[SELECT:NONE]'),

  // Macros
  TagSnippet('DEF MENU', 'Define an interactive menu', '[DEF_MENU:menu_id]\n[ITEM:opt1] Option 1[/ITEM]\n[/DEF_MENU]', 'menu_id'),
  TagSnippet('CALL MENU', 'Draw a defined menu', '[CALL:menu_id]', 'menu_id'),
  TagSnippet('MENU STATE', 'Select an item in a menu', '[MENU_STATE:menu_id:instance_id]', 'menu_id'),
  TagSnippet('MACRO CFG', 'Highlight color and blink for a menu instance', '[MACRO_CFG:instance_id:opt1:0,255,0:0]', 'instance_id'),
  
  // Configs
  // Generated from config_keys.dart rather than listed by hand, so a new
  // CONFIG key appears in the palette and the node dropdown together
  // instead of one of the two being forgotten.
  ...kConfigKeys.map((c) => TagSnippet(
        'CONFIG ${c.key}',
        c.blurb,
        c.sampleTag,
        c.sampleValue,
      )),
];

// ---------------------------------------------------------------------------
// Palette self-check
//
// This list is hand-maintained and the grammar is not, so it drifts. It has
// drifted: VIDEO, REGION, SELECT, INVERT, [BLACK] and three FLASH modes were
// all real markup with no way to insert them, and nothing said so. The
// palette is the discovery surface, so a missing entry does not read as a
// gap in a menu, it reads as a feature that does not exist.
//
// Deriving the palette from the grammar outright is not possible: tagRegex
// knows the SHAPE of [GALLERY:folder:hold:transition:title] but not that it
// should be called GALLERY, described as an image viewer, or exemplified
// with a folder named "folder". Labels, descriptions and example values are
// editorial. What can be derived is whether the editorial content is still
// TRUE, and that is what this checks.
//
// Debug only. A wrong palette is a bad menu, not a broken render, and it
// should never take down a bake in front of an audience.
// ---------------------------------------------------------------------------

/// Throws in debug if the palette and the grammar disagree. Returns true so
/// it can be called from inside an `assert`.
bool debugValidateTagPalette() {
  final List<String> problems = [];

  // 1. Every snippet must survive the real grammar. Asking the linter rather
  //    than tagRegex directly is deliberate: the linter already knows which
  //    bracketed constructs (DEF_MENU, ITEM, CALL, MACRO_CFG, MENU_STATE)
  //    live outside tagRegex by design, so macro snippets are not false
  //    positives here.
  for (final t in kAllTags) {
    final findings = ScriptLinter.lint(t.insertText);
    if (findings.isNotEmpty) {
      problems.add('"${t.label}" does not parse: ${findings.first.message}');
    }
  }

  // 2. Every tag the grammar knows must be insertable from somewhere.
  //    LINE is exempt: the editor injects it for line tracking and it is
  //    never authored.
  const Set<String> notAuthored = {'LINE'};
  for (final tag in ScriptLinter.knownTags) {
    if (notAuthored.contains(tag)) continue;
    final bool covered = kAllTags.any((t) => t.insertText.contains('[$tag'));
    if (!covered) problems.add('grammar has [$tag] with no palette entry');
  }

  // 3. Labels are how a snippet is found and how it is told apart in the
  //    list. Two entries sharing one is a menu you cannot navigate.
  final Set<String> seen = {};
  for (final t in kAllTags) {
    if (!seen.add(t.label)) problems.add('duplicate label "${t.label}"');
  }

  // 4. A placeholder is highlighted on insert so it can be typed over.
  //    One that is not in the text it belongs to selects nothing.
  for (final t in kAllTags) {
    final String? p = t.placeholder;
    if (p != null && !t.insertText.contains(p)) {
      problems.add('"${t.label}" placeholder "$p" is not in its insert text');
    }
  }

  if (problems.isNotEmpty) {
    throw FlutterError('Tag palette is out of step with the grammar:\n'
        '  ${problems.join('\n  ')}');
  }
  return true;
}

class EditorTagMenu extends StatefulWidget {
  final R3Theme theme;
  final FocusNode searchFocusNode;
  final ValueChanged<TagSnippet> onTagSelected;
  final VoidCallback onClose;

  const EditorTagMenu({
    super.key,
    required this.theme,
    required this.searchFocusNode,
    required this.onTagSelected,
    required this.onClose,
  });

  @override
  State<EditorTagMenu> createState() => EditorTagMenuState();
}

class EditorTagMenuState extends State<EditorTagMenu> {
  String _searchQuery = "";
  int _selectedIndex = 0;

  @override
  void initState() {
    super.initState();
    // Debug only: assert bodies are stripped in release, so a release build
    // never pays for this and never throws from it. Opening the menu is the
    // right moment to check, because it is the moment the palette is about
    // to be believed.
    assert(debugValidateTagPalette());
  }

  List<TagSnippet> get _filteredTags {
    if (_searchQuery.isEmpty) return kAllTags;
    final q = _searchQuery.toLowerCase();
    return kAllTags.where((t) => 
        t.label.toLowerCase().contains(q) || 
        t.description.toLowerCase().contains(q) ||
        t.insertText.toLowerCase().contains(q)
    ).toList();
  }

  /// Called by the parent (EditorScreen) when the user presses Tab 
  /// while the menu is already open, allowing them to cycle down quickly.
  void cycleSelection() {
    final filtered = _filteredTags;
    if (filtered.isEmpty) return;
    setState(() {
      _selectedIndex = (_selectedIndex + 1) % filtered.length;
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.theme;
    final filtered = _filteredTags;

    return Material(
      color: Colors.transparent,
      child: Container(
        width: sc(450),
        constraints: BoxConstraints(maxHeight: sc(380)),
        decoration: BoxDecoration(
          color: R3Theme.panelHi,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: R3Theme.hairline, width: 1.5),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.5),
              blurRadius: sc(20),
              offset: Offset(0, sc(10)),
            )
          ]
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Search Input
            Padding(
              padding: EdgeInsets.all(sc(8)),
              child: Focus(
                onKeyEvent: (node, event) {
                   if (event is KeyDownEvent) {
                      if (event.logicalKey == LogicalKeyboardKey.escape) {
                         widget.onClose();
                         return KeyEventResult.handled;
                      }
                      if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
                         setState(() {
                            _selectedIndex = (_selectedIndex + 1).clamp(0, filtered.length - 1);
                         });
                         return KeyEventResult.handled;
                      }
                      if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
                         setState(() {
                            _selectedIndex = (_selectedIndex - 1).clamp(0, filtered.length - 1);
                         });
                         return KeyEventResult.handled;
                      }
                      if (event.logicalKey == LogicalKeyboardKey.enter) {
                         if (filtered.isNotEmpty) {
                            widget.onTagSelected(filtered[_selectedIndex]);
                         }
                         return KeyEventResult.handled;
                      }
                   }
                   return KeyEventResult.ignored;
                },
                child: TextField(
                  focusNode: widget.searchFocusNode,
                  onChanged: (val) {
                     setState(() {
                        _searchQuery = val;
                        _selectedIndex = 0;
                     });
                  },
                  style: t.value,
                  decoration: InputDecoration(
                    hintText: "Search markup tags (e.g. CARD, IMG, FLASH)...",
                    prefixIcon: Icon(Icons.search, size: sc(16), color: R3Theme.textMid),
                    isDense: true,
                  ),
                ),
              ),
            ),
            
            Container(height: 1, color: R3Theme.hairline),
            
            // Results List
            if (filtered.isEmpty)
               Padding(
                 padding: EdgeInsets.all(sc(24)),
                 child: Center(
                   child: Text("NO TAGS FOUND", style: t.micro)
                 ),
               )
            else
               Flexible(
                 child: ListView.builder(
                   shrinkWrap: true,
                   itemCount: filtered.length,
                   itemBuilder: (ctx, idx) {
                      final tag = filtered[idx];
                      final bool isSelected = idx == _selectedIndex;
                      
                      return InkWell(
                        onTap: () => widget.onTagSelected(tag),
                        child: Container(
                          color: isSelected ? t.accentDim.withValues(alpha: 0.25) : Colors.transparent,
                          padding: EdgeInsets.symmetric(horizontal: sc(14), vertical: sc(10)),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Text(tag.label, style: t.value.copyWith(
                                     color: isSelected ? t.accent : R3Theme.textBright,
                                     fontWeight: isSelected ? FontWeight.bold : FontWeight.w600
                                  )),
                                  const Spacer(),
                                  Text(tag.insertText.replaceAll('\n', r'\n'), style: t.fine.copyWith(
                                    color: isSelected ? R3Theme.textMid : R3Theme.textDim,
                                    fontSize: sc(10.5)
                                  )),
                                ]
                              ),
                              SizedBox(height: sc(4)),
                              Text(tag.description, style: t.fine),
                            ]
                          )
                        )
                      );
                   }
                 )
               )
          ]
        )
      )
    );
  }
}