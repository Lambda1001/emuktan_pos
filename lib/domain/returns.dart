// Refund arithmetic. Pure, so the money rules can be tested on their own.

/// How much of a sale each line actually cost the customer once the
/// sale-level discount is shared out in proportion to line value. The shares
/// always add up to exactly [discountCents] (largest-remainder rounding), so
/// refunding every line gives back exactly what was paid.
List<int> netLineTotals({
  required List<int> lineTotals,
  required int discountCents,
}) {
  final subtotal = lineTotals.fold<int>(0, (s, x) => s + x);
  if (discountCents <= 0 || subtotal <= 0) return List.of(lineTotals);

  final shares = <int>[];
  final remainders = <(int index, int rem)>[];
  for (var i = 0; i < lineTotals.length; i++) {
    final exact = discountCents * lineTotals[i];
    shares.add(exact ~/ subtotal);
    remainders.add((i, exact % subtotal));
  }
  var left = discountCents - shares.fold<int>(0, (s, x) => s + x);
  remainders.sort(
    (a, b) => b.$2 != a.$2 ? b.$2.compareTo(a.$2) : a.$1.compareTo(b.$1),
  );
  for (var k = 0; left > 0 && k < remainders.length; k++, left--) {
    shares[remainders[k].$1]++;
  }
  return [
    for (var i = 0; i < lineTotals.length; i++) lineTotals[i] - shares[i],
  ];
}

/// Refund for returning [qty] of a line that sold [soldQty] for [netCents],
/// when [alreadyReturned] units and [alreadyRefunded] cents have gone back.
/// The return that finishes the line takes the remainder, so rounding can never
/// leave cents behind or hand out too much.
int refundFor({
  required int netCents,
  required int soldQty,
  required int qty,
  required int alreadyReturned,
  required int alreadyRefunded,
}) {
  if (qty <= 0 || alreadyReturned + qty > soldQty) {
    throw ArgumentError('Return quantity is out of range.');
  }
  if (alreadyReturned + qty == soldQty) return netCents - alreadyRefunded;
  return (netCents * qty / soldQty).round();
}
