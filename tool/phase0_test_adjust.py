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
old = '          height: 700,\n'
if block.count(old) != 1:
    raise SystemExit(f'expected one height anchor in new regression block, found {block.count(old)}')
block = block.replace(old, '          height: 900,\n', 1)
path.write_text(text[:start] + block + text[end:])
