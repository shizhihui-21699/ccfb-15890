import 'dart:io';

import 'package:groupbuy_evidence/groupbuy_evidence.dart';

/// End-to-end demonstration of the evidence system.
///
/// Run:  dart run bin/demo.dart
///
/// It walks through:
///   1. a normal offline batch (handoff -> scan -> sort -> coded pickup);
///   2. the "ghost signoff then private resale" fraud and how adjudication
///      reconstructs it;
///   3. a fabricated after-sales refund and why it cannot pay out;
///   4. a throughput check for a 300-parcel handoff in airplane mode.
Future<void> main() async {
  stdout.writeln('=' * 72);
  stdout.writeln(' 社区团购团长端 · 签收凭证与售后防伪 演示');
  stdout.writeln('=' * 72);

  await _normalOfflineBatch();
  await _ghostSignoffFraud();
  await _fabricatedAftersale();
  await _throughputBenchmark();
}

TestRig _rig() => TestRig();

class TestRig {
  final FakeClock wallClock = FakeClock(DateTime.utc(2026, 11, 24, 7, 30));
  int _mono = 0;
  late final HmacEvidenceSigner signer = HmacEvidenceSigner(
    secret: List<int>.generate(32, (i) => i + 1),
    keyId: 'key-leader-01',
  );
  final MemoryLedgerStorage storage = MemoryLedgerStorage();
  final PhotoRegistry photos = PhotoRegistry();
  late final TrustedClock clock = TrustedClock(
    wallClock: wallClock,
    monotonicNowMs: () => _mono,
    initialAnchor: TimeAnchor(
      serverTime: wallClock.now(),
      monotonicAtIssueMs: 0,
      signature: 'server-anchor-sig',
    ),
  );
  late final EventLedger ledger = EventLedger(
    config: const LedgerConfig(
      deviceId: 'dev-leader-01',
      leaderId: 'leader-01',
      genesisHash: 'genesis-dev-leader-01',
    ),
    signer: signer,
    clock: clock,
    storage: storage,
    photoRegistry: photos,
  );

  void elapse(Duration d) {
    wallClock.advance(d);
    _mono += d.inMilliseconds;
  }

  PhotoEvidence photo(String seed) => PhotoRegistry.fromBytes(
        List<int>.generate(64, (i) => (i + seed.codeUnitAt(0)) % 256),
        mimeType: 'image/jpeg',
        capturedAt: wallClock.now(),
        lat: 31.2304,
        lng: 121.4737,
      );
}

Future<void> _normalOfflineBatch() async {
  stdout.writeln('\n【场景 1】正常批次:仓库门口无网络,全流程离线完成后补传');
  final rig = _rig();
  final pickupSecret = List<int>.generate(32, (i) => i * 3 + 2);
  final svc = LeaderWorkflowService(
    ledger: rig.ledger,
    pickupVerifier: OfflineCodeVerifier(
      secret: pickupSecret,
      assignments: [const CounterAssignment('o-1001', 1001)],
    ),
    aftersaleVerifier: AftersaleVerifier(
      secret: List<int>.generate(32, (i) => i + 9),
      manifest: const [],
      now: rig.wallClock.now,
    ),
    photoRegistry: rig.photos,
  );

  await svc.receiveBatch(BatchHandoff(
    batchId: 'b-20261124',
    warehouseId: 'wh-pudong-03',
    orderIds: const ['o-1001'],
    batchPhotos: [rig.photo('batch')],
    lat: 31.2304,
    lng: 121.4737,
  ));
  rig.elapse(const Duration(seconds: 8));
  await svc.scanOrderReceived(
    orderId: 'o-1001',
    batchId: 'b-20261124',
    skuSummary: '鲜牛奶 x2',
    photo: rig.photo('o-1001'),
    lat: 31.2304,
    lng: 121.4737,
  );
  await svc.markSorted(orderId: 'o-1001', shelfCode: 'A-07');

  // 居民手机收到的短信取货码由服务器签发,团长手机离线可验。
  final code =
      CodeIssuer(secret: pickupSecret, tag: Hotp.pickupTag).issue(1001);
  stdout.writeln('  居民短信取货码: $code(老人只需报 6 位数字)');
  final pickup =
      await svc.recordPickup(orderId: 'o-1001', residentCode: code);
  stdout.writeln('  离线核验取货码: ${pickup.ok ? '通过 ✓' : '失败 ✗'}');

  final chainOk = EventLedger.verifyChain(
          rig.ledger.events, rig.signer, rig.ledger.config.genesisHash)
      .valid;
  stdout.writeln('  本地台账事件数: ${rig.ledger.length},'
      '哈希链与设备签名校验: ${chainOk ? '通过 ✓' : '失败 ✗'}');
  stdout.writeln('  待补传事件: ${rig.ledger.pendingSync().length} 条'
      '(联网后批量上传,服务器逐条重放)');
}

Future<void> _ghostSignoffFraud() async {
  stdout.writeln('\n【场景 2】幽灵签收 + 私下转卖:团长签收了仓库根本没发的货');
  final rig = _rig();
  final svc = LeaderWorkflowService(
    ledger: rig.ledger,
    pickupVerifier: OfflineCodeVerifier(
      secret: List<int>.generate(32, (i) => i),
      assignments: const [],
    ),
    aftersaleVerifier: AftersaleVerifier(
      secret: List<int>.generate(32, (i) => i + 1),
      manifest: const [],
      now: rig.wallClock.now,
    ),
    photoRegistry: rig.photos,
  );

  // 仓库这一批只发了 o-2001。
  const shipped = ['o-2001'];
  await svc.receiveBatch(BatchHandoff(
    batchId: 'b-2',
    warehouseId: 'wh-pudong-03',
    orderIds: shipped,
    batchPhotos: [rig.photo('b2')],
    lat: 31.23,
    lng: 121.47,
  ));
  // 团长把没送到的 o-2002 也扫成"已收货",随后打算报缺货转卖。
  await svc.scanOrderReceived(
    orderId: 'o-2002',
    batchId: 'b-2',
    skuSummary: '进口牛排 x5',
    photo: rig.photo('ghost'),
    lat: 31.23,
    lng: 121.47,
  );

  final engine = AdjudicationEngine();
  final results = engine.adjudicateBatch(
    manifest: WarehouseManifest(
      batchId: 'b-2',
      shippedAt: DateTime.utc(2026, 11, 24, 7),
      orderParcelCounts: {for (final o in shipped) o: 1},
      loadingPhotoHashes: const {},
    ),
    chain: rig.ledger.events,
    residentCollected: const {},
    aftersaleAuthByClaim: const {},
    serverSideValidClaimIds: const {},
    residentRefundTargets: const {},
    chainCryptographicallyValid: true,
  );
  for (final r in results) {
    stdout.writeln('  裁决 ${r.orderId}: ${r.verdict.name}');
    for (final e in r.evidence) {
      stdout.writeln('    └─ $e');
    }
  }
  final summary = engine.summarizeRisk('leader-01', results);
  stdout.writeln('  团长风险分: ${summary.score} → 处置级别 ${summary.level.name}'
      '(达到 suspend,自动暂停签收权限并转稽核)');
}

Future<void> _fabricatedAftersale() async {
  stdout.writeln('\n【场景 3】伪造居民售后:团长想冒充居民申请退款');
  final rig = _rig();
  final aftersaleSecret = List<int>.generate(32, (i) => i * 5 + 1);
  final auth = AftersaleAuthorization(
    orderId: 'o-3001',
    claimId: 'c-3001',
    counter: 7001,
    amountMinor: 2000,
    expiresAt: rig.wallClock.now().add(const Duration(hours: 2)),
    residentRefundTargetMasked: '微信支付 ****1234',
  );
  final svc = LeaderWorkflowService(
    ledger: rig.ledger,
    pickupVerifier: OfflineCodeVerifier(
      secret: List<int>.generate(32, (i) => i),
      assignments: const [],
    ),
    aftersaleVerifier: AftersaleVerifier(
      secret: aftersaleSecret,
      manifest: [auth],
      now: rig.wallClock.now,
    ),
    photoRegistry: rig.photos,
  );
  await rig.ledger.append(EventDraft(EventType.orderReceived, {
    'orderId': 'o-3001',
    'batchId': 'b-3',
    'skuSummary': '草莓 x1',
    'photoHash': rig.photo('o3001').sha256Hex,
    'geo': {'lat': 31.23, 'lng': 121.47},
  }));

  // 团长猜了一个授权码 —— 离线核验直接拒绝,且台账不产生任何事件。
  final guess = await svc.submitAftersale(
    claimId: 'c-3001',
    orderId: 'o-3001',
    reason: '坏果',
    photos: [rig.photo('fake-as')],
    residentAuthCode: '123456',
    refundTarget: '微信支付 ****1234',
    amountMinor: 2000,
  );
  stdout.writeln('  猜测授权码提交售后: ${guess.check.name}'
      '(被拒,台账事件数仍为 ${rig.ledger.length})');

  // 即使拿到真码,把退款打到团长自己的账户也会在裁决阶段被拦。
  final realCode = AftersaleCodeIssuer(secret: aftersaleSecret).issueCode(
    orderId: 'o-3001',
    counter: 7001,
    amountMinor: 2000,
  );
  final ok = await svc.submitAftersale(
    claimId: 'c-3001',
    orderId: 'o-3001',
    reason: '坏果',
    photos: [rig.photo('real-as')],
    residentAuthCode: realCode,
    refundTarget: '支付宝 ****9999(团长个人账户)',
    amountMinor: 2000,
  );
  stdout.writeln('  真授权码 + 非居民退款账户: 本地记录=${ok.ok ? '已记录' : '未记录'},'
      '提交平台裁决:');
  final engine = AdjudicationEngine();
  final verdict = engine
      .adjudicateBatch(
        manifest: WarehouseManifest(
          batchId: 'b-3',
          shippedAt: rig.wallClock.now(),
          orderParcelCounts: const {'o-3001': 1},
          loadingPhotoHashes: const {},
        ),
        chain: rig.ledger.events,
        residentCollected: const {},
        aftersaleAuthByClaim: {'c-3001': auth},
        serverSideValidClaimIds: const {'c-3001'},
        residentRefundTargets: const {'微信支付 ****1234'},
        chainCryptographicallyValid: true,
      )
      .firstWhere((r) => r.orderId == 'o-3001');
  stdout.writeln('  裁决: ${verdict.verdict.name}');
  for (final e in verdict.evidence) {
    stdout.writeln('    └─ $e');
  }
}

Future<void> _throughputBenchmark() async {
  stdout.writeln('\n【场景 4】性能实测:飞行模式下连续处理 300 件商品');
  final rig = _rig();
  const n = 300;
  final stopwatch = Stopwatch()..start();
  for (var i = 1; i <= n; i++) {
    final orderId = 'o-perf-${i.toString().padLeft(4, '0')}';
    await rig.ledger.append(EventDraft(EventType.orderReceived, {
      'orderId': orderId,
      'batchId': 'b-perf',
      'skuSummary': '混合生鲜',
      'photoHash': rig.photo(orderId).sha256Hex,
      'geo': {'lat': 31.23, 'lng': 121.47},
    }));
  }
  stopwatch.stop();
  final perItemUs = stopwatch.elapsedMicroseconds / n;
  stdout.writeln('  $n 件签名+哈希链写入总耗时: '
      '${stopwatch.elapsedMilliseconds} ms');
  stdout.writeln('  单件平均耗时: ${perItemUs.toStringAsFixed(1)} µs'
      '(不含相机成像,纯密码学与台账开销)');

  final verifyWatch = Stopwatch()..start();
  final result = EventLedger.verifyChain(
      rig.ledger.events, rig.signer, rig.ledger.config.genesisHash);
  verifyWatch.stop();
  stdout.writeln('  服务器重放校验 $n 条: '
      '${verifyWatch.elapsedMilliseconds} ms, 结果=${result.valid ? '通过 ✓' : '失败 ✗'}');
}
