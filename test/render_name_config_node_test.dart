// ./test/render_name_config_node_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/config_keys.dart';
import 'package:r3nder/script_nodes.dart';

void main() {
  test('RENDERNAME is exposed as a first-class text CONFIG key', () {
    final ConfigKeySpec? spec = configSpecFor('RENDERNAME');
    expect(spec, isNotNull);
    expect(spec!.kind, ConfigValueKind.text);
    expect(spec.defaultValue, 'output');
    expect(spec.sampleTag, '[CONFIG:RENDERNAME:documentary_cut]');
    expect(kConfigKeyNames, contains('RENDERNAME'));
  });

  test('RENDERNAME CONFIG parses and rewrites through ScriptNode', () {
    final List<ScriptNode> nodes =
        parseScriptToNodes('[CONFIG:RENDERNAME:Documentary Cut]\n');
    final ScriptNode config =
        nodes.firstWhere((ScriptNode node) => node.type == 'CONFIG');

    expect(config.param('key'), 'RENDERNAME');
    expect(config.param('value'), 'Documentary Cut');
    expect(config.toMarkup(), '[CONFIG:RENDERNAME:Documentary Cut]');

    config.set('value', 'Master Cut');
    expect(config.toMarkup(), '[CONFIG:RENDERNAME:Master Cut]');
  });
}
