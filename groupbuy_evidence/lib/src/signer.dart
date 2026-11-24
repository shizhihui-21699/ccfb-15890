import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'canonical_json.dart';

/// A signature over canonical JSON.
///
/// The production implementation is HMAC-SHA256 with a per-device secret
/// provisioned at enrollment and held in the platform keystore
/// (iOS Keychain / Android Keystore-backed storage). The interface allows
/// swapping in an asymmetric signer (Ed25519) without touching the ledger:
/// with asymmetric keys the server only ever holds a public key, so a
/// compromised backend cannot forge device-signed events.
abstract class EvidenceSigner {
  /// Stable identifier of the key the signature was produced with.
  String get keyId;

  /// Signs [canonicalBytes] and returns the signature as a hex string.
  String signBytes(List<int> canonicalBytes);

  /// Verifies [hexSignature] against [canonicalBytes]. Implementations must
  /// use constant-time comparison.
  bool verifyBytes(List<int> canonicalBytes, String hexSignature);

  String signJson(Object? payload) =>
      signBytes(utf8.encode(canonicalJson(payload)));

  bool verifyJson(Object? payload, String hexSignature) =>
      verifyBytes(utf8.encode(canonicalJson(payload)), hexSignature);
}

/// HMAC-SHA256 signer. The secret must be injected, never hard-coded.
class HmacEvidenceSigner extends EvidenceSigner {
  final List<int> _secret;

  @override
  final String keyId;

  HmacEvidenceSigner({required List<int> secret, required this.keyId})
      : _secret = List<int>.unmodifiable(secret);

  factory HmacEvidenceSigner.fromSecretHex({
    required String secretHex,
    required String keyId,
  }) {
    final bytes = Uint8List(secretHex.length ~/ 2);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = int.parse(secretHex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return HmacEvidenceSigner(secret: bytes, keyId: keyId);
  }

  @override
  String signBytes(List<int> canonicalBytes) {
    final hmac = Hmac(sha256, _secret);
    return hmac.convert(canonicalBytes).bytes.map(_hex).join();
  }

  @override
  bool verifyBytes(List<int> canonicalBytes, String hexSignature) {
    final expected = signBytes(canonicalBytes);
    return _constantTimeEquals(expected, hexSignature);
  }

  static String _hex(int b) => b.toRadixString(16).padLeft(2, '0');

  static bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }
}

/// Convenience: SHA-256 hex digest over canonical JSON.
String sha256HexOfJson(Object? payload) {
  final digest = sha256.convert(utf8.encode(canonicalJson(payload)));
  return digest.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
