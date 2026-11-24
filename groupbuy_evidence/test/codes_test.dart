import 'package:groupbuy_evidence/groupbuy_evidence.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  group('HOTP pickup codes', () {
    final secret = demoSecret(1);

    test('server issuer and offline verifier derive the same code', () {
      final issuer = CodeIssuer(secret: secret, tag: Hotp.pickupTag);
      final code = issuer.issue(1001);
      expect(code.length, 6);
      expect(int.tryParse(code), isNotNull);

      final verifier = OfflineCodeVerifier(
        secret: secret,
        assignments: assignments(2),
      );
      expect(verifier.verify(orderId(1), code), CodeCheck.ok);
    });

    test('a pickup code is rejected for a different order', () {
      final verifier = OfflineCodeVerifier(
        secret: secret,
        assignments: assignments(3),
      );
      final codeFor1 =
          CodeIssuer(secret: secret, tag: Hotp.pickupTag).issue(1001);
      expect(verifier.verify(orderId(2), codeFor1), CodeCheck.wrong);
    });

    test('domain tags are not interchangeable', () {
      final pickup = CodeIssuer(secret: secret, tag: Hotp.pickupTag).issue(1001);
      final aftersale =
          CodeIssuer(secret: secret, tag: Hotp.aftersaleTag).issue(1001);
      expect(pickup == aftersale, isFalse);
    });

    test('locks after five wrong guesses and demands online re-issue', () {
      final verifier = OfflineCodeVerifier(
        secret: secret,
        assignments: assignments(1),
      );
      for (var i = 0; i < 4; i++) {
        expect(verifier.verify(orderId(1), '00000$i'), CodeCheck.wrong);
      }
      expect(verifier.verify(orderId(1), '999999'), CodeCheck.locked);
      // Even the correct code is refused while locked.
      final real =
          CodeIssuer(secret: secret, tag: Hotp.pickupTag).issue(1001);
      expect(verifier.verify(orderId(1), real), CodeCheck.locked);

      verifier.unlock(orderId(1));
      expect(verifier.verify(orderId(1), real), CodeCheck.ok);
    });

    test('unknown order returns unknownOrder instead of consuming budget', () {
      final verifier = OfflineCodeVerifier(
        secret: secret,
        assignments: assignments(1),
      );
      expect(verifier.verify('order-ghost', '123456'), CodeCheck.unknownOrder);
    });

    test('works with no network at all (pure local derivation)', () {
      final verifier = OfflineCodeVerifier(
        secret: secret,
        assignments: assignments(1),
      );
      final code =
          CodeIssuer(secret: secret, tag: Hotp.pickupTag).issue(1001);
      expect(verifier.verify(orderId(1), code), CodeCheck.ok);
    });
  });

  group('After-sales authorization', () {
    final secret = demoSecret(9);
    final t0 = DateTime.utc(2026, 11, 24, 9);
    final auth = AftersaleAuthorization(
      orderId: orderId(1),
      claimId: 'claim-1',
      counter: 5001,
      amountMinor: 2000,
      expiresAt: t0.add(const Duration(hours: 2)),
      residentRefundTargetMasked: 'wechat ****1234',
    );

    AftersaleVerifier build() => AftersaleVerifier(
          secret: secret,
          manifest: [auth],
          now: () => t0,
        );

    test('resident-issued code verifies offline and is single-use', () {
      final code = AftersaleCodeIssuer(secret: secret).issueCode(
        orderId: orderId(1),
        counter: 5001,
        amountMinor: 2000,
      );
      final v = build();
      expect(
        v.verify(
            claimId: 'claim-1', code: code, claimedAmountMinor: 2000),
        AftersaleCodeCheck.ok,
      );
      v.markUsed('claim-1');
      expect(
        v.verify(
            claimId: 'claim-1', code: code, claimedAmountMinor: 2000),
        AftersaleCodeCheck.alreadyUsed,
      );
    });

    test('leader cannot inflate the refund amount', () {
      final code = AftersaleCodeIssuer(secret: secret).issueCode(
        orderId: orderId(1),
        counter: 5001,
        amountMinor: 2000,
      );
      final v = build();
      expect(
        v.verify(
            claimId: 'claim-1', code: code, claimedAmountMinor: 20000),
        AftersaleCodeCheck.amountMismatch,
      );
    });

    test('expired codes fail without contacting the server', () {
      final code = AftersaleCodeIssuer(secret: secret).issueCode(
        orderId: orderId(1),
        counter: 5001,
        amountMinor: 2000,
      );
      final v = AftersaleVerifier(
        secret: secret,
        manifest: [auth],
        now: () => t0.add(const Duration(hours: 3)),
      );
      expect(
        v.verify(
            claimId: 'claim-1', code: code, claimedAmountMinor: 2000),
        AftersaleCodeCheck.expired,
      );
    });

    test('fabricated claim id is unknown', () {
      final v = build();
      expect(
        v.verify(
            claimId: 'claim-fake', code: '123456', claimedAmountMinor: 2000),
        AftersaleCodeCheck.unknownClaim,
      );
    });

    test('wrong code locks the claim after five attempts', () {
      final v = build();
      for (var i = 0; i < 4; i++) {
        expect(
          v.verify(
              claimId: 'claim-1', code: '11111$i', claimedAmountMinor: 2000),
          AftersaleCodeCheck.wrong,
        );
      }
      expect(
        v.verify(
            claimId: 'claim-1', code: '222222', claimedAmountMinor: 2000),
        AftersaleCodeCheck.locked,
      );
    });
  });
}
