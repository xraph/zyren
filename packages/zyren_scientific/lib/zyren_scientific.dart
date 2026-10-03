/// Scalar data validation and native mesh visualization for Zyren.
library;

export 'src/scalar_grid.dart';
export 'src/scalar_slice.dart';
export 'src/slice_view.dart'
    show ScientificSliceView, ScientificViewException, ScientificViewFailure;
export 'src/transfer_function.dart';
export 'src/surface.dart'
    show ScientificSurface, ScalarAssociation, extractIsosurface;
export 'src/work.dart' show ScientificCancellation, ScientificCancelled;
export 'src/sampling.dart'
    show ScientificSample, ScientificSampleStatus, sampleScalar;
export 'src/vectors.dart';
