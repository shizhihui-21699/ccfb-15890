import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'pickup_code.dart';

/// One after-sales authorization the server issued to a resident and synced
/// to the leader's device in the claim manifest.
///
/// The resident receives a 6-digit code by SMS/voice (elderly residents do
/// not need an app). The code is derived from a HOTP-style HMAC over the
/// order id, claim counter, **and refund amount**, so:
///   * the leader cannot invent a valid code offline;
///   * a code for order A cannot be attached to order B;
///   * a code issued for a 20-yuan refund cannot authorize a 200-yuan claim.
class AftersaleAuthorization {
  final String orderId;
  final String claimId;
  final int counter;

  /// Refund amount in minor units (fen), bound into the code.
  final int amountMinor;

  /// Codes are short-lived; an expired code fails even when the device is
  /// offline and cannot ask the server.
  final DateTime expiresAt;

  /// Masked resident payment account the refund *must* return to, e.g.
  /// "微信支付 ****1234". The full account lives only on the server.
  final String residentRefundTargetMasked;

  const AftersaleAuthorization({
    required this.orderId,
    required this.claimId,
    required this.counter,
    required this.amountMinor,
    required this.expiresAt,
    required this.residentRefundTargetMasked,
  });

  Map<String, Object?> toJson() => {
        'orderId': orderId,
        'claimId': claimId,
        'counter': counter,
        'amountMinor': amountMinor,
        'expiresAt': expiresAt.toUtc().toIso8601String(),
        'residentRefundTargetMasked': residentRefundTargetMasked,
      };

  factory AftersaleAuthorization.fromJson(Map<String, Object?> json) =>
      AftersaleAuthorization(
        orderId: json['orderId']! as String,
        claimId: json['claimId']! as String,
        counter: json['counter']! as int,
        amountMinor: json['amountMinor']! as int,
        expiresAt: DateTime.parse(json['expiresAt']! as String).toUtc(),
        residentRefundTargetMasked:
            json['residentRefundTargetMasked']! as String,
      );
}

enum AftersaleCodeCheck {
  ok,
  wrong,
  locked,
  unknownClaim,
  expired,
  amountMismatch,
  alreadyUsed,
}

/// The bytes covered by the authorization code. Kept in one place because
/// the server issuer and the offline verifier must agree exactly.
List<int> _aftersaleMessage({
  required String orderId,
  required int counter,
  required int amountMinor,
}) {
  final counterBytes = ByteData(8)..setUint64(0, counter);
  final amountBytes = ByteData(8)..setUint64(0, amountMinor);
  return [
    ...utf8.encode(Hotp.aftersaleTag),
    0x00,
    ...counterBytes.buffer.asUint8List(),
    ...amountBytes.buffer.asUint8List(),
    ...utf8.encode(orderId),
  ];
}

/// Server-side issuer.
class AftersaleCodeIssuer {
  final List<int> secret;

  const AftersaleCodeIssuer({required this.secret});

  String issueCode({
    required String orderId,
    required int counter,
    required int amountMinor,
    int digits = 6,
  }) {
    final hmac = Hmac(sha256, secret)
        .convert(_aftersaleMessage(
          orderId: orderId,
          counter: counter,
          amountMinor: amountMinor,
        ))
        .bytes;
    final offset = hmac.last & 0x0f;
    final bin = ((hmac[offset] & 0x7f) << 24) |
        ((hmac[offset + 1] & 0xff) << 16) |
        ((hmac[offset + 2] & 0xff) << 8) |
        (hmac[offset + 3] & 0xff);
    return (bin % _pow10(digits)).toString().padLeft(digits, '0');
  }

  static int _pow10(int digits) {
    var v = 1;
    for (var i = 0; i < digits; i++) {
      v *= 10;
    }
    return v;
  }
}

/// Offline verifier running on the leader's phone, with the same brute-force
/// and single-use protections as pickup verification.
class AftersaleVerifier {
  final List<int> _secret;
  final Map<String, AftersaleAuthorization> _byClaim = {};
  final Map<String, int> _failures = {};
  final Set<String> _usedClaimIds = {};
  final int maxFailures;
  final DateTime Function() _now;

  AftersaleVerifier({
    required List<int> secret,
    required List<AftersaleAuthorization> manifest,
    required DateTime Function() now,
    this.maxFailures = 5,
  })  : _secret = List<int>.unmodifiable(secret),
        _now = now {
    for (final a in manifest) {
      _byClaim[a.claimId] = a;
    }
  }

  /// Verifies the code the resident read out over the phone / at the shelf.
  AftersaleCodeCheck verify({
    required String claimId,
    required String code,
    required int claimedAmountMinor,
  }) {
    final auth = _byClaim[claimId];
    if (auth == null) return AftersaleCodeCheck.unknownClaim;
    if (_usedClaimIds.contains(claimId)) return AftersaleCodeCheck.alreadyUsed;
    if ((_failures[claimId] ?? 0) >= maxFailures) {
      return AftersaleCodeCheck.locked;
    }
    if (_now().isAfter(auth.expiresAt)) return AftersaleCodeCheck.expired;
    if (claimedAmountMinor != auth.amountMinor) {
      return AftersaleCodeCheck.amountMismatch;
    }

    final hmac = Hmac(sha256, _secret)
        .convert(_aftersaleMessage(
          orderId: auth.orderId,
          counter: auth.counter,
          amountMinor: auth.amountMinor,
        ))
        .bytes;
    final offset = hmac.last & 0x0f;
    final bin = ((hmac[offset] & 0x7f) << 24) |
        ((hmac[offset + 1] & 0xff) << 16) |
        ((hmac[offset + 2] & 0xff) << 8) |
        (hmac[offset + 3] & 0xff);
    final expected = (bin % 1000000).toString().padLeft(6, '0');

    if (!Hotp.constantTimeEquals(expected, code)) {
      _failures[claimId] = (_failures[claimId] ?? 0) + 1;
      return (_failures[claimId] ?? 0) >= maxFailures
          ? AftersaleCodeCheck.locked
          : AftersaleCodeCheck.wrong;
    }
    _failures.remove(claimId);
    // Consumption happens only when the caller actually records the claim;
    // markUsed() is invoked together with the ledger append.
    return AftersaleCodeCheck.ok;
  }

  /// Marks a claim consumed after its ledger event was appended.
  void markUsed(String claimId) => _usedClaimIds.add(claimId);

  bool isUsed(String claimId) => _usedClaimIds.contains(claimId);

  AftersaleAuthorization? authorizationFor(String claimId) => _byClaim[claimId];
}

/// Hash stored in the ledger payload instead of the cleartext code: the code
/// itself transits verbally and must not sit in long-term storage.
String hashResidentAuthCode(String code) =>
    sha256.convert(utf8.encode('resident-auth:$code')).bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
