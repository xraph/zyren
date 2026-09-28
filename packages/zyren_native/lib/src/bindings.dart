import 'dart:ffi';

const _asset = 'package:zyren_native/src/bindings.dart';

final class NativeMeshLimits extends Struct {
  @Uint32()
  external int version;
  @Uint32()
  external int maxVertices;
  @Uint32()
  external int maxTriangles;
  @Uint32()
  external int maxAttributes;
  @Uint64()
  external int maxEncodedBytes;
  @Uint64()
  external int maxDecodedBytes;
}

final class NativeMeshBytes extends Struct {
  external Pointer<Uint8> data;
  @Size()
  external int length;
}

@Native<
  Uint32 Function(
    Pointer<Uint8>,
    Size,
    Pointer<NativeMeshLimits>,
    Pointer<NativeMeshBytes>,
  )
>(symbol: 'fg2_draco_decode', assetId: _asset)
external int dracoDecode(
  Pointer<Uint8> input,
  int length,
  Pointer<NativeMeshLimits> limits,
  Pointer<NativeMeshBytes> output,
);
@Native<Void Function(Pointer<NativeMeshBytes>)>(
  symbol: 'fg2_draco_free',
  assetId: _asset,
)
external void dracoFree(Pointer<NativeMeshBytes> output);

@Native<
  Uint32 Function(
    Pointer<Uint8>,
    Size,
    Size,
    Size,
    Uint32,
    Uint32,
    Pointer<Uint8>,
    Size,
  )
>(symbol: 'fg2_meshopt_decode', assetId: _asset)
external int meshoptDecode(
  Pointer<Uint8> input,
  int length,
  int count,
  int stride,
  int mode,
  int filter,
  Pointer<Uint8> output,
  int outputLength,
);

final class NativeImageLimits extends Struct {
  @Uint32()
  external int version;
  @Uint32()
  external int maxDimension;
  @Uint64()
  external int maxEncodedBytes;
  @Uint64()
  external int maxDecodedBytes;
  @Uint64()
  external int maxWorkingBytes;
}

final class NativeImagePixels extends Struct {
  @Uint32()
  external int width;
  @Uint32()
  external int height;
  external Pointer<Uint8> pixels;
  @Size()
  external int length;
}

@Native<
  Uint32 Function(
    Pointer<Uint8>,
    Size,
    Pointer<NativeImageLimits>,
    Pointer<NativeImagePixels>,
  )
>(symbol: 'fg2_image_decode', assetId: _asset)
external int imageDecode(
  Pointer<Uint8> input,
  int length,
  Pointer<NativeImageLimits> limits,
  Pointer<NativeImagePixels> output,
);
@Native<Void Function(Pointer<NativeImagePixels>)>(
  symbol: 'fg2_image_free',
  assetId: _asset,
)
external void imageFree(Pointer<NativeImagePixels> output);

final class NativeTextureBytes extends Struct {
  external Pointer<Uint8> data;
  @Size()
  external int length;
}

@Native<
  Uint32 Function(
    Pointer<Uint8>,
    Size,
    Pointer<NativeImageLimits>,
    Pointer<NativeTextureBytes>,
  )
>(symbol: 'fg2_ktx2_decode', assetId: _asset)
external int ktx2Decode(
  Pointer<Uint8> input,
  int length,
  Pointer<NativeImageLimits> limits,
  Pointer<NativeTextureBytes> output,
);
@Native<Void Function(Pointer<NativeTextureBytes>)>(
  symbol: 'fg2_ktx2_free',
  assetId: _asset,
)
external void ktx2Free(Pointer<NativeTextureBytes> output);

@Native<Uint32 Function()>(symbol: 'fg_abi_version', assetId: _asset)
external int abiVersion();
@Native<Uint64 Function()>(symbol: 'fg_create', assetId: _asset)
external int create();
@Native<Size Function()>(symbol: 'fg_live_renderer_count', assetId: _asset)
external int liveRendererCount();
@Native<Uint32 Function(Uint64)>(symbol: 'fg_destroy', assetId: _asset)
external int destroy(int handle);
@Native<Void Function(Pointer<Void>)>(symbol: 'fg_finalize', assetId: _asset)
external void finalize(Pointer<Void> token);
@Native<Size Function(Pointer<Uint8>, Size)>(
  symbol: 'fg_last_error',
  assetId: _asset,
)
external int lastError(Pointer<Uint8> buffer, int capacity);
@Native<
  Uint32 Function(
    Uint64,
    Pointer<Uint8>,
    Size,
    Uint32,
    Uint32,
    Pointer<Uint8>,
    Size,
  )
>(symbol: 'fg_render', assetId: _asset)
external int render(
  int handle,
  Pointer<Uint8> json,
  int jsonLength,
  int width,
  int height,
  Pointer<Uint8> pixels,
  int capacity,
);

@Native<
  Uint32 Function(
    Uint64,
    Pointer<Uint8>,
    Size,
    Pointer<Uint8>,
    Size,
    Pointer<Size>,
  )
>(symbol: 'fg2_resource_command', assetId: _asset)
external int resourceCommand(
  int handle,
  Pointer<Uint8> input,
  int length,
  Pointer<Uint8> output,
  int capacity,
  Pointer<Size> written,
);

@Native<
  Uint32 Function(
    Uint64,
    Pointer<Uint8>,
    Size,
    Pointer<Uint8>,
    Size,
    Pointer<Size>,
  )
>(symbol: 'fg2_shader_command', assetId: _asset)
external int shaderCommand(
  int handle,
  Pointer<Uint8> input,
  int length,
  Pointer<Uint8> output,
  int capacity,
  Pointer<Size> written,
);

@Native<
  Uint32 Function(
    Uint64,
    Pointer<Uint8>,
    Size,
    Pointer<Uint8>,
    Size,
    Pointer<Size>,
  )
>(symbol: 'fg2_graph_command', assetId: _asset)
external int graphCommand(
  int handle,
  Pointer<Uint8> input,
  int length,
  Pointer<Uint8> output,
  int capacity,
  Pointer<Size> written,
);

@Native<Uint32 Function(Uint64, Uint64)>(
  symbol: 'fg2_scene_close',
  assetId: _asset,
)
external int closeScene(int renderer, int view);
@Native<Uint64 Function(Uint64)>(
  symbol: 'fg2_scene_resident_bytes',
  assetId: _asset,
)
external int sceneResidentBytes(int renderer);
@Native<Uint64 Function(Uint64)>(
  symbol: 'fg2_scene_uploaded_bytes',
  assetId: _asset,
)
external int sceneUploadedBytes(int renderer);
