import 'package:groupbuy_evidence/groupbuy_evidence.dart';
import 'package:test/test.dart';

import 'helpers.dart';

/// Builds a minimal but fully-valid chain for one order through a chosen
/// sequence of workflow steps, so each test can assemble exactly the evidence
/// pattern it wants to adjudicate.
class ChainBuilder {
  final TestRig rig;
  final String batchId = 'b1';

  ChainBuilder(this.rig);

  Future<EvidenceEvent> batch(List<String> orderIds) =>
      rig.ledger.append(EventDraft(EventType.batchReceived, {
        'batchId': batchId,
        'warehouseId': 'wh-1',
        'orderIds': orderIds,
        'photoHashes': [rig.fakePhoto('batch').sha256Hex],
        'geo': {'lat': 31.23, 'lng': 121.47},
      }));

  Future<EvidenceEvent> received(String orderId) =>
      rig.ledger.append(EventDraft(EventType.orderReceived, {
        'orderId': orderId,
        'batchId': batchId,
        'skuSummary': 'goods',
        'photoHash': rig.fakePhoto(orderId).sha256Hex,
        'geo': {'lat': 31.23, 'lng': 121.47},
      }));

  Future<EvidenceEvent> sorted(String orderId) =>
      rig.ledger.append(EventDraft(EventType.orderSorted, {
        'orderId': orderId,
        'shelfCode': 'A-1',
      }));

  Future<EvidenceEvent> pickup(
    String orderId, {
    bool codeVerified = true,
    String? noCodeReason,
  }) =>
      rig.ledger.append(EventDraft(EventType.orderPickedUp, {
        'orderId': orderId,
        'residentCodeHash': codeVerified ? 'hash-of-code' : null,
        'codeVerified': codeVerified,
        'noCodeReason': codeVerified ? null : (noCodeReason ?? 'no reason'),
      }));

  Future<EvidenceEvent> exception(String orderId, String stage,
          {String reason = 'shortage'}) =>
      rig.ledger.append(EventDraft(EventType.exceptionReported, {
        'orderId': orderId,
        'reason': reason,
        'photoHash': rig.fakePhoto('exc-$orderId').sha256Hex,
        'stage': stage,
      }));

  Future<EvidenceEvent> aftersale(
    String orderId, {
    String claimId = 'claim-1',
    String refundTarget = 'wechat ****1234',
    bool includeAuthHash = true,
  }) =>
      rig.ledger.append(EventDraft(EventType.aftersaleRequested, {
        'orderId': orderId,
        'claimId': claimId,
        'reason': 'damaged',
        'photoHashes': [rig.fakePhoto('as-$orderId').sha256Hex],
        'residentAuthCodeHash': includeAuthHash ? 'auth-hash' : null,
        'refundTarget': refundTarget,
        'amount': 2000,
      }));
}

WarehouseManifest manifest(List<String> orderIds) => WarehouseManifest(
      batchId: 'b1',
      shippedAt: DateTime.utc(2026, 11, 24, 7),
      orderParcelCounts: {for (final o in orderIds) o: 1},
      loadingPhotoHashes: {for (final o in orderIds) o: ['wh-photo']},
    );

void main() {
  late TestRig rig;
  late ChainBuilder b;
  late AdjudicationEngine engine;

  setUp(() {
    rig = TestRig.create();
    b = ChainBuilder(rig);
    engine = AdjudicationEngine();
  });

  AdjudicationResult runFor(
    String orderId, {
    required WarehouseManifest manifest,
    bool residentCollected = false,
    Set<String> serverClaims = const {'claim-1'},
    Set<String> residentTargets = const {'wechat ****1234'},
    Map<String, AftersaleAuthorization> authByClaim = const {},
    bool chainValid = true,
  }) {
    return engine
        .adjudicateBatch(
          manifest: manifest,
          chain: rig.ledger.events,
          residentCollected: {orderId: residentCollected},
          aftersaleAuthByClaim: authByClaim,
          serverSideValidClaimIds: serverClaims,
          residentRefundTargets: residentTargets,
          chainCryptographicallyValid: chainValid,
        )
        .firstWhere((r) => r.orderId == orderId);
  }

  test('clean: received, verified pickup, resident confirms', () async {
    await b.received(orderId(1));
    await b.pickup(orderId(1));
    final r = runFor(orderId(1),
        manifest: manifest([orderId(1)]), residentCollected: true);
    expect(r.verdict, Verdict.clean);
  });

  test('GHOST SIGNOFF: signed receipt for an order the warehouse never shipped',
      () async {
    // Scenario from the brief: leader marks an unshipped order received,
    // then claims shortage and resells the stock privately.
    await b.batch([orderId(1)]);
    await b.received(orderId(2)); // order-0002 exists nowhere in the manifest
    final r = runFor(orderId(2), manifest: manifest([orderId(1)]));
    expect(r.verdict, Verdict.ghostSignoff);
    expect(r.evidence.single, contains('warehouse manifest'));
  });

  test('FRAUDULENT AFTERSALE: fabricated claim, no server authorization',
      () async {
    await b.received(orderId(1));
    await b.aftersale(orderId(1), claimId: 'made-up-claim');
    final r = runFor(
      orderId(1),
      manifest: manifest([orderId(1)]),
      serverClaims: const {}, // platform has no resident request at all
    );
    expect(r.verdict, Verdict.fraudulentAftersale);
    expect(r.evidence.join(), contains('no server-side resident'));
  });

  test('FRAUDULENT AFTERSALE: refund routed to a non-resident account',
      () async {
    final auth = AftersaleAuthorization(
      orderId: orderId(1),
      claimId: 'claim-1',
      counter: 1,
      amountMinor: 2000,
      expiresAt: DateTime.utc(2026, 12, 31),
      residentRefundTargetMasked: 'wechat ****1234',
    );
    await b.received(orderId(1));
    await b.aftersale(orderId(1), refundTarget: 'alipay ****9999 (leader)');
    final r = runFor(
      orderId(1),
      manifest: manifest([orderId(1)]),
      authByClaim: {'claim-1': auth},
      residentTargets: const {'wechat ****1234'},
    );
    expect(r.verdict, Verdict.fraudulentAftersale);
    expect(r.evidence.join(), contains('not the resident payment account'));
  });

  test('legitimate aftersale: resident-authorized, refund to resident account',
      () async {
    final auth = AftersaleAuthorization(
      orderId: orderId(1),
      claimId: 'claim-1',
      counter: 1,
      amountMinor: 2000,
      expiresAt: DateTime.utc(2026, 12, 31),
      residentRefundTargetMasked: 'wechat ****1234',
    );
    await b.received(orderId(1));
    await b.aftersale(orderId(1));
    final r = runFor(
      orderId(1),
      manifest: manifest([orderId(1)]),
      authByClaim: {'claim-1': auth},
    );
    expect(r.verdict, Verdict.legitimateAftersale);
  });

  test('TRANSPORT LOSS: warehouse shipped, handoff exception, never received',
      () async {
    await b.exception(orderId(1), 'handoff', reason: 'carton missing at dock');
    final r = runFor(orderId(1), manifest: manifest([orderId(1)]));
    expect(r.verdict, Verdict.transportLoss);
  });

  test('LEADER LOSS: received and sorted, parcel never closed out', () async {
    await b.received(orderId(1));
    await b.sorted(orderId(1));
    final r = runFor(orderId(1), manifest: manifest([orderId(1)]));
    expect(r.verdict, Verdict.leaderResponsibleLoss);
    expect(r.evidence.join(), contains('possible diversion'));
  });

  test('pickup dispute: code verified on device but resident denies pickup',
      () async {
    await b.received(orderId(1));
    await b.pickup(orderId(1), codeVerified: true);
    final r = runFor(orderId(1),
        manifest: manifest([orderId(1)]), residentCollected: false);
    expect(r.verdict, Verdict.pickupDispute);
  });

  test('no-code pickup denied by resident is leader-responsible', () async {
    await b.received(orderId(1));
    await b.pickup(orderId(1),
        codeVerified: false, noCodeReason: 'resident forgot code');
    final r = runFor(orderId(1),
        manifest: manifest([orderId(1)]), residentCollected: false);
    expect(r.verdict, Verdict.leaderResponsibleLoss);
  });

  test('chain tampered contaminates every order on the device', () async {
    await b.received(orderId(1));
    final r = runFor(orderId(1),
        manifest: manifest([orderId(1)]), chainValid: false);
    expect(r.verdict, Verdict.chainTampered);
  });

  test('risk summary escalates: watch -> suspend -> investigate', () async {
    // One ghost signoff alone crosses the suspend threshold.
    await b.received(orderId(9));
    final results = engine.adjudicateBatch(
      manifest: manifest([orderId(1)]),
      chain: rig.ledger.events,
      residentCollected: const {},
      aftersaleAuthByClaim: const {},
      serverSideValidClaimIds: const {},
      residentRefundTargets: const {},
      chainCryptographicallyValid: true,
    );
    final summary = engine.summarizeRisk('leader-01', results);
    expect(summary.level, RiskLevel.suspend);
    expect(summary.signals.join(), contains('ghostSignoff'));
  });

  test('risk summary stays normal for a clean batch', () async {
    await b.received(orderId(1));
    await b.pickup(orderId(1));
    final results = engine.adjudicateBatch(
      manifest: manifest([orderId(1)]),
      chain: rig.ledger.events,
      residentCollected: {orderId(1): true},
      aftersaleAuthByClaim: const {},
      serverSideValidClaimIds: const {},
      residentRefundTargets: const {},
      chainCryptographicallyValid: true,
    );
    final summary = engine.summarizeRisk('leader-01', results);
    expect(summary.level, RiskLevel.normal);
    expect(summary.score, 0);
  });
}
