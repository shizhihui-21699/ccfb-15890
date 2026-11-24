import 'package:groupbuy_evidence/groupbuy_evidence.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  group('PhotoRegistry', () {
    test('rejects the same photo bytes for two orders', () {
      final rig = TestRig.create();
      final photo = rig.fakePhoto('p1');
      expect(rig.photos.register(photo), isTrue);
      expect(rig.photos.register(photo), isFalse,
          reason: 'duplicate hash = reused picture');
      expect(rig.photos.bindToOrder(photo.sha256Hex, orderId(1)), isTrue);
      expect(rig.photos.bindToOrder(photo.sha256Hex, orderId(2)), isFalse);
      expect(rig.photos.orderOf(photo.sha256Hex), orderId(1));
    });

    test('distinct captures get distinct hashes', () {
      final rig = TestRig.create();
      final a = rig.fakePhoto('a');
      final b = rig.fakePhoto('b');
      expect(a.sha256Hex, isNot(equals(b.sha256Hex)));
    });
  });

  group('LeaderWorkflowService end-to-end', () {
    TestRig rig() => TestRig.create();

    LeaderWorkflowService service(
      TestRig rig, {
      List<int>? pickupSecret,
      List<int>? aftersaleSecret,
      List<AftersaleAuthorization>? aftersaleManifest,
    }) {
      final now = rig.wallClock.now();
      return LeaderWorkflowService(
        ledger: rig.ledger,
        pickupVerifier: OfflineCodeVerifier(
          secret: pickupSecret ?? demoSecret(2),
          assignments: assignments(4),
        ),
        aftersaleVerifier: AftersaleVerifier(
          secret: aftersaleSecret ?? demoSecret(3),
          manifest: aftersaleManifest ?? const [],
          now: () => now,
        ),
        photoRegistry: rig.photos,
      );
    }

    test('full offline batch: handoff, scan, sort, code pickup, sync',
        () async {
      final r = rig();
      final secret = demoSecret(2);
      final svc = service(r, pickupSecret: secret);

      await svc.receiveBatch(BatchHandoff(
        batchId: 'b1',
        warehouseId: 'wh-1',
        orderIds: [orderId(1), orderId(2)],
        batchPhotos: [r.fakePhoto('batch')],
        lat: 31.23,
        lng: 121.47,
      ));
      await svc.scanOrderReceived(
        orderId: orderId(1),
        batchId: 'b1',
        skuSummary: 'milk',
        photo: r.fakePhoto('o1'),
        lat: 31.23,
        lng: 121.47,
      );
      await svc.markSorted(orderId: orderId(1), shelfCode: 'A-1');

      final code =
          CodeIssuer(secret: secret, tag: Hotp.pickupTag).issue(1001);
      final pickup =
          await svc.recordPickup(orderId: orderId(1), residentCode: code);
      expect(pickup.ok, isTrue);

      // All events live locally first — the "airplane mode" guarantee.
      expect(r.ledger.length, 4);
      expect(r.ledger.pendingSync().length, 4);

      // Connectivity returns: server replays and accepts, then checkpoints.
      final verify = EventLedger.verifyChain(
          r.ledger.events, r.signer, r.ledger.config.genesisHash);
      expect(verify.valid, isTrue);
      r.ledger.markSynced(r.ledger.events.map((e) => e.eventId));
      expect(r.ledger.pendingSync(), isEmpty);

      await svc.ingestCheckpoint(
        upToEventId: r.ledger.events.last.eventId,
        upToHash: r.ledger.headHash,
        serverSignature: 'srv-sig',
      );
      expect(r.ledger.lastCheckpoint, isNotNull);
    });

    test('wrong pickup code is refused and no ledger event is written',
        () async {
      final r = rig();
      final svc = service(r);
      final result =
          await svc.recordPickup(orderId: orderId(1), residentCode: '000000');
      expect(result.ok, isFalse);
      expect(result.check, CodeCheck.wrong);
      expect(r.ledger.length, 0);
    });

    test('pickup without code requires an explicit reason', () async {
      final r = rig();
      final svc = service(r);
      expect(
        () => svc.recordPickup(orderId: orderId(1)),
        throwsArgumentError,
      );
      final result = await svc.recordPickup(
        orderId: orderId(1),
        noCodeReason: 'resident lost phone, witnessed by staff 42',
      );
      expect(result.ok, isTrue);
      expect(result.event!.payload['codeVerified'], isFalse);
    });

    test('reusing one photo across two scans is blocked', () async {
      final r = rig();
      final svc = service(r);
      final photo = r.fakePhoto('shared');
      await svc.scanOrderReceived(
        orderId: orderId(1),
        batchId: 'b1',
        skuSummary: 'milk',
        photo: photo,
        lat: 31.23,
        lng: 121.47,
      );
      expect(
        () => svc.scanOrderReceived(
          orderId: orderId(2),
          batchId: 'b1',
          skuSummary: 'beef',
          photo: photo,
          lat: 31.23,
          lng: 121.47,
        ),
        throwsStateError,
      );
    });

    test('aftersale succeeds only with a valid resident code and binds amount',
        () async {
      final r = rig();
      final secret = demoSecret(3);
      final auth = AftersaleAuthorization(
        orderId: orderId(1),
        claimId: 'claim-1',
        counter: 7001,
        amountMinor: 2000,
        expiresAt: r.wallClock.now().add(const Duration(hours: 1)),
        residentRefundTargetMasked: 'wechat ****1234',
      );
      final svc = service(
        r,
        aftersaleSecret: secret,
        aftersaleManifest: [auth],
      );
      final code = AftersaleCodeIssuer(secret: secret).issueCode(
        orderId: orderId(1),
        counter: 7001,
        amountMinor: 2000,
      );

      // Leader tries a bigger refund first — blocked.
      final inflated = await svc.submitAftersale(
        claimId: 'claim-1',
        orderId: orderId(1),
        reason: 'spoiled',
        photos: [r.fakePhoto('as1')],
        residentAuthCode: code,
        refundTarget: 'wechat ****1234',
        amountMinor: 20000,
      );
      expect(inflated.check, AftersaleCodeCheck.amountMismatch);
      expect(inflated.event, isNull);

      final ok = await svc.submitAftersale(
        claimId: 'claim-1',
        orderId: orderId(1),
        reason: 'spoiled',
        photos: [r.fakePhoto('as2')],
        residentAuthCode: code,
        refundTarget: 'wechat ****1234',
        amountMinor: 2000,
      );
      expect(ok.ok, isTrue);
      // Cleartext code must never land in the ledger.
      expect(ok.event!.payload.containsValue(code), isFalse);
      expect(ok.event!.payload['residentAuthCodeHash'], isA<String>());

      // Replay: same claim cannot be consumed twice.
      final replay = await svc.submitAftersale(
        claimId: 'claim-1',
        orderId: orderId(1),
        reason: 'spoiled',
        photos: [r.fakePhoto('as3')],
        residentAuthCode: code,
        refundTarget: 'wechat ****1234',
        amountMinor: 2000,
      );
      expect(replay.check, AftersaleCodeCheck.alreadyUsed);
    });
  });
}
