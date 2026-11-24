/// Offline-first tamper-evident evidence primitives for the community
/// group-buying leader app:
///
///  * [EventLedger] — hash-chained, device-signed append-only event ledger;
///  * [TrustedClock] — server-anchored timestamps that survive offline work
///    and resist manual clock changes;
///  * [PhotoRegistry] / [PhotoEvidence] — camera-capture-to-ledger binding;
///  * [OfflineCodeVerifier] — offline HOTP pickup codes for elderly residents;
///  * [AftersaleVerifier] — resident-authorized, single-use after-sales codes;
///  * [AdjudicationEngine] — explainable server-side arbitration that
///    distinguishes leader fraud from genuine loss.
library;

export 'src/adjudication.dart';
export 'src/aftersale.dart';
export 'src/canonical_json.dart';
export 'src/clock.dart';
export 'src/event.dart';
export 'src/ledger.dart';
export 'src/photo.dart';
export 'src/pickup_code.dart';
export 'src/signer.dart';
export 'src/storage.dart';
export 'src/workflow.dart';
