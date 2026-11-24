import 'dart:convert';

import 'package:groupbuy_evidence/groupbuy_evidence.dart';
import 'package:test/test.dart';

import 'helpers.dart';

Future<EvidenceEvent> _appendScan(TestRig rig, String orderId) =>
    rig.ledger.append(EventDraft(EventType.orderReceived, {
      'orderId': orderId,
      'batchId': 'b1',
      'skuSummary': 'milk x2',
      'photoHash': rig.fakePhoto(orderId).sha256Hex,
      'geo': {'lat': 31.23, 'lng': 121.47},
    }));

void main() {
  group('EventLedger happy path', () {
    test('appends form a valid hash chain with monotonic seq', () async {
      final rig = TestRig.create();
      for (var i = 0; i < 10; i++) {
        rig.elapse(const Duration(seconds: 2));
        await _appendScan(rig, orderId(i + 1));
      }
      final result = EventLedger.verifyChain(
        rig.ledger.events,
        rig.signer,
        rig.ledger.config.genesisHash,
      );
      expect(result.valid, isTrue, reason: result.failures.toString());
      expect(result.eventsChecked, 10);
      for (var i = 0; i < 10; i++) {
        expect(rig.ledger.events[i].seq, i);
      }
    });

    test('rejects drafts missing required payload fields', () async {
      final rig = TestRig.create();
      expect(
        () => rig.ledger
            .append(EventDraft(EventType.orderReceived, {'orderId': 'o1'})),
        throwsArgumentError,
      );
    });

    test('round-trips through storage and re-verifies after reload',
        () async {
      final rig = TestRig.create();
      await _appendScan(rig, orderId(1));
      await _appendScan(rig, orderId(2));

      final reloaded = TestRig.create();
      // Share the same underlying storage rows.
      reloaded.storage.rows.addAll(rig.storage.rows);
      final result = await reloaded.ledger.load();
      expect(result.valid, isTrue);
      expect(reloaded.ledger.length, 2);
      expect(reloaded.ledger.headHash, rig.ledger.headHash);
    });

    test('persisted JSON is parseable JSONL with self-hash and signature',
        () async {
      final rig = TestRig.create();
      await _appendScan(rig, orderId(1));
      final row = rig.storage.rows.single;
      expect(row['selfHash'], isA<String>());
      expect(row['signature'], isA<String>());
      expect((row['selfHash'] as String).length, 64);
      // The row itself must re-encode deterministically.
      expect(() => jsonEncode(row), returnsNormally);
    });

    test('load restores the server checkpoint pinned in the chain', () async {
      final rig = TestRig.create();
      await _appendScan(rig, orderId(1));
      final head = rig.ledger.headHash;
      final headEventId = rig.ledger.events.last.eventId;
      await rig.ledger.append(EventDraft(EventType.checkpoint, {
        'upToEventId': headEventId,
        'upToHash': head,
        'serverSignature': 'server-sig-9',
      }));

      final reloaded = TestRig.create();
      reloaded.storage.rows.addAll(rig.storage.rows);
      final result = await reloaded.ledger.load();
      expect(result.valid, isTrue);
      expect(reloaded.ledger.lastCheckpoint?.upToHash, head);
      expect(reloaded.ledger.lastCheckpoint?.serverSignature, 'server-sig-9');
    });
  });

  group('Tamper detection', () {
    test('editing an old payload breaks its self-hash', () async {
      final rig = TestRig.create();
      await _appendScan(rig, orderId(1));
      await _appendScan(rig, orderId(2));
      final events = [
        for (final e in rig.ledger.events)
          EvidenceEvent.fromJson(
              jsonDecode(jsonEncode(e.toJson())) as Map<String, Object?>)
      ];
      final tampered = EvidenceEvent(
        eventId: events[0].eventId,
        seq: events[0].seq,
        type: events[0].type,
        deviceId: events[0].deviceId,
        leaderId: events[0].leaderId,
        timestamp: events[0].timestamp,
        timeAnchored: events[0].timeAnchored,
        timeHighConfidence: events[0].timeHighConfidence,
        offlineForMs: events[0].offlineForMs,
        prevHash: events[0].prevHash,
        payload: {...events[0].payload, 'skuSummary': 'wagyu beef x99'},
        selfHash: events[0].selfHash,
        signature: events[0].signature,
      );
      events[0] = tampered;
      final result =
          EventLedger.verifyChain(events, rig.signer, rig.ledger.config.genesisHash);
      expect(result.valid, isFalse);
      expect(result.failures.map((f) => f.error),
          contains(ChainError.selfHashMismatch));
    });

    test('re-hashing a tampered event still fails the device signature',
        () async {
      final rig = TestRig.create();
      await _appendScan(rig, orderId(1));
      final original = rig.ledger.events.single;
      final tamperedBody = EvidenceEvent(
        eventId: original.eventId,
        seq: original.seq,
        type: original.type,
        deviceId: original.deviceId,
        leaderId: original.leaderId,
        timestamp: original.timestamp,
        timeAnchored: original.timeAnchored,
        timeHighConfidence: original.timeHighConfidence,
        offlineForMs: original.offlineForMs,
        prevHash: original.prevHash,
        payload: {...original.payload, 'orderId': 'order-9999'},
        selfHash: '',
        signature: '',
      );
      final rehashed = EvidenceEvent(
        eventId: tamperedBody.eventId,
        seq: tamperedBody.seq,
        type: tamperedBody.type,
        deviceId: tamperedBody.deviceId,
        leaderId: tamperedBody.leaderId,
        timestamp: tamperedBody.timestamp,
        timeAnchored: tamperedBody.timeAnchored,
        timeHighConfidence: tamperedBody.timeHighConfidence,
        offlineForMs: tamperedBody.offlineForMs,
        prevHash: tamperedBody.prevHash,
        payload: tamperedBody.payload,
        selfHash: hashEventBody(tamperedBody),
        signature: original.signature, // attacker lacks the device key
      );
      final result = EventLedger.verifyChain(
          [rehashed], rig.signer, rig.ledger.config.genesisHash);
      expect(result.failures.map((f) => f.error),
          contains(ChainError.signatureMismatch));
    });

    test('deleting an event breaks seq continuity and the hash link',
        () async {
      final rig = TestRig.create();
      for (var i = 1; i <= 3; i++) {
        await _appendScan(rig, orderId(i));
      }
      final events = [...rig.ledger.events]..removeAt(1);
      final result =
          EventLedger.verifyChain(events, rig.signer, rig.ledger.config.genesisHash);
      expect(result.failures.map((f) => f.error),
          contains(ChainError.prevHashMismatch));
    });

    test('checkpoint pinning detects a rewritten prefix', () async {
      final rig = TestRig.create();
      await _appendScan(rig, orderId(1));
      final head = rig.ledger.headHash;
      await rig.ledger.append(EventDraft(EventType.checkpoint, {
        'upToEventId': rig.ledger.events.last.eventId,
        'upToHash': head,
        'serverSignature': 'server-sig-1',
      }));
      await _appendScan(rig, orderId(2));

      // Attacker rewrites history; server still holds the old checkpoint.
      final serverCheckpoint = CheckpointRecord(
        upToEventId: rig.ledger.events.first.eventId,
        upToHash: 'stale-hash-from-server',
        serverTime: DateTime.utc(2026, 11, 24),
        serverSignature: 'server-sig-1',
      );
      final result = EventLedger.verifyChain(
        rig.ledger.events,
        rig.signer,
        rig.ledger.config.genesisHash,
        expectedCheckpoint: serverCheckpoint,
      );
      expect(result.failures.map((f) => f.error),
          contains(ChainError.checkpointMismatch));
    });
  });

  group('Clock manipulation resistance', () {
    test('setting the wall clock backwards cannot backdate evidence',
        () async {
      final rig = TestRig.create();
      rig.elapse(const Duration(hours: 2));
      final before = (await _appendScan(rig, orderId(1))).timestamp;

      // Leader manually rolls the device clock back by a day.
      rig.tamperWallClock(DateTime.utc(2026, 11, 23));
      rig.elapse(const Duration(minutes: 5));
      final after = (await _appendScan(rig, orderId(2))).timestamp;

      expect(after.isAfter(before), isTrue,
          reason: 'monotonic-derived time must keep moving forward');
      expect(after.difference(before), const Duration(minutes: 5));
    });
  });
}
