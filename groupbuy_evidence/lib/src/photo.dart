import 'package:crypto/crypto.dart';

/// A photo captured straight from the camera at evidence time.
///
/// The anti-forgery property does not come from trusting EXIF (trivially
/// editable) but from hashing the bytes *at capture time*, immediately
/// embedding that hash in the signed ledger event, and only later uploading
/// the bytes. A leader cannot substitute a gallery picture: its hash would
/// not match the hash signed inside the event. Server-side image forensics
/// (duplicate detection across orders, JPEG re-encoding markers) is a second
/// layer on top of this binding.
class PhotoEvidence {
  /// SHA-256 hex of the raw captured bytes.
  final String sha256Hex;

  /// Bytes size — a second cheap integrity check and a sanity bound.
  final int byteLength;

  /// "image/jpeg", "image/heic", ...
  final String mimeType;

  /// Capture instant as reported by the camera callback, not by the user.
  final DateTime capturedAt;

  /// Present when the platform camera supplies an embedded location.
  final double? lat;
  final double? lng;

  const PhotoEvidence({
    required this.sha256Hex,
    required this.byteLength,
    required this.mimeType,
    required this.capturedAt,
    this.lat,
    this.lng,
  });

  Map<String, Object?> toJson() => {
        'sha256Hex': sha256Hex,
        'byteLength': byteLength,
        'mimeType': mimeType,
        'capturedAt': capturedAt.toUtc().toIso8601String(),
        'lat': lat,
        'lng': lng,
      };

  factory PhotoEvidence.fromJson(Map<String, Object?> json) => PhotoEvidence(
        sha256Hex: json['sha256Hex']! as String,
        byteLength: json['byteLength']! as int,
        mimeType: json['mimeType']! as String,
        capturedAt: DateTime.parse(json['capturedAt']! as String).toUtc(),
        lat: json['lat'] as double?,
        lng: json['lng'] as double?,
      );
}

/// Registry binding photo hashes to the event that first used them.
///
/// Two integrity rules:
///  1. a hash must be registered *before* (or at) the event that cites it —
///     you cannot reference a photo that never existed at capture time;
///  2. one photo hash can evidence only one order. Reusing the same picture
///     for two "missing goods" claims is the textbook resale-cover pattern.
class PhotoRegistry {
  final Map<String, PhotoEvidence> _byHash = {};
  final Map<String, String> _hashToOrder = {};

  /// Registers a freshly captured photo. Returns false on a duplicate hash.
  bool register(PhotoEvidence photo) {
    if (_byHash.containsKey(photo.sha256Hex)) return false;
    _byHash[photo.sha256Hex] = photo;
    return true;
  }

  /// Binds a registered photo to an order. Rejects reuse for another order.
  bool bindToOrder(String photoHash, String orderId) {
    if (!_byHash.containsKey(photoHash)) return false;
    final existing = _hashToOrder[photoHash];
    if (existing != null) return existing == orderId;
    _hashToOrder[photoHash] = orderId;
    return true;
  }

  PhotoEvidence? lookup(String hash) => _byHash[hash];
  String? orderOf(String hash) => _hashToOrder[hash];
  int get size => _byHash.length;

  /// Convenience used by the real camera integration and by tests:
  /// hash raw capture bytes in one call.
  static PhotoEvidence fromBytes(
    List<int> bytes, {
    required String mimeType,
    required DateTime capturedAt,
    double? lat,
    double? lng,
  }) {
    final digest = sha256.convert(bytes);
    return PhotoEvidence(
      sha256Hex: digest.bytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join(),
      byteLength: bytes.length,
      mimeType: mimeType,
      capturedAt: capturedAt.toUtc(),
      lat: lat,
      lng: lng,
    );
  }
}

/// Helper used by tests/demos to hash raw bytes cheaply.
String hashOfBytes(List<int> bytes) => sha256.convert(bytes).bytes
    .map((b) => b.toRadixString(16).padLeft(2, '0'))
    .join();
