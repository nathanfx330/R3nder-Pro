// ./test/audio_packet_contract_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:r3nder/audio_sink.dart';

void main() {
  group('PreviewPcmPacketContract', () {
    const PreviewPcmPacketContract contract = PreviewPcmPacketContract(
      sampleRate: 48000,
      channels: 2,
    );

    test('10 ms is exactly 480 stereo s16le frames at 48 kHz', () {
      expect(PreviewPcmPacketContract.packetDurationMicroseconds, 10000);
      expect(contract.framesPerPacket, 480);
      expect(contract.bytesPerFrame, 4);
      expect(contract.bytesPerPacket, 1920);
    });

    test('full packets and one shorter EOF tail are the only valid sequence', () {
      expect(
        contract.validatePacketByteCount(
          contract.bytesPerPacket,
          shortTailAlreadyAccepted: false,
        ),
        isFalse,
      );

      expect(
        contract.validatePacketByteCount(
          120 * contract.bytesPerFrame,
          shortTailAlreadyAccepted: false,
        ),
        isTrue,
      );

      expect(
        () => contract.validatePacketByteCount(
          contract.bytesPerPacket,
          shortTailAlreadyAccepted: true,
        ),
        throwsStateError,
      );
    });

    test('oversized and frame-misaligned packets are rejected', () {
      expect(
        () => contract.validatePacketByteCount(
          contract.bytesPerPacket + contract.bytesPerFrame,
          shortTailAlreadyAccepted: false,
        ),
        throwsArgumentError,
      );
      expect(
        () => contract.validatePacketByteCount(
          contract.bytesPerPacket - 1,
          shortTailAlreadyAccepted: false,
        ),
        throwsArgumentError,
      );
    });

    test('packet duration must be representable as an exact PCM frame count', () {
      const PreviewPcmPacketContract inexact = PreviewPcmPacketContract(
        sampleRate: 22050,
        channels: 2,
      );
      expect(() => inexact.framesPerPacket, throwsStateError);
    });
  });
}
