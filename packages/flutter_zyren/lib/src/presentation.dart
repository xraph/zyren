import 'dart:ui' as ui;
import 'package:flutter/widgets.dart';
import 'package:zyren/zyren.dart';

typedef PresenterFactory = FramePresenter Function();

/// Owns one displayed frame until the widget retires it after painting.
abstract interface class PresentedFrame {
  Widget build(BuildContext context);
  void dispose();
}

/// Converts backend output into a Flutter presentation without owning the GPU.
abstract interface class FramePresenter {
  Future<PresentedFrame> present(RenderedFrame frame);
  Future<void> dispose();
}

/// The current native readback adapter. Shared GPU textures are a later backend.
class ImageFramePresenter implements FramePresenter {
  bool _closed = false;
  static FramePresenter create() => ImageFramePresenter();

  @override
  Future<PresentedFrame> present(RenderedFrame frame) async {
    if (_closed) throw StateError('Presenter has been disposed.');
    if (frame.width < 1 ||
        frame.height < 1 ||
        frame.pixels.length != frame.width * frame.height * 4) {
      throw ArgumentError('Expected tightly packed RGBA8 pixels.');
    }
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(frame.pixels);
      descriptor = ui.ImageDescriptor.raw(
        buffer,
        width: frame.width,
        height: frame.height,
        pixelFormat: ui.PixelFormat.rgba8888,
      );
      codec = await descriptor.instantiateCodec();
      final image = (await codec.getNextFrame()).image;
      if (_closed) {
        image.dispose();
        throw StateError('Presenter was disposed while decoding.');
      }
      return _ImageFrame(image);
    } finally {
      codec?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
    }
  }

  @override
  Future<void> dispose() async {
    _closed = true;
  }
}

class _ImageFrame implements PresentedFrame {
  final ui.Image image;
  bool _closed = false;
  _ImageFrame(this.image);
  @override
  Widget build(BuildContext context) => RawImage(
    image: image,
    fit: BoxFit.fill,
    filterQuality: FilterQuality.low,
  );
  @override
  void dispose() {
    if (_closed) return;
    _closed = true;
    image.dispose();
  }
}
