/// Immutable membership in 32 scene layers. Objects start on layer zero.
final class LayerMask {
  final int bits;
  const LayerMask._(this.bits);
  static const none = LayerMask._(0);
  static const all = LayerMask._(0xffffffff);
  factory LayerMask.only(int layer) => LayerMask._(_bit(layer));
  static int _bit(int layer) =>
      1 << RangeError.checkValueInInterval(layer, 0, 31, 'layer');
  LayerMask including(int layer) => LayerMask._(bits | _bit(layer));
  LayerMask excluding(int layer) => LayerMask._(bits & ~_bit(layer));
  LayerMask intersection(LayerMask other) => LayerMask._(bits & other.bits);
  bool intersects(LayerMask other) => bits & other.bits != 0;
  @override
  bool operator ==(Object other) => other is LayerMask && other.bits == bits;
  @override
  int get hashCode => bits.hashCode;
}
