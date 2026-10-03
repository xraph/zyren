part of '../../training.dart';

/// An adapter from the pinned T4/T5 artifact, supplied by its verified reader.
final class TrainingEvaluation {
  final String modelHash, observationHash, actionHash, receiptHash;
  final List<Map<String, Object?>> cases;
  final bool accepted;
  TrainingEvaluation({
    required this.modelHash,
    required this.observationHash,
    required this.actionHash,
    required this.receiptHash,
    required this.accepted,
    required List<Map<String, Object?>> cases,
  }) : cases = List.unmodifiable(
         cases.map(
           (v) => Map<String, Object?>.unmodifiable(jsonDecode(jsonEncode(v))),
         ),
       ) {
    if (![modelHash, observationHash, actionHash, receiptHash].every(_digest) ||
        cases.isEmpty ||
        cases.length > 256 ||
        utf8.encode(jsonEncode(cases)).length > 1048576) {
      throw ArgumentError('Evaluation receipt is missing pins or cases.');
    }
  }
  bool matches({
    required String model,
    required String observation,
    required String action,
  }) =>
      modelHash == model &&
      observationHash == observation &&
      actionHash == action;
}
