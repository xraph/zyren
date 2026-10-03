part of '../../training.dart';

/// An adapter from the pinned T4/T5 artifact, supplied by its verified reader.
final class TrainingEvaluation {
  final String modelHash, observationHash, actionHash, receiptHash;
  final List<Map<String, Object?>> cases;
  final bool accepted;
  final int? fixedHz;
  TrainingEvaluation({
    required this.modelHash,
    required this.observationHash,
    required this.actionHash,
    required this.receiptHash,
    required this.accepted,
    this.fixedHz,
    required List<Map<String, Object?>> cases,
  }) : cases = List.unmodifiable(
         cases.map(
           (v) => Map<String, Object?>.unmodifiable(jsonDecode(jsonEncode(v))),
         ),
       ) {
    if (fixedHz != null && (fixedHz! < 10 || fixedHz! > 240) ||
        ![modelHash, observationHash, actionHash, receiptHash].every(_digest) ||
        cases.isEmpty ||
        cases.length > 256 ||
        utf8.encode(jsonEncode(cases)).length > 1048576) {
      throw ArgumentError('Evaluation receipt is missing pins or cases.');
    }
  }
  factory TrainingEvaluation.fromModel(ModelEvaluation value) =>
      TrainingEvaluation(
        modelHash: value.modelHash,
        observationHash: value.observationHash,
        actionHash: value.actionHash,
        receiptHash: value.receiptHash,
        accepted: value.accepted,
        fixedHz: value.fixedHz,
        cases: value.cases,
      );
  bool matches({
    required String model,
    required String observation,
    required String action,
  }) =>
      modelHash == model &&
      observationHash == observation &&
      actionHash == action;
}

/// Thin file adapter around the shared byte-only AI artifact reader.
final class EvaluationReceiptReader {
  Future<TrainingEvaluation> readFamily(
    String path, {
    required String receiptHash,
    required String family,
    required String modelHash,
    required String observationHash,
    required String actionHash,
  }) async {
    final file = File(path);
    if (!await file.exists() || await file.length() > 16777216) {
      throw FormatException('Evaluation receipt is unavailable or oversized.');
    }
    final value = ModelEvaluation.decode(
      await file.readAsBytes(),
      receiptHash: receiptHash,
      family: family,
      modelHash: modelHash,
      observationHash: observationHash,
      actionHash: actionHash,
    );
    return TrainingEvaluation.fromModel(value);
  }
}
