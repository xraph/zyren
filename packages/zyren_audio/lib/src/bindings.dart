import 'dart:ffi';

const _asset = 'package:zyren_audio/src/bindings.dart';
@Native<Int32 Function(Int32, Uint32, Pointer<Pointer<Void>>)>(
  assetId: _asset,
  symbol: 'za_engine_create',
)
external int create(int offline, int sampleRate, Pointer<Pointer<Void>> output);
@Native<Void Function(Pointer<Void>)>(assetId: _asset, symbol: 'za_engine_free')
external void freeEngine(Pointer<Void> engine);
@Native<Pointer<Char> Function(Pointer<Void>)>(
  assetId: _asset,
  symbol: 'za_backend_name',
)
external Pointer<Char> backendName(Pointer<Void> engine);
@Native<
  Int32 Function(Pointer<Void>, Pointer<Float>, Uint32, Pointer<Pointer<Void>>)
>(assetId: _asset, symbol: 'za_voice_create')
external int createVoice(
  Pointer<Void> engine,
  Pointer<Float> samples,
  int frames,
  Pointer<Pointer<Void>> output,
);
@Native<Void Function(Pointer<Void>, Pointer<Void>)>(
  assetId: _asset,
  symbol: 'za_voice_free',
)
external void freeVoice(Pointer<Void> engine, Pointer<Void> voice);
@Native<
  Void Function(
    Pointer<Void>,
    Float,
    Float,
    Float,
    Float,
    Float,
    Float,
    Float,
    Float,
    Float,
  )
>(assetId: _asset, symbol: 'za_listener')
external void listener(
  Pointer<Void> engine,
  double x,
  double y,
  double z,
  double fx,
  double fy,
  double fz,
  double ux,
  double uy,
  double uz,
);
@Native<Void Function(Pointer<Void>, Float, Float, Float)>(
  assetId: _asset,
  symbol: 'za_position',
)
external void position(Pointer<Void> voice, double x, double y, double z);
@Native<Void Function(Pointer<Void>, Float, Float, Float, Float, Int32, Int32)>(
  assetId: _asset,
  symbol: 'za_settings',
)
external void settings(
  Pointer<Void> voice,
  double volume,
  double minDistance,
  double maxDistance,
  double rolloff,
  int attenuation,
  int loop,
);
@Native<Int32 Function(Pointer<Void>)>(assetId: _asset, symbol: 'za_play')
external int play(Pointer<Void> voice);
@Native<Int32 Function(Pointer<Void>)>(assetId: _asset, symbol: 'za_pause')
external int pause(Pointer<Void> voice);
@Native<Int32 Function(Pointer<Void>)>(assetId: _asset, symbol: 'za_rewind')
external int rewind(Pointer<Void> voice);
@Native<Int32 Function(Pointer<Void>)>(assetId: _asset, symbol: 'za_playing')
external int playing(Pointer<Void> voice);
@Native<Int32 Function(Pointer<Void>, Pointer<Float>, Uint32)>(
  assetId: _asset,
  symbol: 'za_read',
)
external int read(Pointer<Void> engine, Pointer<Float> output, int frames);

@Native<Int32 Function(Pointer<Void>)>(
  assetId: _asset,
  symbol: 'za_engine_suspend',
)
external int suspendEngine(Pointer<Void> engine);
@Native<Int32 Function(Pointer<Void>)>(
  assetId: _asset,
  symbol: 'za_engine_resume',
)
external int resumeEngine(Pointer<Void> engine);
@Native<Int32 Function(Pointer<Void>, Pointer<Char>, Pointer<Pointer<Void>>)>(
  assetId: _asset,
  symbol: 'za_voice_file',
)
external int createFile(
  Pointer<Void> engine,
  Pointer<Char> path,
  Pointer<Pointer<Void>> output,
);
@Native<Int32 Function(Pointer<Void>, Double)>(
  assetId: _asset,
  symbol: 'za_seek',
)
external int seek(Pointer<Void> voice, double seconds);
@Native<Int32 Function(Pointer<Void>, Int32, Pointer<Double>)>(
  assetId: _asset,
  symbol: 'za_time',
)
external int time(Pointer<Void> voice, int length, Pointer<Double> seconds);
@Native<Void Function(Pointer<Void>, Float)>(assetId: _asset, symbol: 'za_gain')
external void gain(Pointer<Void> voice, double gain);
@Native<Void Function(Pointer<Void>, Float, Float, Float, Float)>(
  assetId: _asset,
  symbol: 'za_velocity',
)
external void velocity(
  Pointer<Void> voice,
  double x,
  double y,
  double z,
  double factor,
);
@Native<Void Function(Pointer<Void>, Float, Float, Float)>(
  assetId: _asset,
  symbol: 'za_listener_velocity',
)
external void listenerVelocity(
  Pointer<Void> engine,
  double x,
  double y,
  double z,
);
