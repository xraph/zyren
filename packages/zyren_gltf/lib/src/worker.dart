import 'dart:async';
import 'dart:collection';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'accessor.dart';
import 'data_uri.dart';
import 'checked.dart';
import 'document.dart';
import 'limits.dart';
import 'options.dart';
import 'recipes.dart';
import 'mesh_decoder.dart';

/// At most two parser isolates run from one application isolate. Queued jobs
/// retain source references; transferable copies are made only after admission.
final class GltfWorkers {
  static final _pending = Queue<_Job>();
  static int _active = 0;
  static Future<Uint8List> dataUri(
    String uri,
    int maxBytes,
    Set<String> mediaTypes,
    LoadCancellation cancellation,
    String path,
  ) async =>
      await _enqueue(
            () => ['dataUri', uri, maxBytes, mediaTypes, path],
            cancellation,
          )
          as Uint8List;
  static Future<GltfDocument> parse(
    Uint8List bytes,
    GltfLimits limits,
    LoadCancellation cancellation, {
    Set<String> supportedExtensions = const {},
  }) async =>
      await _enqueue(
            () => [
              'parse',
              TransferableTypedData.fromList([bytes]),
              limits,
              supportedExtensions,
            ],
            cancellation,
          )
          as GltfDocument;

  static Future<PreparedModel> model(
    Map<String, Object?> root,
    List<Uint8List> buffers,
    GltfOptions options,
    int maxDecodedBytes,
    LoadCancellation cancellation,
  ) async =>
      await _enqueue(
            () => [
              'model',
              root,
              [
                for (final bytes in buffers)
                  TransferableTypedData.fromList([bytes]),
              ],
              options,
              maxDecodedBytes,
            ],
            cancellation,
          )
          as PreparedModel;

  static Future<TextureImageData> image(
    ImageData image,
    bool mipmaps,
    LoadCancellation cancellation, {
    bool linear = false,
  }) async =>
      await _enqueue(
            () => [
              'image',
              TransferableTypedData.fromList([image.pixels]),
              image.size,
              image.rowStride,
              image.format,
              linear ? ColorSpace.linear : ColorSpace.srgb,
              image.alphaMode,
              mipmaps,
            ],
            cancellation,
          )
          as TextureImageData;

  static Future<List<DecodedAccessor>> accessors(
    Map<String, Object?> root,
    List<Uint8List> buffers,
    GltfLimits limits,
    int maxDecodedBytes,
    LoadCancellation cancellation,
  ) async =>
      (await _enqueue(
            () => [
              'accessors',
              root,
              [
                for (final bytes in buffers)
                  TransferableTypedData.fromList([bytes]),
              ],
              limits,
              maxDecodedBytes,
            ],
            cancellation,
          ))
          as List<DecodedAccessor>;

  static Future<Object> _enqueue(
    List<Object> Function() input,
    LoadCancellation cancellation,
  ) {
    cancellation.throwIfCancelled();
    if (_pending.length >= 16) {
      throw AssetLoadException(
        AssetLoadError.limitExceeded,
        'The glTF worker queue is full. Retry after a pending load settles.',
      );
    }
    final job = _Job(input, cancellation);
    _pending.add(job);
    job.registration = cancellation.onCancel(() {
      if (_pending.remove(job)) {
        job.result.completeError(LoadCancelled());
        job.registration?.dispose();
      }
    });
    _drain();
    return job.result.future;
  }

  static void _drain() {
    while (_active < 2 && _pending.isNotEmpty) {
      final job = _pending.removeFirst();
      job.registration?.dispose();
      _active++;
      _run(job)
          .then<void>(
            (result) => job.result.complete(result),
            onError: (Object error, StackTrace stack) =>
                job.result.completeError(error, stack),
          )
          .whenComplete(() {
            _active--;
            _drain();
          });
    }
  }
}

class _Job {
  final List<Object> Function() input;
  final LoadCancellation cancellation;
  final result = Completer<Object>();
  Registration? registration;
  _Job(this.input, this.cancellation) {
    result.future.then<void>((_) {}, onError: (Object _, StackTrace _) {});
  }
}

Future<Object> _run(_Job job) async {
  final port = ReceivePort();
  final result = Completer<Object>();
  result.future.then<void>((_) {}, onError: (Object _, StackTrace _) {});
  Isolate? isolate;
  void fail(Object error) {
    if (!result.isCompleted) result.completeError(error);
  }

  final subscription = port.listen((message) {
    if (result.isCompleted) return;
    switch (message) {
      case _Success(:final value):
        result.complete(value);
      case _Failure(:final code, :final message, :final path):
        fail(AssetLoadException(code, message, fieldPath: path));
      default:
        fail(
          AssetLoadException(
            AssetLoadError.decodeFailed,
            'The glTF worker exited without a result.',
          ),
        );
    }
  });
  final registration = job.cancellation.onCancel(() {
    isolate?.kill(priority: Isolate.immediate);
    fail(LoadCancelled());
  });
  try {
    job.cancellation.throwIfCancelled();
    final input = job.input();
    isolate = await Isolate.spawn(
      _entry,
      (port.sendPort, input),
      onError: port.sendPort,
      onExit: port.sendPort,
      errorsAreFatal: true,
      debugName: 'zyren-gltf-${input.first}',
    );
    if (job.cancellation.isCancelled) isolate.kill(priority: Isolate.immediate);
    return await result.future;
  } finally {
    registration.dispose();
    isolate?.kill(priority: Isolate.immediate);
    await subscription.cancel();
    port.close();
  }
}

final class _Success {
  final Object value;
  const _Success(this.value);
}

final class _Failure {
  final AssetLoadError code;
  final String message;
  final String? path;
  const _Failure(this.code, this.message, this.path);
}

void _entry((SendPort, List<Object>) request) {
  final (reply, args) = request;
  Object result;
  try {
    switch (args[0]) {
      case 'dataUri':
        result = decodeDataUri(
          args[1] as String,
          args[2] as int,
          args[3] as Set<String>,
          args[4] as String,
        );
      case 'parse':
        final bytes = (args[1] as TransferableTypedData)
            .materialize()
            .asUint8List();
        result = GltfDocument.parse(
          bytes,
          limits: args[2] as GltfLimits,
          supportedExtensions: args[3] as Set<String>,
        );
      case 'model':
        result = prepareModel(
          args[1] as Map<String, Object?>,
          [
            for (final transfer in args[2] as List<TransferableTypedData>)
              transfer.materialize().asUint8List(),
          ],
          args[3] as GltfOptions,
          args[4] as int,
        );
      case 'image':
        result = TextureImageData.fromImage(
          ImageData(
            pixels: (args[1] as TransferableTypedData)
                .materialize()
                .asUint8List(),
            size: args[2] as PhysicalSize,
            rowStride: args[3] as int,
            format: args[4] as PixelFormat,
            colorSpace: args[5] as ColorSpace,
            alphaMode: args[6] as AlphaMode,
          ),
          generateMipmaps: args[7] as bool,
        );
      case 'accessors':
        final root = args[1] as Map<String, Object?>;
        final buffers = [
          for (final transfer in args[2] as List<TransferableTypedData>)
            transfer.materialize().asUint8List(),
        ];
        final reader = AccessorReader(
          root,
          buffers,
          limits: args[3] as GltfLimits,
          budget: DecodeBudget(args[4] as int),
        );
        result = [
          for (
            var i = 0;
            i < (root['accessors'] as List<Object?>? ?? const []).length;
            i++
          )
            reader.read(i),
        ];
      default:
        throw StateError('Unknown glTF worker operation.');
    }
    // Isolate.exit transfers ownership of the result graph and its typed storage.
    Isolate.exit(reply, _Success(result));
  } on AssetLoadException catch (error) {
    Isolate.exit(
      reply,
      _Failure(error.code, error.issue.message, error.fieldPath),
    );
  } catch (_) {
    Isolate.exit(
      reply,
      const _Failure(
        AssetLoadError.decodeFailed,
        'The glTF parser failed.',
        null,
      ),
    );
  }
}
