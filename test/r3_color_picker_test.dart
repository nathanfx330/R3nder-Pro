// ./test/r3_color_picker_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/r3_color_picker.dart';

void main() {
  test('hex formatting and parsing round-trip opaque RGB', () {
    const Color color = Color(0xFF336699);
    expect(r3ColorHex(color), '#336699');
    expect(parseR3ColorHex('#336699')?.toARGB32(), color.toARGB32());
    expect(parseR3ColorHex('336699')?.toARGB32(), color.toARGB32());
  });

  test('short hex expands and malformed values are rejected', () {
    expect(parseR3ColorHex('#369')?.toARGB32(), 0xFF336699);
    expect(parseR3ColorHex('#12'), isNull);
    expect(parseR3ColorHex('#GGHHII'), isNull);
  });
}
