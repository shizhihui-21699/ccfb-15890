import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// RFC 4226 HOTP, truncated to 6 decimal digits, with a domain tag so a code
/// issued for one purpose can never be replayed for another.
///
/// Both the server (which texts the code to the resident) and the leader's
/// phone (which verifies it in the warehouse basement with no signal) derive
/// the same value from a per-batch secret that was delivered to the device
/// during the last online sync. Nothing about a code is validated "in the
/// cloud" at pickup time — connectivity is not on the resident's path.
class Hotp {
  /// Domain separation tags. A pickup code must fail after-sales verification
  /// and vice versa, even if the digits happen to match.
  static const String pickupTag = 'GB-PICKUP-v1';
  static const String aftersaleTag = 'GB-AFTERSALE-v1';

  static String generate({
    required List<int> secret,
    required String tag,
    required int counter,
    int digits = 6,
  }) {
    final counterBytes = ByteData(8)..setUint64(0, counter);
    final message = <int>[
      ...utf8.encode(tag),
      0x00,
      ...counterBytes.buffer.asUint8List(),
    ];
    final hmac = Hmac(sha256, secret).convert(message);
    final hash = hmac.bytes;
    // Dynamic truncation (RFC 4226 §5.3), using the low 4 bits of last byte.
    final offset = hash.last & 0x0f;
    final bin = ((hash[offset] & 0x7f) << 24) |
        ((hash[offset + 1] & 0xff) << 16) |
        ((hash[offset + 2] & 0xff) << 8) |
        (hash[offset + 3] & 0xff);
    final mod = pow(10, digits).toInt();
    return (bin % mod).toString().padLeft(digits, '0');
  }

  /// Constant-time string comparison so failed attempts cannot be timed.
  static bool constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }
}

/// Per-order counter assignment handed to the device with the batch manifest.
class CounterAssignment {
  final String orderId;
  final int counter;

  const CounterAssignment(this.orderId, this.counter);

  Map<String, Object?> toJson() => {'orderId': orderId, 'counter': counter};

  factory CounterAssignment.fromJson(Map<String, Object?> json) =>
      CounterAssignment(json['orderId']! as String, json['counter']! as int);
}

/// Result of an offline verification attempt.
enum CodeCheck {
  ok,
  wrong,
  locked, // too many wrong attempts: online re-issue required
  unknownOrder,
}

/// Tracks brute-force lockout state for one order.
class _AttemptState {
  int failures = 0;
  bool locked = false;
}

/// Verifies pickup codes fully offline.
///
/// Security properties:
///  * secret never leaves the device keystore in production;
///  * at most [maxFailures] guesses per order, then the order is locked until
///    the device goes online and the server re-issues a code — six digits
///    only give 10^6 space, so unbounded guessing is not acceptable;
///  * verification is constant-time;
///  * lockout state itself is not security-critical to persist (a reboot
///    resetting it merely restores a small offline guess budget), but the
///    server independently rate-limits re-issues.
class OfflineCodeVerifier {
  final List<int> _secret;
  final String _tag;
  final int maxFailures;
  final Map<String, int> _counters;
  final Map<String, _AttemptState> _attempts = {};

  OfflineCodeVerifier({
    required List<int> secret,
    required List<CounterAssignment> assignments,
    String tag = Hotp.pickupTag,
    this.maxFailures = 5,
  })  : _secret = List<int>.unmodifiable(secret),
        _tag = tag,
        _counters = {for (final a in assignments) a.orderId: a.counter};

  CodeCheck verify(String orderId, String code) {
    final counter = _counters[orderId];
    if (counter == null) return CodeCheck.unknownOrder;

    final state = _attempts.putIfAbsent(orderId, _AttemptState.new);
    if (state.locked) return CodeCheck.locked;

    final expected = Hotp.generate(
      secret: _secret,
      tag: _tag,
      counter: counter,
    );
    if (Hotp.constantTimeEquals(expected, code)) {
      state.failures = 0;
      return CodeCheck.ok;
    }
    state.failures += 1;
    if (state.failures >= maxFailures) state.locked = true;
    return state.locked ? CodeCheck.locked : CodeCheck.wrong;
  }

  /// Called after a successful online sync: server can unlock re-issued codes.
  void unlock(String orderId) => _attempts.remove(orderId);

  bool isLocked(String orderId) => _attempts[orderId]?.locked ?? false;

  int failuresFor(String orderId) => _attempts[orderId]?.failures ?? 0;
}

/// Server-side issuer: produces the code that goes out by SMS/voice.
class CodeIssuer {
  final List<int> secret;
  final String tag;

  const CodeIssuer({required this.secret, required this.tag});

  String issue(int counter) =>
      Hotp.generate(secret: secret, tag: tag, counter: counter);
}
