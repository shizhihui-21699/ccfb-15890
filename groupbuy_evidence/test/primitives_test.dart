import 'dart:convert';

import 'package:groupbuy_evidence/groupbuy_evidence.dart';
import 'package:test/test.dart';

void main() {
  group('canonicalJson', () {
    test('map keys are sorted regardless of insertion order', () {
      final a = canonicalJson({'b': 1, 'a': 2, 'c': {'z': 1, 'y': 2}});
      final b = canonicalJson({'c': {'y': 2, 'z': 1}, 'a': 2, 'b': 1});
      expect(a, equals(b));
      expect(a, equals('{"a":2,"b":1,"c":{"y":2,"z":1}}'));
    });

    test('produces compact output with no whitespace', () {
      expect(canonicalJson([1, 'x', true, null]), equals('[1,"x",true,null]'));
    });

    test('escapes JSON control characters', () {
      expect(canonicalJson('a"b\\c\n'), equals(r'"a\"b\\c\n"'));
    });

    test('deterministic across nested structures', () {
      final payload = {
        'orderId': 'o1',
        'amount': 1234,
        'tags': ['fresh', 'cold'],
        'meta': {'shelf': 'A-1', 'seq': 3},
      };
      expect(
        canonicalJson(payload),
        equals(
          '{"amount":1234,"meta":{"seq":3,"shelf":"A-1"},'
          '"orderId":"o1","tags":["fresh","cold"]}',
        ),
      );
    });
  });

  group('HmacEvidenceSigner', () {
    final signer = HmacEvidenceSigner(
      secret: utf8.encode('unit-test-secret'),
      keyId: 'k1',
    );

    test('sign then verify round-trips', () {
      final body = utf8.encode('evidence-body');
      final sig = signer.signBytes(body);
      expect(signer.verifyBytes(body, sig), isTrue);
    });

    test('a single flipped byte fails verification', () {
      final body = utf8.encode('evidence-body');
      final sig = signer.signBytes(body);
      final tampered = List<int>.from(body)..[3] ^= 0xff;
      expect(signer.verifyBytes(tampered, sig), isFalse);
    });

    test('canonical JSON signatures agree on equal data in different order',
        () {
      final sig1 = signer.signJson({'a': 1, 'b': 2});
      final sig2 = signer.signJson({'b': 2, 'a': 1});
      expect(sig1, equals(sig2));
      expect(signer.verifyJson({'a': 1, 'b': 2}, sig1), isTrue);
    });
  });

  group('TrustedClock', () {
    final t0 = DateTime.utc(2026, 11, 24, 8);
    var mono = 0;
    final clock = TrustedClock(
      wallClock: SystemClock(),
      monotonicNowMs: () => mono,
      initialAnchor: TimeAnchor(
        serverTime: t0,
        monotonicAtIssueMs: 0,
        signature: 'sig',
      ),
    );

    test('extrapolates server time from the monotonic clock', () {
      mono = 60 * 1000;
      final t = clock.now();
      expect(t.time, equals(t0.add(const Duration(minutes: 1))));
      expect(t.anchored, isTrue);
      expect(t.highConfidence, isTrue);
    });

    test('flags low confidence past the offline extrapolation window', () {
      mono = const Duration(hours: 13).inMilliseconds;
      final t = clock.now();
      expect(t.highConfidence, isFalse);
      expect(t.offlineFor, const Duration(hours: 13));
    });

    test('rejects an anchor that moves backwards', () {
      final ok = clock.ingestAnchor(TimeAnchor(
        serverTime: t0.subtract(const Duration(hours: 1)),
        monotonicAtIssueMs: mono,
        signature: 'sig2',
      ));
      expect(ok, isFalse);
    });

    test('unanchored first run is explicitly marked untrusted', () {
      final fresh = TrustedClock(
        wallClock: const SystemClock(),
        monotonicNowMs: () => 0,
      );
      final t = fresh.now();
      expect(t.anchored, isFalse);
      expect(t.highConfidence, isFalse);
    });
  });
}
