import 'dart:math';
import 'dart:typed_data';

import 'package:groupbuy_evidence/groupbuy_evidence.dart';

/// Test/demo helpers that assemble the same production wiring the Flutter
/// app uses, with controllable clocks and synthetic camera bytes.
class TestRig {
  final FakeClock wallClock;
  late final TrustedClock trustedClock;
  final HmacEvidenceSigner signer;
  final MemoryLedgerStorage storage;
  final PhotoRegistry photos;
  late final EventLedger ledger;
  int _monoMs = 0;

  TestRig._({
    required this.wallClock,
    required this.signer,
    required this.storage,
    required this.photos,
    TimeAnchor? anchor,
  }) {
    trustedClock = TrustedClock(
      wallClock: wallClock,
      monotonicNowMs: () => _monoMs,
      initialAnchor: anchor,
    );
    ledger = EventLedger(
      config: LedgerConfig(
        deviceId: 'dev-test-01',
        leaderId: 'leader-01',
        genesisHash: 'genesis-dev-test-01',
      ),
      signer: signer,
      clock: trustedClock,
      storage: storage,
      photoRegistry: photos,
    );
  }

  factory TestRig.create({
    DateTime? startTime,
    bool withAnchor = true,
    List<int>? secret,
  }) {
    final start = startTime ?? DateTime.utc(2026, 11, 24, 8);
    final rig = TestRig._(
      wallClock: FakeClock(start),
      signer: HmacEvidenceSigner(
        secret: secret ?? List<int>.generate(32, (i) => i + 1),
        keyId: 'key-test-01',
      ),
      storage: MemoryLedgerStorage(),
      photos: PhotoRegistry(),
      anchor: withAnchor
          ? TimeAnchor(
              serverTime: start,
              monotonicAtIssueMs: 0,
              signature: 'srv-sig-demo',
            )
          : null,
    );
    return rig;
  }

  /// Advances both wall and monotonic clocks (the normal passage of time).
  void elapse(Duration d) {
    wallClock.advance(d);
    _monoMs += d.inMilliseconds;
  }

  /// Simulates the leader manually changing the device wall clock. The
  /// monotonic clock is untouched, exactly like a real OS setting change.
  void tamperWallClock(DateTime t) => wallClock.setTo(t);

  int monotonicMs() => _monoMs;

  PhotoEvidence fakePhoto(String seed) {
    final bytes = Uint8List.fromList(
      utf8Encode('camera-capture-$seed-${DateTime.now().microsecond}'),
    );
    return PhotoRegistry.fromBytes(
      bytes,
      mimeType: 'image/jpeg',
      capturedAt: wallClock.now(),
      lat: 31.23,
      lng: 121.47,
    );
  }

  static List<int> utf8Encode(String s) => [for (final c in s.codeUnits) c];
}

List<int> demoSecret(int seed) =>
    List<int>.generate(32, (i) => (i * 7 + seed) % 256);

/// Deterministic counter assignments for N fake orders: order-0001 ...
List<CounterAssignment> assignments(int n) => [
      for (var i = 1; i <= n; i++)
        CounterAssignment('order-${i.toString().padLeft(4, '0')}', 1000 + i),
];

String orderId(int i) => 'order-${i.toString().padLeft(4, '0')}';

final _rng = Random(42);

List<int> randomishBytes(String tag, int n) =>
    List<int>.generate(n, (i) => (tag.codeUnitAt(i % tag.length) + i + _rng.nextInt(256)) % 256);
