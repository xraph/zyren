/// The native 0..1 depth convention, including projection and depth testing.
/// Reversed depth requires `RenderFeature.reversedDepth` on the backend.
/// Use a floating-point depth attachment to retain precision at long distances.
enum DepthStrategy {
  standard,
  reversed;

  double get nearDepth => this == reversed ? 1 : 0;
  double get farDepth => this == reversed ? 0 : 1;
}
