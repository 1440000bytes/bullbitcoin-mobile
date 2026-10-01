import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bb_mobile/core/wallet/domain/entities/wallet_utxo.dart';
import 'package:bb_mobile/features/labels/label.dart';
import 'package:bb_mobile/features/send/domain/octojoin.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../coins/wallet_utxo_fixture.dart';

WalletUtxo _utxo({required int sats, required bool isSwapped, int vout = 0}) {
  return walletUtxoFixture(
    sats: sats,
    vout: vout,
    labels: isSwapped ? ['octojoin'] : [],
  );
}

List<WalletUtxo> _coins(List<int> swapped, List<int> own) => [
  for (var i = 0; i < swapped.length; i++)
    _utxo(sats: swapped[i], isSwapped: true, vout: i),
  for (var i = 0; i < own.length; i++)
    _utxo(sats: own[i], isSwapped: false, vout: 100 + i),
];

Matcher _throwsIssue(OctojoinIssue issue) =>
    throwsA(isA<OctojoinException>().having((e) => e.issue, 'issue', issue));

int Function(int, int) _feeAtRate(double satPerVbyte) =>
    (numInputs, numOutputs) => Octojoin.estimateFee(
      numInputs: numInputs,
      numOutputs: numOutputs,
      satPerVbyte: satPerVbyte,
    );

OctojoinRandomness _rng(String seed) => OctojoinRandomness(utf8.encode(seed));

OctojoinPlan<WalletUtxo> _plan(
  List<WalletUtxo> utxos,
  int paymentSat, {
  String seed = 'octojoin',
  double rate = 1,
  bool equalOutputs = false,
  bool equalInputs = false,
  List<String> addresses = const ['bc1qa', 'bc1qb'],
}) => Octojoin.plan(
  utxos: utxos,
  paymentSat: paymentSat,
  addresses: addresses,
  numInputs: 3,
  feeForShape: _feeAtRate(rate),
  rng: _rng(seed),
  equalOutputs: equalOutputs,
  equalInputs: equalInputs,
);

List<int> _values(OctojoinPlan plan) => [
  for (final t in plan.targets) t.amountSat,
];

int _smallestInput(OctojoinPlan<WalletUtxo> plan) =>
    plan.inputs.map((u) => u.amountSat.toInt()).reduce((a, b) => a < b ? a : b);

void main() {
  group('Octojoin protocol logic', () {
    test(
      'isOctojoinLabel matches case-insensitively and within longer notes',
      () {
        expect(Octojoin.isOctojoinLabel('Octojoin 1'), true);
        expect(Octojoin.isOctojoinLabel('octojoin 2'), true);
        expect(Octojoin.isOctojoinLabel('my OCTOJOIN swap'), true);
        expect(Octojoin.isOctojoinLabel('Normal TX'), false);
        expect(Octojoin.isOctojoinLabel(''), false);
        expect(Octojoin.isOctojoinLabel(null), false);
      },
    );

    test('isSwappedUtxo counts utxo, transaction and address labels', () {
      expect(Octojoin.isSwappedUtxo(_utxo(sats: 1000, isSwapped: true)), true);
      expect(
        Octojoin.isSwappedUtxo(_utxo(sats: 1000, isSwapped: false)),
        false,
      );

      final txLabeled = WalletUtxo.bitcoin(
        walletId: 'w',
        txId: 'a' * 64,
        vout: 0,
        scriptPubkey: Uint8List(0),
        amountSat: BigInt.from(1000),
        address: 'bc1qtest',
        txLabels: [
          Label.tx(id: 0, transactionId: 'a' * 64, label: 'Octojoin receive'),
        ],
      );
      expect(Octojoin.isSwappedUtxo(txLabeled), true);

      final addressLabeled = WalletUtxo.bitcoin(
        walletId: 'w',
        txId: 'b' * 64,
        vout: 0,
        scriptPubkey: Uint8List(0),
        amountSat: BigInt.from(1000),
        address: 'bc1qtest2',
        addressLabels: [
          Label.addr(id: 0, address: 'bc1qtest2', label: 'octojoin'),
        ],
      );
      expect(Octojoin.isSwappedUtxo(addressLabeled), true);
    });

    test('randomness repeats for a seed and stays in range', () {
      List<int> draw(String seed) {
        final rng = _rng(seed);
        return [for (var i = 0; i < 200; i++) rng.below(1000)];
      }

      expect(draw('seed'), draw('seed'));
      expect(draw('seed'), isNot(draw('other')));
      expect(draw('seed').every((d) => d >= 0 && d < 1000), true);
    });

    test('the split range is half to one and a half shares above dust', () {
      expect(Octojoin.splitRange(300000, 2), (75000, 225000));
      expect(Octojoin.splitRange(300000, 3), (50000, 150000));
      expect(Octojoin.splitRange(1200, 2), (547, 900));
      expect(Octojoin.smallestSplittable(2), 547 + 548);
      expect(Octojoin.smallestSplittable(2, equalOutputs: true), 2 * 547);
    });

    test('a split adds up and has different values that are not round', () {
      for (final k in [2, 3, 4, 5]) {
        for (final paymentSat in [5000, 80000, 300000, 123456789]) {
          final rng = _rng('$paymentSat/$k');
          final (lo, hi) = Octojoin.splitRange(paymentSat, k);
          for (var i = 0; i < 20; i++) {
            final parts = Octojoin.splitAmount(paymentSat, k, 546, rng)!;
            expect(parts.length, k);
            expect(parts.fold(0, (s, v) => s + v), paymentSat);
            expect(parts.every((v) => v >= lo && v <= hi), true);
            expect(parts.toSet().length, k);
            expect(parts.any(Octojoin.isRound), false);
          }
        }
      }
    });

    test('equal amounts split the payment evenly', () {
      expect(Octojoin.equalSplit(300000, 2), [150000, 150000]);
      expect(Octojoin.equalSplit(300001, 2), [150001, 150000]);
      expect(Octojoin.equalSplit(100000, 3), [33334, 33333, 33333]);
    });

    test('round change gives 1 sat to the fee, and dust change goes to it', () {
      final fee = _feeAtRate(1)(3, 3);
      expect(
        Octojoin.feeAndChange(
          totalInputSat: 390000 + fee,
          paymentSat: 300000,
          numInputs: 3,
          numPaymentOutputs: 2,
          feeForShape: _feeAtRate(1),
        ),
        (change: 89999, fee: fee + 1),
      );
      expect(
        Octojoin.feeAndChange(
          totalInputSat: 300400,
          paymentSat: 300000,
          numInputs: 3,
          numPaymentOutputs: 2,
          feeForShape: _feeAtRate(1),
        ),
        (change: 0, fee: 400),
      );
    });
  });

  group('Octojoin planning', () {
    test('spends numInputs - 1 swapped coins and exactly one sender coin', () {
      final plan = _plan(
        _coins([200000, 300000, 400000], [500000, 900000]),
        600000,
      );
      expect(plan.inputs.length, 3);
      expect(plan.inputs.where(Octojoin.isSwappedUtxo).length, 2);
      expect(plan.totalInputSat, 600000 + plan.changeSat + plan.feeSat);
    });

    test('prefers a selection without change, then change that blends in', () {
      for (var seed = 0; seed < 20; seed++) {
        final changeless = _plan(
          _coins([120000, 130000], [140000, 50450]),
          300000,
          seed: 's$seed',
        );
        expect(changeless.changeSat, 0);
        expect(changeless.warnings, isEmpty);
        final blending = _plan(
          _coins([120000, 130000], [100000, 140000]),
          300000,
          seed: 's$seed',
        );
        expect(blending.inputs.last.amountSat.toInt(), 140000);
        expect(blending.warnings, isEmpty);
      }
    });

    test('puts a payment output below every input when the change is', () {
      final ranks = <int>{};
      for (var seed = 0; seed < 100; seed++) {
        final plan = _plan(
          _coins([120000, 130000], [140000]),
          300000,
          seed: 's$seed',
        );
        final smallestInput = _smallestInput(plan);
        expect(plan.changeSat, lessThan(smallestInput));
        expect(
          _values(plan).reduce((a, b) => a < b ? a : b),
          lessThan(smallestInput),
        );
        ranks.add(
          ([..._values(plan), plan.changeSat]..sort()).indexOf(plan.changeSat),
        );
      }
      expect(ranks, {
        0,
        1,
      }, reason: 'the change is not always in the same place');
    });

    test('prefers inputs of near-equal value with equal inputs', () {
      expect(Octojoin.inputsNearEqual([100000, 110000, 105000]), true);
      expect(Octojoin.inputsNearEqual([100000, 110001]), false);
      final utxos = _coins(
        [60000, 61000, 62000, 63000, 64000, 65000, 66000, 130000, 135000],
        [140000, 90000],
      );
      for (var seed = 0; seed < 20; seed++) {
        final plan = _plan(utxos, 300000, seed: 's$seed', equalInputs: true);
        expect(plan.inputs.map((u) => u.amountSat.toInt()).toList()..sort(), [
          130000,
          135000,
          140000,
        ]);
        expect(plan.warnings, isEmpty);
      }
    });

    test('warns about what an observer could notice', () {
      expect(
        _plan(_coins([500000, 500000], [500000]), 300000).warnings,
        contains(OctojoinIssue.unnecessaryInput),
      );
      expect(_plan(_coins([100000, 100000], [110000]), 300000).warnings, [
        OctojoinIssue.changeIdentifiable,
      ]);
      final equal = _plan(
        _coins([120000, 130000], [140000]),
        300000,
        equalOutputs: true,
      );
      expect(_values(equal), [150000, 150000]);
      expect(equal.warnings, [OctojoinIssue.changeBesideEqualOutputs]);
      expect(
        _plan(
          _coins([120000, 130000], [140000]),
          300000,
          equalInputs: true,
        ).warnings,
        [OctojoinIssue.unequalInputs],
      );
    });

    test('rejects amounts it cannot split and shapes it cannot build', () {
      final utxos = _coins([300000, 300000], [300000]);
      expect(
        () => _plan(utxos, 520),
        _throwsIssue(OctojoinIssue.amountBelowDust),
      );
      expect(
        () => _plan(utxos, 1094),
        _throwsIssue(OctojoinIssue.amountTooSmallToSplit),
      );
      expect(_values(_plan(utxos, 1095))..sort(), [547, 548]);
      expect(
        () => _plan(_coins([150000], [50000]), 100000),
        _throwsIssue(OctojoinIssue.notEnoughSwappedCoins),
      );
      expect(
        () => _plan(_coins([150000, 150000], []), 100000),
        _throwsIssue(OctojoinIssue.noSenderCoin),
      );
      expect(
        () => _plan(_coins([100000, 100000], [50000]), 305000, rate: 10),
        _throwsIssue(OctojoinIssue.insufficientFunds),
      );
      expect(
        () => _plan(utxos, 300000, addresses: ['bc1qa']),
        _throwsIssue(OctojoinIssue.notEnoughAddresses),
      );
    });

    // The same vectors run against the planners of the reference
    // implementation and the Electrum plugin, so all of them make the same
    // choices from the same random stream.
    test('matches the shared test vectors', () {
      final vectors =
          jsonDecode(
                File(
                  'test/features/send/domain/octojoin_vectors.json',
                ).readAsStringSync(),
              )
              as List;
      const errors = {
        'amountBelowDust': OctojoinIssue.amountBelowDust,
        'outputBelowDust': OctojoinIssue.amountTooSmallToSplit,
        'notEnoughSwappedCoins': OctojoinIssue.notEnoughSwappedCoins,
        'noSenderCoin': OctojoinIssue.noSenderCoin,
        'insufficientFunds': OctojoinIssue.insufficientFunds,
      };
      for (final v in vectors.cast<Map<String, dynamic>>()) {
        final coins = [
          for (final (i, c) in (v['coins'] as List).indexed)
            (
              index: i,
              value: c['valueSats'] as int,
              swapped: c['isSwapped'] as bool,
            ),
        ];
        final seed = v['seed'] as String;
        final rate = (v['feeRate'] as num).toDouble();
        final expected = v['expected'] as Map<String, dynamic>;
        OctojoinPlan<({int index, int value, bool swapped})> run() =>
            Octojoin.planCoins(
              coins: coins,
              valueOf: (c) => c.value,
              isSwapped: (c) => c.swapped,
              paymentSat: v['paymentSats'] as int,
              addresses: [
                for (var i = 0; i < (v['outputs'] as List).length; i++)
                  'recipient$i',
              ],
              numInputs: v['numInputs'] as int,
              feeForShape: (n, m) => ((11 + n * 68 + m * 31) * rate).ceil(),
              rng: OctojoinRandomness([
                for (var i = 0; i < seed.length; i += 2)
                  int.parse(seed.substring(i, i + 2), radix: 16),
              ]),
              dust: 294,
              equalOutputs: v['equalOutputs'] as bool,
              equalInputs: v['equalInputs'] as bool,
            );
        if (expected.containsKey('error')) {
          expect(
            run,
            _throwsIssue(errors[expected['error']]!),
            reason: v['name'] as String,
          );
          continue;
        }
        final plan = run();
        expect(
          {
            'inputs': [for (final c in plan.inputs) c.index],
            'payments': _values(plan),
            'changeSats': plan.changeSat,
            'feeSats': plan.feeSat,
            'uihClean': plan.uihClean,
            'changeHidden': plan.changeHidden,
            'warnings': [for (final w in plan.warnings) w.name],
          },
          expected,
          reason: v['name'] as String,
        );
      }
    });
  });
}
