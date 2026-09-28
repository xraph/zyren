import 'dart:ui' as ui;
import 'dart:typed_data';
import 'package:flutter/widgets.dart';
import 'package:gpu3d/gpu3d.dart';

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

/// Explicit RGBA readback adapter with conversion at the Flutter boundary.
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
      buffer = await ui.ImmutableBuffer.fromUint8List(_flutterPixels(frame));
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

Uint8List _flutterPixels(RenderedFrame frame) {
  if (frame.alphaMode == AlphaMode.premultiplied) return frame.pixels;
  final pixels = Uint8List.fromList(frame.pixels);
  for (var i = 0; i < pixels.length; i += 4) {
    if (frame.alphaMode == AlphaMode.opaque) {
      pixels[i + 3] = 255;
    } else {
      final alpha = pixels[i + 3];
      for (var channel = 0; channel < 3; channel++) {
        pixels[i + channel] = (pixels[i + channel] * alpha + 127) ~/ 255;
      }
    }
  }
  return pixels;
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
