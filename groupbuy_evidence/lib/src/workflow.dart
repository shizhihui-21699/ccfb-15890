import 'aftersale.dart';
import 'event.dart';
import 'ledger.dart';
import 'photo.dart';
import 'pickup_code.dart';

/// Inputs for the warehouse handoff of a whole batch.
class BatchHandoff {
  final String batchId;
  final String warehouseId;
  final List<String> orderIds;
  final List<PhotoEvidence> batchPhotos;
  final double lat;
  final double lng;

  const BatchHandoff({
    required this.batchId,
    required this.warehouseId,
    required this.orderIds,
    required this.batchPhotos,
    required this.lat,
    required this.lng,
  });
}

/// Result of attempting to close a pickup.
class PickupResult {
  final CodeCheck check;
  final EvidenceEvent? event;

  const PickupResult(this.check, this.event);

  bool get ok => check == CodeCheck.ok;
}

class AftersaleResult {
  final AftersaleCodeCheck check;
  final EvidenceEvent? event;

  const AftersaleResult(this.check, this.event);

  bool get ok => check == AftersaleCodeCheck.ok;
}

/// Single entry point the Flutter UI uses. Every method is safe to call with
/// no connectivity: it writes the signed ledger event locally and returns.
/// Sync is a separate, retryable step.
class LeaderWorkflowService {
  final EventLedger ledger;
  final OfflineCodeVerifier pickupVerifier;
  final AftersaleVerifier aftersaleVerifier;
  final PhotoRegistry photoRegistry;

  LeaderWorkflowService({
    required this.ledger,
    required this.pickupVerifier,
    required this.aftersaleVerifier,
    required this.photoRegistry,
  });

  /// Batch header: one signed event covering the whole handoff.
  Future<EvidenceEvent> receiveBatch(BatchHandoff h) async {
    for (final p in h.batchPhotos) {
      photoRegistry.register(p);
    }
    return ledger.append(EventDraft(EventType.batchReceived, {
      'batchId': h.batchId,
      'warehouseId': h.warehouseId,
      'orderIds': h.orderIds,
      'photoHashes': h.batchPhotos.map((p) => p.sha256Hex).toList(),
      'geo': {'lat': h.lat, 'lng': h.lng},
    }));
  }

  /// Fast per-parcel scan path. One camera shot + one ledger append per
  /// parcel; measured cost is dominated by the camera, not cryptography.
  Future<EvidenceEvent> scanOrderReceived({
    required String orderId,
    required String batchId,
    required String skuSummary,
    required PhotoEvidence photo,
    required double lat,
    required double lng,
  }) async {
    if (!photoRegistry.register(photo)) {
      throw StateError(
        'Photo ${photo.sha256Hex} was already used — refusing to attach a '
        'reused picture to order $orderId',
      );
    }
    if (!photoRegistry.bindToOrder(photo.sha256Hex, orderId)) {
      throw StateError('Photo already bound to another order');
    }
    return ledger.append(EventDraft(EventType.orderReceived, {
      'orderId': orderId,
      'batchId': batchId,
      'skuSummary': skuSummary,
      'photoHash': photo.sha256Hex,
      'geo': {'lat': lat, 'lng': lng},
    }));
  }

  Future<EvidenceEvent> markSorted({
    required String orderId,
    required String shelfCode,
  }) =>
      ledger.append(EventDraft(EventType.orderSorted, {
        'orderId': orderId,
        'shelfCode': shelfCode,
      }));

  /// Resident pickup with the 6-digit code. [noCodeReason] is required when
  /// no code is presented and is itself evidence (e.g. "resident lost phone"
  /// requires a second-staff witness id in the real app).
  Future<PickupResult> recordPickup({
    required String orderId,
    String? residentCode,
    String? noCodeReason,
  }) async {
    final hasCode = residentCode != null && residentCode.isNotEmpty;
    if (!hasCode && (noCodeReason == null || noCodeReason.isEmpty)) {
      throw ArgumentError(
        'Pickup requires either a resident code or a noCodeReason',
      );
    }

    var check = CodeCheck.ok;
    if (hasCode) {
      check = pickupVerifier.verify(orderId, residentCode);
      if (check != CodeCheck.ok) {
        return PickupResult(check, null);
      }
    }

    final event = await ledger.append(EventDraft(EventType.orderPickedUp, {
      'orderId': orderId,
      // Never store the cleartext code; store its hash for later audit.
      'residentCodeHash': hasCode
          ? _codeHash(residentCode)
          : null,
      'codeVerified': hasCode,
      'noCodeReason': hasCode ? null : noCodeReason,
    }));
    return PickupResult(check, event);
  }

  /// Leader-side exception (shortage at handoff, damage, spoilage...).
  /// A photo is mandatory: text-only exception claims are how diverted stock
  /// gets explained away.
  Future<EvidenceEvent> reportException({
    required String orderId,
    required String reason,
    required PhotoEvidence photo,
    required String stage, // handoff | sorting | storage
  }) async {
    if (!photoRegistry.register(photo)) {
      throw StateError('Exception photo was already used for another claim');
    }
    photoRegistry.bindToOrder(photo.sha256Hex, orderId);
    return ledger.append(EventDraft(EventType.exceptionReported, {
      'orderId': orderId,
      'reason': reason,
      'photoHash': photo.sha256Hex,
      'stage': stage,
    }));
  }

  /// After-sales claim. Only succeeds when the resident's authorization code
  /// verifies, and the ledger records that the refund target is the
  /// resident's own payment account.
  Future<AftersaleResult> submitAftersale({
    required String claimId,
    required String orderId,
    required String reason,
    required List<PhotoEvidence> photos,
    required String residentAuthCode,
    required String refundTarget,
    required int amountMinor,
  }) async {
    for (final p in photos) {
      if (!photoRegistry.register(p)) {
        return AftersaleResult(AftersaleCodeCheck.wrong, null);
      }
      photoRegistry.bindToOrder(p.sha256Hex, orderId);
    }

    final check = aftersaleVerifier.verify(
      claimId: claimId,
      code: residentAuthCode,
      claimedAmountMinor: amountMinor,
    );
    if (check != AftersaleCodeCheck.ok) {
      return AftersaleResult(check, null);
    }

    final event = await ledger.append(EventDraft(EventType.aftersaleRequested, {
      'orderId': orderId,
      'claimId': claimId,
      'reason': reason,
      'photoHashes': photos.map((p) => p.sha256Hex).toList(),
      'residentAuthCodeHash': _codeHash(residentAuthCode),
      'refundTarget': refundTarget,
      'amount': amountMinor,
    }));
    aftersaleVerifier.markUsed(claimId);
    return AftersaleResult(check, event);
  }

  /// Ingests a server checkpoint pinning the current chain head. The server
  /// signs this; the device stores it as a normal chain event, after which
  /// rewriting history also requires forging the server signature.
  Future<EvidenceEvent> ingestCheckpoint({
    required String upToEventId,
    required String upToHash,
    required String serverSignature,
  }) =>
      ledger.append(EventDraft(EventType.checkpoint, {
        'upToEventId': upToEventId,
        'upToHash': upToHash,
        'serverSignature': serverSignature,
      }));

  static String _codeHash(String code) =>
      // Reuse the same salted hash helper as after-sales auth codes.
      hashResidentAuthCode(code);
}
