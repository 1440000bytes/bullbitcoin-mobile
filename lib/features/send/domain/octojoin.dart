import 'dart:math';
import 'dart:typed_data';

import 'package:bb_mobile/core/errors/bull_exception.dart';
import 'package:bb_mobile/core/wallet/domain/entities/wallet.dart';
import 'package:bb_mobile/core/wallet/domain/entities/wallet_utxo.dart';
import 'package:crypto/crypto.dart';

enum OctojoinIssue {
  amountBelowDust,
  amountTooSmallToSplit,
  notEnoughAddresses,
  numInputsTooLow,
  numOutputsTooLow,
  outputsMismatch,
  notEnoughSwappedCoins,
  noSenderCoin,
  insufficientFunds,
  sendMaxUnsupported,
  bitcoinOnly,
  unequalInputs,
  unnecessaryInput,
  changeIdentifiable,
  changeBesideEqualOutputs,
}

class OctojoinException extends BullException {
  final OctojoinIssue issue;
  final int? needed;
  final int? found;

  OctojoinException(this.issue, {this.needed, this.found})
    : super('Octojoin: ${issue.name}');
}

/// Uniform integers from SHA-256 of a seed and a counter, the same stream as
/// the reference implementation, so a seed gives the same plan everywhere.
class OctojoinRandomness {
  OctojoinRandomness(List<int> seed) : _seed = Uint8List.fromList(seed);

  factory OctojoinRandomness.secure() {
    final random = Random.secure();
    return OctojoinRandomness(List.generate(32, (_) => random.nextInt(256)));
  }

  final Uint8List _seed;
  BigInt _counter = BigInt.zero;
  static final BigInt _twoTo64 = BigInt.one << 64;
  static final BigInt _byte = BigInt.from(0xff);

  int below(int n) {
    final range = BigInt.from(n);
    final limit = _twoTo64 - _twoTo64 % range;
    while (true) {
      _counter += BigInt.one;
      final message = Uint8List(_seed.length + 8)..setAll(0, _seed);
      var counter = _counter;
      for (var i = message.length - 1; i >= _seed.length; i--) {
        message[i] = (counter & _byte).toInt();
        counter >>= 8;
      }
      final digest = sha256.convert(message).bytes;
      var value = BigInt.zero;
      for (var i = 0; i < 8; i++) {
        value = (value << 8) | BigInt.from(digest[i]);
      }
      if (value < limit) return (value % range).toInt();
    }
  }
}

class OctojoinPlan<T> {
  final List<T> inputs;
  final List<({String address, int amountSat})> targets;
  final int totalInputSat;
  final int changeSat;
  final int feeSat;
  final bool uihClean;
  final bool changeHidden;
  final List<OctojoinIssue> warnings;

  OctojoinPlan({
    required this.inputs,
    required this.targets,
    required this.totalInputSat,
    required this.changeSat,
    required this.feeSat,
    required this.uihClean,
    required this.changeHidden,
    required this.warnings,
  });
}

typedef _Selection<T> = ({List<T> inputs, int total, int change, int fee});

abstract final class Octojoin {
  static const int dustThresholdSat = 546;
  static const int minInputs = 3;
  static const int minOutputs = 2;
  static const int roundUnit = 1000;
  static const int equalInputsPercent = 10;
  static const int _splitAttempts = 10000;
  static const int _maxSelections = 200000;
  static const String labelTag = 'octojoin';

  static bool isOctojoinLabel(String? label) =>
      label != null && label.toLowerCase().contains(labelTag);

  static bool isSwappedUtxo(WalletUtxo utxo) => [
    ...utxo.labels,
    ...utxo.txLabels,
    ...utxo.addressLabels,
  ].any((l) => isOctojoinLabel(l.label));

  static int inputVbytesForScriptType(ScriptType scriptType) {
    return switch (scriptType) {
      ScriptType.bip84 => 68,
      ScriptType.bip49 => 91,
      ScriptType.bip44 => 148,
    };
  }

  static int estimateFee({
    required int numInputs,
    required int numOutputs,
    required double satPerVbyte,
    int inputVbytes = 68,
    int outputVbytes = 34,
  }) {
    const txOverheadVbytes = 11;
    return ((txOverheadVbytes +
                numInputs * inputVbytes +
                numOutputs * outputVbytes) *
            satPerVbyte)
        .ceil();
  }

  static bool isRound(int value) => value % roundUnit == 0;

  static bool inputsNearEqual(List<int> values) =>
      values.reduce(max) * 100 <=
      values.reduce(min) * (100 + equalInputsPercent);

  /// The smallest and largest value of a payment output: above dust, and
  /// between half and one and a half times an even share of the payment.
  static (int, int) splitRange(
    int paymentSat,
    int numOutputs, {
    int dust = dustThresholdSat,
  }) {
    final share = 2 * numOutputs;
    final lo = paymentSat ~/ share + (paymentSat % share == 0 ? 0 : 1);
    return (max(dust + 1, lo), 3 * paymentSat ~/ share);
  }

  static int smallestSplittable(
    int numOutputs, {
    int dust = dustThresholdSat,
    bool equalOutputs = false,
  }) {
    if (equalOutputs) return numOutputs * (dust + 1);
    return numOutputs * (dust + 1) + numOutputs * (numOutputs - 1) ~/ 2;
  }

  static List<int> equalSplit(int paymentSat, int numOutputs) {
    final share = paymentSat ~/ numOutputs;
    final rest = paymentSat % numOutputs;
    return List.generate(numOutputs, (i) => i < rest ? share + 1 : share);
  }

  /// Cuts the payment at random points into values in the split range that
  /// are all different, not round and not equal to the change. With [below],
  /// at least one of them is smaller than it. Null if no attempt works.
  static List<int>? splitAmount(
    int paymentSat,
    int numOutputs,
    int dust,
    OctojoinRandomness rng, {
    int change = 0,
    int? below,
  }) {
    final (lo, hi) = splitRange(paymentSat, numOutputs, dust: dust);
    final spread = paymentSat - numOutputs * lo;
    if (spread < 0) return null;
    for (var attempt = 0; attempt < _splitAttempts; attempt++) {
      final cuts = List.generate(numOutputs - 1, (_) => rng.below(spread + 1))
        ..sort();
      final lower = [0, ...cuts];
      final upper = [...cuts, spread];
      final values = List.generate(numOutputs, (i) => lo + upper[i] - lower[i]);
      if (values.reduce(max) <= hi &&
          values.toSet().length == numOutputs &&
          !values.contains(change) &&
          !values.any(isRound) &&
          (below == null || values.reduce(min) < below)) {
        return values;
      }
    }
    return null;
  }

  /// Fee and change for spending inputs on the payment outputs. Change that
  /// would be round gives 1 sat to the fee, and change at or below dust goes
  /// to the fee entirely. Null when the inputs cannot pay the fee.
  static ({int change, int fee})? feeAndChange({
    required int totalInputSat,
    required int paymentSat,
    required int numInputs,
    required int numPaymentOutputs,
    required int Function(int numInputs, int numOutputs) feeForShape,
    int dust = dustThresholdSat,
  }) {
    var fee = feeForShape(numInputs, numPaymentOutputs + 1);
    var change = totalInputSat - paymentSat - fee;
    if (change > dust && isRound(change)) {
      change -= 1;
      fee += 1;
    }
    if (change <= dust) {
      fee = totalInputSat - paymentSat;
      if (fee < feeForShape(numInputs, numPaymentOutputs)) return null;
      change = 0;
    }
    return (change: change, fee: fee);
  }

  static List<List<T>> _chooseCombinations<T>(List<T> items, int k) {
    if (k == 0) return [[]];
    if (k > items.length) return [];
    final result = <List<T>>[];
    for (var i = 0; i <= items.length - k; i++) {
      for (final rest in _chooseCombinations(items.sublist(i + 1), k - 1)) {
        result.add([items[i], ...rest]);
      }
    }
    return result;
  }

  static BigInt _countCombinations(int n, int k) {
    var count = BigInt.one;
    for (var i = 1; i <= k; i++) {
      count = count * BigInt.from(n - k + i) ~/ BigInt.from(i);
    }
    return count;
  }

  static List<T> _sortedByValue<T>(List<T> items, int Function(T) valueOf) {
    final indexed = [for (var i = 0; i < items.length; i++) (i, items[i])]
      ..sort((a, b) {
        final byValue = valueOf(a.$2).compareTo(valueOf(b.$2));
        return byValue != 0 ? byValue : a.$1.compareTo(b.$1);
      });
    return [for (final (_, item) in indexed) item];
  }

  /// Picks numInputs - 1 swapped coins plus exactly one sender coin. The change
  /// should be smaller than the smallest input, otherwise an input could be
  /// dropped while the payment is still funded, the unnecessary input
  /// heuristic. No change is best. Otherwise it should lie in the split range,
  /// so that it looks like one of the payment outputs, which change next to
  /// equal outputs never does. With equal inputs, inputs of near-equal value
  /// come before all of that, and every swapped coin is a candidate. Picks at
  /// random among the selections that do best.
  static _Selection<T>? _selectInputs<T>({
    required List<T> swapped,
    required List<T> other,
    required int Function(T) valueOf,
    required int numInputs,
    required int paymentSat,
    required int numPaymentOutputs,
    required int Function(int numInputs, int numOutputs) feeForShape,
    required int dust,
    required (int, int) split,
    required OctojoinRandomness rng,
    required bool equalOutputs,
    required bool equalInputs,
  }) {
    final requiredSwapped = numInputs - 1;
    final senders = _sortedByValue(other, valueOf);
    var pool = _sortedByValue(swapped, valueOf);
    var extra = equalInputs ? pool.length - requiredSwapped : 6;
    while (extra > 0 &&
        _countCombinations(
                  min(pool.length, requiredSwapped + extra),
                  requiredSwapped,
                ) *
                BigInt.from(senders.length) >
            BigInt.from(_maxSelections)) {
      extra -= 1;
    }
    pool = pool.take(requiredSwapped + extra).toList();

    final (lo, hi) = split;
    int? bestRank;
    var best = <_Selection<T>>[];
    for (final combo in _chooseCombinations(pool, requiredSwapped)) {
      for (final sender in senders) {
        final inputs = [...combo, sender];
        final values = inputs.map(valueOf).toList();
        final total = values.fold(0, (sum, v) => sum + v);
        final funded = feeAndChange(
          totalInputSat: total,
          paymentSat: paymentSat,
          numInputs: numInputs,
          numPaymentOutputs: numPaymentOutputs,
          feeForShape: feeForShape,
          dust: dust,
        );
        if (funded == null) continue;
        final change = funded.change;
        final unequal = equalInputs && !inputsNearEqual(values);
        final unnecessary = change >= values.reduce(min);
        final standsOut =
            change > 0 && (equalOutputs || change < lo || change > hi);
        final rank =
            (unequal ? 8 : 0) +
            (unnecessary ? 4 : 0) +
            (standsOut ? 2 : 0) +
            (change > 0 ? 1 : 0);
        final selection = (
          inputs: inputs,
          total: total,
          change: change,
          fee: funded.fee,
        );
        if (bestRank == null || rank < bestRank) {
          bestRank = rank;
          best = [selection];
        } else if (rank == bestRank) {
          best.add(selection);
        }
      }
    }
    return best.isEmpty ? null : best[rng.below(best.length)];
  }

  /// Plans an octojoin payment for any kind of coin, given its value and
  /// whether it is a swapped coin.
  static OctojoinPlan<T> planCoins<T>({
    required List<T> coins,
    required int Function(T coin) valueOf,
    required bool Function(T coin) isSwapped,
    required int paymentSat,
    required List<String> addresses,
    required int numInputs,
    required int Function(int numInputs, int numOutputs) feeForShape,
    required OctojoinRandomness rng,
    int dust = dustThresholdSat,
    bool equalOutputs = false,
    bool equalInputs = false,
  }) {
    if (addresses.length < minOutputs) {
      throw OctojoinException(
        OctojoinIssue.notEnoughAddresses,
        needed: minOutputs,
        found: addresses.length,
      );
    }
    final numOutputs = addresses.length;
    if (paymentSat <= dust) {
      throw OctojoinException(OctojoinIssue.amountBelowDust);
    }
    if (paymentSat <
        smallestSplittable(
          numOutputs,
          dust: dust,
          equalOutputs: equalOutputs,
        )) {
      throw OctojoinException(OctojoinIssue.amountTooSmallToSplit);
    }

    final swapped = coins.where(isSwapped).toList();
    final other = coins.where((c) => !isSwapped(c)).toList();
    final requiredSwapped = numInputs - 1;
    if (swapped.length < requiredSwapped) {
      throw OctojoinException(
        OctojoinIssue.notEnoughSwappedCoins,
        needed: requiredSwapped,
        found: swapped.length,
      );
    }
    if (other.isEmpty) {
      throw OctojoinException(OctojoinIssue.noSenderCoin);
    }

    final split = splitRange(paymentSat, numOutputs, dust: dust);
    final selection = _selectInputs(
      swapped: swapped,
      other: other,
      valueOf: valueOf,
      numInputs: numInputs,
      paymentSat: paymentSat,
      numPaymentOutputs: numOutputs,
      feeForShape: feeForShape,
      dust: dust,
      split: split,
      rng: rng,
      equalOutputs: equalOutputs,
      equalInputs: equalInputs,
    );
    if (selection == null) {
      throw OctojoinException(OctojoinIssue.insufficientFunds);
    }

    final change = selection.change;
    final inputValues = selection.inputs.map(valueOf).toList();
    final minInput = inputValues.reduce(min);
    final (lo, hi) = split;
    final List<int> values;
    final bool changeHidden;
    if (equalOutputs) {
      values = equalSplit(paymentSat, numOutputs);
      changeHidden = change == 0;
    } else {
      // with change below every input, a payment output below every input as
      // well keeps the change from being the only output the heuristic finds
      final below = change > 0 && change < minInput && minInput > lo
          ? minInput
          : null;
      var parts = splitAmount(
        paymentSat,
        numOutputs,
        dust,
        rng,
        change: change,
        below: below,
      );
      if (parts == null && below != null) {
        parts = splitAmount(paymentSat, numOutputs, dust, rng, change: change);
      }
      if (parts == null) {
        throw OctojoinException(OctojoinIssue.amountTooSmallToSplit);
      }
      values = parts;
      changeHidden =
          change == 0 ||
          (lo <= change &&
              change <= hi &&
              (change >= minInput || values.reduce(min) < minInput));
    }

    final uihClean = change < minInput;
    return OctojoinPlan(
      inputs: selection.inputs,
      targets: [
        for (var i = 0; i < numOutputs; i++)
          (address: addresses[i], amountSat: values[i]),
      ],
      totalInputSat: selection.total,
      changeSat: change,
      feeSat: selection.fee,
      uihClean: uihClean,
      changeHidden: changeHidden,
      warnings: [
        if (equalInputs && !inputsNearEqual(inputValues))
          OctojoinIssue.unequalInputs,
        if (!uihClean) OctojoinIssue.unnecessaryInput,
        if (!changeHidden)
          equalOutputs
              ? OctojoinIssue.changeBesideEqualOutputs
              : OctojoinIssue.changeIdentifiable,
      ],
    );
  }

  static OctojoinPlan<WalletUtxo> plan({
    required List<WalletUtxo> utxos,
    required int paymentSat,
    required List<String> addresses,
    required int numInputs,
    required int Function(int numInputs, int numOutputs) feeForShape,
    required OctojoinRandomness rng,
    bool equalOutputs = false,
    bool equalInputs = false,
  }) {
    return planCoins(
      coins: utxos,
      valueOf: (u) => u.amountSat.toInt(),
      isSwapped: isSwappedUtxo,
      paymentSat: paymentSat,
      addresses: addresses,
      numInputs: numInputs,
      feeForShape: feeForShape,
      rng: rng,
      equalOutputs: equalOutputs,
      equalInputs: equalInputs,
    );
  }
}
