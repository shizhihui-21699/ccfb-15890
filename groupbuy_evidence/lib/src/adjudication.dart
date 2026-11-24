import 'aftersale.dart';
import 'event.dart';

/// What the warehouse claims it loaded into the leader's batch. This record
/// originates outside the leader's device and is the independent anchor
/// against which the device chain is reconciled.
class WarehouseManifest {
  final String batchId;
  final DateTime shippedAt;

  /// Orders (and parcel counts) the warehouse says left the dock.
  final Map<String, int> orderParcelCounts;

  /// Photo hashes the warehouse capture system recorded at loading.
  final Map<String, List<String>> loadingPhotoHashes;

  const WarehouseManifest({
    required this.batchId,
    required this.shippedAt,
    required this.orderParcelCounts,
    required this.loadingPhotoHashes,
  });

  bool containsOrder(String orderId) => orderParcelCounts.containsKey(orderId);
}

/// Final adjudication for one order.
enum Verdict {
  /// Everything is consistent; no dispute.
  clean,

  /// Warehouse has no outbound record but the device signed for receipt —
  /// ghost signoff, the parcel never existed in this batch.
  ghostSignoff,

  /// Device chain shows received but no legitimate pickup/aftersale closes
  /// the order, and the resident never collected: leader-side loss or
  /// diversion. Distinguishing detail lives in [AdjudicationResult.evidence].
  leaderResponsibleLoss,

  /// Warehouse manifest says shipped, but the device never recorded receipt
  /// and reported an exception at handoff: loss in transport / at dock.
  transportLoss,

  /// After-sales request without a valid resident authorization, or with a
  /// refund target other than the resident's own payment account.
  fraudulentAftersale,

  /// A valid resident-authorized claim — a real refund, not fraud.
  legitimateAftersale,

  /// Resident says never collected but the device has a code-verified pickup;
  /// either a shared-code social issue or device compromise, needs manual
  /// review rather than an automatic sanction.
  pickupDispute,

  /// Device's own evidence chain failed cryptographic verification.
  chainTampered,

  /// Evidence is incomplete or contradictory in a way no rule can settle.
  inconclusive,
}

/// Risk levels aggregate order verdicts into an action recommendation.
enum RiskLevel { normal, watch, suspend, investigate }

class AdjudicationResult {
  final String orderId;
  final Verdict verdict;
  final List<String> evidence;
  final int? severityWeight;

  const AdjudicationResult(this.orderId, this.verdict, this.evidence,
      {this.severityWeight});

  @override
  String toString() =>
      '$orderId -> ${verdict.name}${evidence.isEmpty ? '' : ' (${evidence.join('; ')})'}';
}

class LeaderRiskSummary {
  final String leaderId;
  final int ordersReviewed;
  final Map<Verdict, int> counts;
  final int score;
  final RiskLevel level;
  final List<String> signals;

  const LeaderRiskSummary({
    required this.leaderId,
    required this.ordersReviewed,
    required this.counts,
    required this.score,
    required this.level,
    required this.signals,
  });
}

/// Replays a device's verified chain against independent platform records.
///
/// Deliberately rule-based and fully explainable: every verdict carries the
/// exact evidence lines behind it, because sanctions against a leader (and
/// payout decisions) must be contestable, not a black-box score.
class AdjudicationEngine {
  /// Weights feeding the leader risk score.
  static const Map<Verdict, int> _weights = {
    Verdict.ghostSignoff: 25,
    Verdict.fraudulentAftersale: 30,
    Verdict.chainTampered: 40,
    Verdict.leaderResponsibleLoss: 10,
    Verdict.pickupDispute: 5,
    Verdict.inconclusive: 2,
  };

  /// Adjudicates every order referenced by either the manifest or the chain.
  List<AdjudicationResult> adjudicateBatch({
    required WarehouseManifest manifest,
    required List<EvidenceEvent> chain,
    required Map<String, bool> residentCollected,
    required Map<String, AftersaleAuthorization> aftersaleAuthByClaim,
    required Set<String> serverSideValidClaimIds,
    required Set<String> residentRefundTargets,
    required bool chainCryptographicallyValid,
  }) {
    final orderIds = <String>{
      ...manifest.orderParcelCounts.keys,
      ..._orderIdsInChain(chain),
    };
    final results = <AdjudicationResult>[];

    for (final orderId in orderIds) {
      results.add(_adjudicateOrder(
        orderId: orderId,
        manifest: manifest,
        chain: chain,
        residentCollected: residentCollected[orderId] ?? false,
        aftersaleAuthByClaim: aftersaleAuthByClaim,
        serverSideValidClaimIds: serverSideValidClaimIds,
        residentRefundTargets: residentRefundTargets,
        chainValid: chainCryptographicallyValid,
      ));
    }
    return results..sort((a, b) => a.orderId.compareTo(b.orderId));
  }

  AdjudicationResult _adjudicateOrder({
    required String orderId,
    required WarehouseManifest manifest,
    required List<EvidenceEvent> chain,
    required bool residentCollected,
    required Map<String, AftersaleAuthorization> aftersaleAuthByClaim,
    required Set<String> serverSideValidClaimIds,
    required Set<String> residentRefundTargets,
    required bool chainValid,
  }) {
    final ev = <String>[];
    final orderEvents = chain
        .where((e) =>
            e.payload['orderId'] == orderId ||
            (e.payload['orderIds'] as List?)?.contains(orderId) == true)
        .toList();
    final received = orderEvents.any((e) =>
        e.type == EventType.orderReceived ||
        (e.type == EventType.batchReceived &&
            (e.payload['orderIds'] as List).contains(orderId)));
    final sorted =
        orderEvents.any((e) => e.type == EventType.orderSorted);
    final pickup = orderEvents
        .where((e) => e.type == EventType.orderPickedUp)
        .cast<EvidenceEvent?>()
        .firstWhere((_) => true, orElse: () => null);
    final exception = orderEvents
        .where((e) => e.type == EventType.exceptionReported)
        .cast<EvidenceEvent?>()
        .firstWhere((_) => true, orElse: () => null);
    final aftersale = orderEvents
        .where((e) => e.type == EventType.aftersaleRequested)
        .cast<EvidenceEvent?>()
        .firstWhere((_) => true, orElse: () => null);
    final inManifest = manifest.containsOrder(orderId);

    // Rule 0: broken chain contaminates everything signed on this device.
    if (!chainValid) {
      ev.add('device evidence chain failed hash/signature verification');
      return AdjudicationResult(orderId, Verdict.chainTampered, ev,
          severityWeight: _weights[Verdict.chainTampered]);
    }

    // Rule 1: ghost signoff — signed receipt for something never shipped.
    if (received && !inManifest) {
      ev.add('orderReceived/batchReceived on device but absent from warehouse '
          'manifest ${manifest.batchId}');
      return AdjudicationResult(orderId, Verdict.ghostSignoff, ev,
          severityWeight: _weights[Verdict.ghostSignoff]);
    }

    // Rule 2: after-sales validity.
    if (aftersale != null) {
      final claimId = aftersale.payload['claimId'] as String?;
      final target = aftersale.payload['refundTarget'] as String?;
      final auth = claimId == null ? null : aftersaleAuthByClaim[claimId];
      final serverKnowsClaim =
          claimId != null && serverSideValidClaimIds.contains(claimId);
      final targetIsResident =
          target != null && residentRefundTargets.contains(target);

      if (!serverKnowsClaim ||
          auth == null ||
          !targetIsResident ||
          aftersale.payload['residentAuthCodeHash'] == null) {
        ev.addAll([
          if (!serverKnowsClaim) 'claim $claimId has no server-side resident '
              'authorization record',
          if (auth == null) 'no resident authorization synced for claim',
          if (!targetIsResident)
            'refundTarget "$target" is not the resident payment account',
          if (aftersale.payload['residentAuthCodeHash'] == null)
            'missing resident authorization code hash',
        ]);
        return AdjudicationResult(orderId, Verdict.fraudulentAftersale, ev,
            severityWeight: _weights[Verdict.fraudulentAftersale]);
      }
      ev.add('resident-authorized claim $claimId, refund to resident account');
      return AdjudicationResult(orderId, Verdict.legitimateAftersale, ev);
    }

    // Rule 3: transport loss — shipped by warehouse, never received on device,
    // with an exception logged at the handoff stage.
    if (inManifest && !received) {
      if (exception != null && exception.payload['stage'] == 'handoff') {
        ev.add('warehouse shipped; device logged handoff exception '
            '("${exception.payload['reason']}") before any receipt event');
        return AdjudicationResult(orderId, Verdict.transportLoss, ev);
      }
      ev.add('warehouse shipped but device never recorded receipt and no '
          'handoff exception exists');
      return AdjudicationResult(orderId, Verdict.inconclusive, ev,
          severityWeight: _weights[Verdict.inconclusive]);
    }

    // Rule 4: pickup reconciliation.
    if (pickup != null) {
      final codeVerified = pickup.payload['codeVerified'] == true;
      if (residentCollected) {
        return AdjudicationResult(orderId, Verdict.clean,
            [if (codeVerified) 'pickup closed with verified resident code']);
      }
      if (codeVerified) {
        ev.add('device shows code-verified pickup but resident denies '
            'collection — investigate shared/compromised code');
        return AdjudicationResult(orderId, Verdict.pickupDispute, ev,
            severityWeight: _weights[Verdict.pickupDispute]);
      }
      ev.add('pickup closed without a resident code '
          '(reason: ${pickup.payload['noCodeReason']}) and resident denies '
          'collection');
      return AdjudicationResult(orderId, Verdict.leaderResponsibleLoss, ev,
          severityWeight: _weights[Verdict.leaderResponsibleLoss]);
    }

    // Rule 5: received, not picked up, no valid closing event.
    if (received && !residentCollected) {
      if (exception != null) {
        ev.add('device reports exception "${exception.payload['reason']}" '
            'after orderReceived; no resident pickup; leader accountable for '
            'custody since receipt');
      } else {
        ev.add('received (sorted=$sorted) but no pickup, exception '
            'or after-sale closes the order — possible diversion');
      }
      return AdjudicationResult(orderId, Verdict.leaderResponsibleLoss, ev,
          severityWeight: _weights[Verdict.leaderResponsibleLoss]);
    }

    return AdjudicationResult(orderId, Verdict.inconclusive,
        ['no decisive combination of events found'],
        severityWeight: _weights[Verdict.inconclusive]);
  }

  /// Aggregates order verdicts into a per-leader risk summary and thresholded
  /// action recommendation.
  LeaderRiskSummary summarizeRisk(
    String leaderId,
    List<AdjudicationResult> results, {
    List<String> extraSignals = const [],
  }) {
    final counts = <Verdict, int>{};
    var score = 0;
    for (final r in results) {
      counts[r.verdict] = (counts[r.verdict] ?? 0) + 1;
      score += r.severityWeight ?? 0;
    }
    final signals = <String>[
      ...extraSignals,
      for (final entry in counts.entries)
        if ((_weights[entry.key] ?? 0) > 0)
          '${entry.value}x ${entry.key.name}',
    ];
    final RiskLevel level;
    if (score >= 60 ||
        (counts[Verdict.chainTampered] ?? 0) > 0 ||
        (counts[Verdict.fraudulentAftersale] ?? 0) >= 2) {
      level = RiskLevel.investigate;
    } else if (score >= 30 || (counts[Verdict.ghostSignoff] ?? 0) > 0) {
      level = RiskLevel.suspend;
    } else if (score >= 10) {
      level = RiskLevel.watch;
    } else {
      level = RiskLevel.normal;
    }
    return LeaderRiskSummary(
      leaderId: leaderId,
      ordersReviewed: results.length,
      counts: counts,
      score: score,
      level: level,
      signals: signals,
    );
  }

  Set<String> _orderIdsInChain(List<EvidenceEvent> chain) {
    final ids = <String>{};
    for (final e in chain) {
      final oid = e.payload['orderId'];
      if (oid is String) ids.add(oid);
      final list = e.payload['orderIds'];
      if (list is List) ids.addAll(list.cast<String>());
    }
    return ids;
  }
}
