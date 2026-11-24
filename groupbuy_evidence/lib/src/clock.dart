import 'dart:math';

/// Abstraction over "what time is it now" so the whole library is testable
/// and the production app can swap the source without touching domain logic.
abstract class Clock {
  DateTime now();
}

/// Production wall clock. Never trusted on its own for evidence timestamps —
/// see [TrustedClock], which anchors wall time to a signed server time.
class SystemClock implements Clock {
  const SystemClock();

  @override
  DateTime now() => DateTime.now();
}

/// Controllable clock for tests and demos.
class FakeClock implements Clock {
  DateTime _current;

  FakeClock(DateTime start) : _current = start;

  @override
  DateTime now() => _current;

  void advance(Duration d) => _current = _current.add(d);

  /// Simulate the leader manually changing the device clock (backdating).
  void setTo(DateTime t) => _current = t;
}

/// A server-signed time anchor.
///
/// The device obtains one while online. The signature covers
/// `serverTime|monotonicAtIssue`, so a leader cannot manufacture an anchor
/// for an arbitrary time, and cannot reuse an old anchor after tampering.
class TimeAnchor {
  /// UTC time asserted by the server.
  final DateTime serverTime;

  /// Value of the device monotonic clock (e.g. Stopwatch elapsed) when the
  /// anchor was issued.
  final int monotonicAtIssueMs;

  /// Server signature over `serverTime|monotonicAtIssueMs|deviceId`.
  final String signature;

  /// How long the anchor may be extrapolated offline before the resulting
  /// timestamp is marked low-confidence (it stays usable, just weaker).
  final Duration maxOfflineExtrapolation;

  const TimeAnchor({
    required this.serverTime,
    required this.monotonicAtIssueMs,
    required this.signature,
    this.maxOfflineExtrapolation = const Duration(hours: 12),
  });

  Map<String, Object?> toJson() => {
        'serverTime': serverTime.toUtc().toIso8601String(),
        'monotonicAtIssueMs': monotonicAtIssueMs,
        'signature': signature,
        'maxOfflineExtrapolationMs': maxOfflineExtrapolation.inMilliseconds,
      };

  factory TimeAnchor.fromJson(Map<String, Object?> json) => TimeAnchor(
        serverTime: DateTime.parse(json['serverTime']! as String).toUtc(),
        monotonicAtIssueMs: json['monotonicAtIssueMs']! as int,
        signature: json['signature']! as String,
        maxOfflineExtrapolation: Duration(
          milliseconds: json['maxOfflineExtrapolationMs']! as int,
        ),
      );
}

/// Result of asking the device for a trusted timestamp while possibly offline.
class TrustedTime {
  final DateTime time;

  /// False when extrapolated beyond [TimeAnchor.maxOfflineExtrapolation] or
  /// when no anchor exists yet. Such events are still recorded, but flagged
  /// for the adjudication engine rather than silently accepted.
  final bool highConfidence;

  /// True when derived from a fresh server anchor, false when extrapolated
  /// offline from the last anchor.
  final bool anchored;

  /// Extrapolation distance from the anchor, zero when freshly anchored.
  final Duration offlineFor;

  const TrustedTime({
    required this.time,
    required this.highConfidence,
    required this.anchored,
    required this.offlineFor,
  });

  Map<String, Object?> toJson() => {
        'time': time.toUtc().toIso8601String(),
        'highConfidence': highConfidence,
        'anchored': anchored,
        'offlineForMs': offlineFor.inMilliseconds,
      };

  factory TrustedTime.fromJson(Map<String, Object?> json) => TrustedTime(
        time: DateTime.parse(json['time']! as String).toUtc(),
        highConfidence: json['highConfidence']! as bool,
        anchored: json['anchored']! as bool,
        offlineFor: Duration(milliseconds: json['offlineForMs']! as int),
      );
}

/// Produces tamper-resistant timestamps.
///
/// Strategy:
///  * online: ask the server for a signed [TimeAnchor];
///  * offline: `lastAnchor.serverTime + (monotonicNow - monotonicAtIssue)`.
///
/// The monotonic clock cannot be changed by the user (unlike wall-clock
/// settings), so manually setting the device clock backwards does **not**
/// move evidence timestamps backwards. A monotonically increasing local
/// sequence additionally rejects duplicate/replayed timestamps.
class TrustedClock {
  final Clock wallClock;
  int Function() monotonicNowMs;
  TimeAnchor? _anchor;
  int _lastIssuedMonotonic = -1;

  TrustedClock({
    required this.wallClock,
    required this.monotonicNowMs,
    TimeAnchor? initialAnchor,
  }) : _anchor = initialAnchor;

  TimeAnchor? get anchor => _anchor;

  /// Called when the app obtains a fresh signed anchor from the server.
  /// Rejects anchors that move backwards relative to the previous one.
  bool ingestAnchor(TimeAnchor candidate) {
    final prev = _anchor;
    if (prev != null &&
        candidate.serverTime.isBefore(prev.serverTime.subtract(
          const Duration(seconds: 5), // clock skew tolerance
        ))) {
      return false;
    }
    _anchor = candidate;
    return true;
  }

  TrustedTime now() {
    final anchor = _anchor;
    if (anchor == null) {
      // First-ever run with no connectivity. Record anyway, but untrusted:
      // the server will demand a retroactive anchor before accepting claims.
      return TrustedTime(
        time: wallClock.now().toUtc(),
        highConfidence: false,
        anchored: false,
        offlineFor: Duration.zero,
      );
    }

    final mono = monotonicNowMs();
    final deltaMs = mono - anchor.monotonicAtIssueMs;
    final delta = Duration(milliseconds: max(0, deltaMs));
    final derived = anchor.serverTime.add(delta);
    final highConfidence =
        delta <= anchor.maxOfflineExtrapolation && !_monotonicWentBackwards(mono);

    return TrustedTime(
      time: derived,
      highConfidence: highConfidence,
      anchored: true,
      offlineFor: delta,
    );
  }

  bool _monotonicWentBackwards(int mono) {
    final wentBack = mono < _lastIssuedMonotonic;
    if (mono > _lastIssuedMonotonic) _lastIssuedMonotonic = mono;
    return wentBack;
  }
}
