import 'canonical_json.dart';
import 'signer.dart';

/// Every state transition in the leader's workflow is one of these events.
/// The closed enum + per-type required payload fields make "I signed for an
/// order that never arrived" reconstructable: there is simply no valid event
/// path that turns an order into PICKED_UP without a RECEIVED event whose
/// photo hash the warehouse also attests.
enum EventType {
  /// Batch header: warehouse handoff of a shipment to the leader.
  batchReceived,

  /// One order/parcel scanned as physically received.
  orderReceived,

  /// Leader marks the parcel sorted into the self-pickup shelf.
  orderSorted,

  /// Resident collected the parcel (with or without pickup code).
  orderPickedUp,

  /// Leader reports a parcel missing/damaged *before* pickup.
  exceptionReported,

  /// Resident-initiated after-sales claim, authorized by the resident.
  aftersaleRequested,

  /// Server checkpoint pinning the head of the hash chain.
  checkpoint,
}

EventType eventTypeFromString(String s) =>
    EventType.values.firstWhere((e) => e.name == s);

/// Required payload keys per event type. Unknown extra keys are allowed (they
/// are covered by the hash), missing keys make the event invalid.
const Map<EventType, List<String>> requiredPayloadFields = {
  EventType.batchReceived: [
    'batchId',
    'warehouseId',
    'orderIds',
    'photoHashes',
    'geo',
  ],
  EventType.orderReceived: [
    'orderId',
    'batchId',
    'skuSummary',
    'photoHash',
    'geo',
  ],
  EventType.orderSorted: ['orderId', 'shelfCode'],
  EventType.orderPickedUp: [
    'orderId',
    'residentCodeHash',
    'codeVerified',
    'noCodeReason',
  ],
  EventType.exceptionReported: [
    'orderId',
    'reason',
    'photoHash',
    'stage',
  ],
  EventType.aftersaleRequested: [
    'orderId',
    'claimId',
    'reason',
    'photoHashes',
    'residentAuthCodeHash',
    'refundTarget',
    'amount',
  ],
  EventType.checkpoint: ['upToEventId', 'upToHash'],
};

/// One immutable evidence record.
///
/// `selfHash` = SHA256 over the canonical encoding of all fields except
/// `selfHash` and `signature` (which includes `prevHash`). `signature` is the
/// device signer over that same canonical body. The chain order is
/// append-only on the device and independently replayed on the server.
class EvidenceEvent {
  final String eventId;
  final int seq;
  final EventType type;
  final String deviceId;
  final String leaderId;
  final DateTime timestamp;

  /// Whether [timestamp] came from a server anchor (see clock.dart).
  final bool timeAnchored;
  final bool timeHighConfidence;
  final int offlineForMs;

  /// Hash of the previous event, or the genesis hash for the first event.
  final String prevHash;
  final Map<String, Object?> payload;

  /// SHA256 hex of the canonical body. Filled by the ledger on append.
  final String selfHash;

  /// Device signature hex over the canonical body.
  final String signature;

  const EvidenceEvent({
    required this.eventId,
    required this.seq,
    required this.type,
    required this.deviceId,
    required this.leaderId,
    required this.timestamp,
    required this.timeAnchored,
    required this.timeHighConfidence,
    required this.offlineForMs,
    required this.prevHash,
    required this.payload,
    required this.selfHash,
    required this.signature,
  });

  /// The exact bytes that get hashed and signed. Keeping this construction in
  /// one place guarantees device and server compute the identical input.
  Map<String, Object?> signedBody() => {
        'eventId': eventId,
        'seq': seq,
        'type': type.name,
        'deviceId': deviceId,
        'leaderId': leaderId,
        'timestamp': timestamp.toUtc().toIso8601String(),
        'timeAnchored': timeAnchored,
        'timeHighConfidence': timeHighConfidence,
        'offlineForMs': offlineForMs,
        'prevHash': prevHash,
        'payload': payload,
      };

  String canonicalBody() => canonicalJson(signedBody());

  Map<String, Object?> toJson() => {
        ...signedBody(),
        'selfHash': selfHash,
        'signature': signature,
      };

  factory EvidenceEvent.fromJson(Map<String, Object?> json) => EvidenceEvent(
        eventId: json['eventId']! as String,
        seq: json['seq']! as int,
        type: eventTypeFromString(json['type']! as String),
        deviceId: json['deviceId']! as String,
        leaderId: json['leaderId']! as String,
        timestamp: DateTime.parse(json['timestamp']! as String).toUtc(),
        timeAnchored: json['timeAnchored']! as bool,
        timeHighConfidence: json['timeHighConfidence']! as bool,
        offlineForMs: json['offlineForMs']! as int,
        prevHash: json['prevHash']! as String,
        payload: Map<String, Object?>.from(json['payload']! as Map),
        selfHash: json['selfHash']! as String,
        signature: json['signature']! as String,
      );
}

/// Builder for unsigned events. The ledger assigns seq/prevHash/hash/signature
/// on append, so application code cannot construct a "valid" event by itself.
class EventDraft {
  final EventType type;
  final Map<String, Object?> payload;
  final String? eventId;

  const EventDraft(this.type, this.payload, {this.eventId});
}

/// Recomputes the hash of an existing event exactly as the ledger would.
String hashEventBody(EvidenceEvent e) => sha256HexOfJson(e.signedBody());
