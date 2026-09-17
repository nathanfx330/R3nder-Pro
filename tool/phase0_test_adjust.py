from pathlib import Path

path = Path('test/edit_workspace_test.dart')
text = path.read_text()
name = "testWidgets('ADD VIDEO appends when playhead is inside existing V1 clip',"
start = text.find(name)
if start < 0:
    raise SystemExit('new ADD VIDEO regression test not found')
end = text.find("  testWidgets('ADD OVERLAY creates V2 at current edit playhead',", start)
if end < 0:
    raise SystemExit('ADD OVERLAY marker not found after new regression test')
block = text[start:end]

height = '          height: 700,\n'
if block.count(height) != 1:
    raise SystemExit(
        f'expected one height anchor in new regression block, found {block.count(height)}'
    )
block = block.replace(height, '          height: 900,\n', 1)

opening = "      (WidgetTester tester) async {\n    String latest ="
if block.count(opening) != 1:
    raise SystemExit(
        f'expected one widget-test opening anchor, found {block.count(opening)}'
    )
block = block.replace(
    opening,
    "      (WidgetTester tester) async {\n"
    "    await tester.binding.setSurfaceSize(const Size(1200, 1000));\n"
    "    addTearDown(() async {\n"
    "      await tester.binding.setSurfaceSize(null);\n"
    "    });\n"
    "    String latest =",
    1,
)

path.write_text(text[:start] + block + text[end:])
