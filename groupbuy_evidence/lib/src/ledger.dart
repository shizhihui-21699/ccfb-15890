import 'dart:convert';
import 'dart:math';

import 'clock.dart';
import 'event.dart';
import 'photo.dart';
import 'signer.dart';
import 'storage.dart';

/// Why a single event failed verification.
enum ChainError {
  seqGap,
  seqDuplicate,
  prevHashMismatch,
  selfHashMismatch,
  signatureMismatch,
  missingRequiredPayloadField,
  timestampOutOfOrder,
  checkpointMismatch,
  payloadNotCanonicalizable,
}

class VerificationFailure {
  final int seq;
  final String eventId;
  final ChainError error;
  final String detail;

  const VerificationFailure(this.seq, this.eventId, this.error, this.detail);

  @override
  String toString() => '[$seq $eventId] ${error.name}: $detail';
}

/// Outcome of replaying the whole chain independently (the server does this).
class ChainVerificationResult {
  final int eventsChecked;
  final List<VerificationFailure> failures;

  /// Last server checkpoint found while replaying, with the chain agreeing up
  /// to that point. Events before it cannot be silently rewritten.
  final EvidenceEvent? lastValidCheckpoint;

  const ChainVerificationResult(
    this.eventsChecked,
    this.failures,
    this.lastValidCheckpoint,
  );

  bool get valid => failures.isEmpty;
}

/// Server checkpoint pinning the chain head.
class CheckpointRecord {
  final String upToEventId;
  final String upToHash;
  final DateTime serverTime;
  final String serverSignature;

  const CheckpointRecord({
    required this.upToEventId,
    required this.upToHash,
    required this.serverTime,
    required this.serverSignature,
  });
}

/// Configuration for one leader device's ledger.
class LedgerConfig {
  final String deviceId;
  final String leaderId;

  /// Genesis previous-hash. Derived from device enrollment so a different
  /// device cannot share a chain.
  final String genesisHash;

  const LedgerConfig({
    required this.deviceId,
    required this.leaderId,
    required this.genesisHash,
  });
}

/// The append-only, hash-chained, locally signed evidence ledger.
///
/// Performance: append is one SHA-256 + one HMAC over a small JSON body and a
/// buffered file write — sub-millisecond on a phone, so scanning hundreds of
/// parcels at the warehouse gate is bound by the camera, not the ledger.
class EventLedger {
  final LedgerConfig config;
  final EvidenceSigner signer;
  final TrustedClock clock;
  final LedgerStorage storage;
  final PhotoRegistry? photoRegistry;

  final List<EvidenceEvent> _events = [];
  final Random _rng;
  CheckpointRecord? _lastCheckpoint;

  /// Ids of events already delivered to the server (the sync outbox queue
  /// removes them). Re-uploads after a crash never duplicate server-side.
  final Set<String> syncedEventIds = {};

  EventLedger({
    required this.config,
    required this.signer,
    required this.clock,
    required this.storage,
    this.photoRegistry,
    Random? random,
  }) : _rng = random ?? Random.secure();

  int get length => _events.length;
  List<EvidenceEvent> get events => List.unmodifiable(_events);
  CheckpointRecord? get lastCheckpoint => _lastCheckpoint;
  String get headHash => _events.isEmpty ? config.genesisHash : _events.last.selfHash;

  /// Rehydrates a chain from storage. Used at app startup; returns failures
  /// found in persisted data (e.g. an edited ledger file).
  Future<ChainVerificationResult> load() async {
    final rows = await storage.readAll();
    _events.clear();
    syncedEventIds.clear();
    _lastCheckpoint = null;
    for (final row in rows) {
      _events.add(EvidenceEvent.fromJson(row));
    }
    final result = verifyChain(_events, signer, config.genesisHash);
    final cp = result.lastValidCheckpoint;
    if (cp != null) {
      _lastCheckpoint = CheckpointRecord(
        upToEventId: cp.payload['upToEventId']! as String,
        upToHash: cp.payload['upToHash']! as String,
        serverTime: cp.timestamp,
        serverSignature: cp.payload['serverSignature']! as String,
      );
    }
    return result;
  }

  /// Appends one workflow event to the chain.
  ///
  /// Never throws on weak connectivity — the ledger is the offline source of
  /// truth. Throws only on programming errors: missing required payload
  /// fields or a payload that cannot be canonicalized.
  Future<EvidenceEvent> append(EventDraft draft) async {
    final required = requiredPayloadFields[draft.type];
    if (required != null) {
      for (final key in required) {
        if (!draft.payload.containsKey(key)) {
          throw ArgumentError(
            'Event ${draft.type.name} requires payload field "$key"',
          );
        }
      }
    }

    final trusted = clock.now();
    final seq = _events.length;
    final eventId = draft.eventId ?? 'ev_${seq}_${_shortRandom()}';
    final prevHash = headHash;

    final unsigned = EvidenceEvent(
      eventId: eventId,
      seq: seq,
      type: draft.type,
      deviceId: config.deviceId,
      leaderId: config.leaderId,
      timestamp: trusted.time,
      timeAnchored: trusted.anchored,
      timeHighConfidence: trusted.highConfidence,
      offlineForMs: trusted.offlineFor.inMilliseconds,
      prevHash: prevHash,
      payload: draft.payload,
      selfHash: '',
      signature: '',
    );

    final body = unsigned.canonicalBody();
    final selfHash = sha256HexOfJson(unsigned.signedBody());
    final bodyBytes = utf8.encode(body);
    final signature = signer.signBytes(bodyBytes);

    final signed = EvidenceEvent(
      eventId: unsigned.eventId,
      seq: unsigned.seq,
      type: unsigned.type,
      deviceId: unsigned.deviceId,
      leaderId: unsigned.leaderId,
      timestamp: unsigned.timestamp,
      timeAnchored: unsigned.timeAnchored,
      timeHighConfidence: unsigned.timeHighConfidence,
      offlineForMs: unsigned.offlineForMs,
      prevHash: unsigned.prevHash,
      payload: unsigned.payload,
      selfHash: selfHash,
      signature: signature,
    );

    _events.add(signed);
    await storage.appendJson(signed.toJson());

    if (draft.type == EventType.checkpoint) {
      _lastCheckpoint = CheckpointRecord(
        upToEventId: signed.payload['upToEventId']! as String,
        upToHash: signed.payload['upToHash']! as String,
        serverTime: signed.timestamp,
        serverSignature: signed.payload['serverSignature']! as String,
      );
    }
    return signed;
  }

  /// Persists buffered writes (call before app backgrounding).
  Future<void> flush() => storage.flush();

  /// Events the server has not acknowledged yet — the sync outbox.
  List<EvidenceEvent> pendingSync() =>
      _events.where((e) => !syncedEventIds.contains(e.eventId)).toList();

  void markSynced(Iterable<String> eventIds) =>
      syncedEventIds.addAll(eventIds);

  /// All events touching one order, in chain order.
  List<EvidenceEvent> eventsForOrder(String orderId) => _events
      .where((e) =>
          e.payload['orderId'] == orderId ||
          (e.payload['orderIds'] as List?)?.contains(orderId) == true)
      .toList();

  String _shortRandom() {
    final bytes = List<int>.generate(8, (_) => _rng.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Independent replay. Pure/static so the server can run exactly the same
  /// code against events uploaded from a device it does not trust.
  static ChainVerificationResult verifyChain(
    List<EvidenceEvent> events,
    EvidenceSigner signer,
    String genesisHash, {
    CheckpointRecord? expectedCheckpoint,
  }) {
    final failures = <VerificationFailure>[];
    var expectedPrev = genesisHash;
    var lastTs = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    EvidenceEvent? lastValidCheckpoint;

    for (var i = 0; i < events.length; i++) {
      final e = events[i];
      // 1. Sequence continuity.
      if (e.seq != i) {
        failures.add(VerificationFailure(
          e.seq,
          e.eventId,
          ChainError.seqGap,
          'expected seq $i',
        ));
      }

      // 2. Payload schema.
      final required = requiredPayloadFields[e.type];
      if (required != null) {
        for (final key in required) {
          if (!e.payload.containsKey(key)) {
            failures.add(VerificationFailure(
              e.seq,
              e.eventId,
              ChainError.missingRequiredPayloadField,
              key,
            ));
          }
        }
      }

      // 3. Hash link.
      if (e.prevHash != expectedPrev) {
        failures.add(VerificationFailure(
          e.seq,
          e.eventId,
          ChainError.prevHashMismatch,
          'expected $expectedPrev got ${e.prevHash}',
        ));
      }

      // 4. Self hash over the canonical body.
      try {
        final recomputed = sha256HexOfJson(e.signedBody());
        if (recomputed != e.selfHash) {
          failures.add(VerificationFailure(
            e.seq,
            e.eventId,
            ChainError.selfHashMismatch,
            'expected $recomputed',
          ));
        }
      } on ArgumentError catch (err) {
        failures.add(VerificationFailure(
          e.seq,
          e.eventId,
          ChainError.payloadNotCanonicalizable,
          err.message as String,
        ));
      }

      // 5. Device signature.
      if (!signer.verifyBytes(utf8.encode(e.canonicalBody()), e.signature)) {
        failures.add(VerificationFailure(
          e.seq,
          e.eventId,
          ChainError.signatureMismatch,
          'device signature does not verify',
        ));
      }

      // 6. Monotonic timestamps (tolerant of equal timestamps in fast scans).
      if (e.timestamp.isBefore(lastTs.subtract(const Duration(seconds: 1)))) {
        failures.add(VerificationFailure(
          e.seq,
          e.eventId,
          ChainError.timestampOutOfOrder,
          '${e.timestamp} before $lastTs',
        ));
      } else {
        lastTs = e.timestamp;
      }

      // 7. Checkpoint internal consistency.
      if (e.type == EventType.checkpoint) {
        final upToHash = e.payload['upToHash'] as String?;
        if (upToHash != expectedPrev && e.seq > 0) {
          failures.add(VerificationFailure(
            e.seq,
            e.eventId,
            ChainError.checkpointMismatch,
            'checkpoint pins $upToHash but chain head is $expectedPrev',
          ));
        } else {
          lastValidCheckpoint = e;
        }
      }

      expectedPrev = e.selfHash;
    }

    if (expectedCheckpoint != null) {
      final pinned = events
          .where((e) => e.eventId == expectedCheckpoint.upToEventId)
          .toList();
      if (pinned.isEmpty || pinned.single.selfHash != expectedCheckpoint.upToHash) {
        failures.add(VerificationFailure(
          -1,
          expectedCheckpoint.upToEventId,
          ChainError.checkpointMismatch,
          'server-pinned checkpoint not found in chain',
        ));
      }
    }

    return ChainVerificationResult(events.length, failures, lastValidCheckpoint);
  }
}
