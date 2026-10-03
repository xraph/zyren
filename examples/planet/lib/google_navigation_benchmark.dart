import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'geospatial_presets.dart';
import 'google_tiles_lab.dart';
import 'navigation_benchmark_stats.dart';
import 'navigation_device_report.dart';
import 'navigation_failure_report.dart';
import 'preset_globe_controls.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final key = GlobalKey<GoogleTilesLabState>();
  runApp(GoogleTilesLabApp(labKey: key, clouds: true));
  WidgetsBinding.instance.addPostFrameCallback((_) {
    _NavigationBenchmark(key.currentState!).register();
  });
}

final class _NavigationBenchmark {
  final GoogleTilesLabState lab;
  bool _running = false;
  String _stage = 'ready';
  Map<String, Object?>? _result;
  Object? _expectedSettings;
  _NavigationBenchmark(this.lab);
  SceneController get controller => lab.controller;
  PresetGlobeControlsPlugin get navigation =>
      controller.requestedPlugins.whereType<PresetGlobeControlsPlugin>().single;

  void register() {
    developer.registerExtension('ext.planet.navigationBenchmark', (
      _,
      args,
    ) async {
      if (args['command'] == 'start' && !_running) {
        final variant = args['variant'] ?? 'auto';
        final weather = args['weather'] ?? 'animated';
        if (![
              'auto',
              'low',
              'medium',
              'high',
              'shadowsOff',
              'sparse',
            ].contains(variant) ||
            !['animated', 'fixed'].contains(weather)) {
          return developer.ServiceExtensionResponse.error(
            developer.ServiceExtensionResponse.invalidParams,
            'Unknown variant or weather mode.',
          );
        }
        _running = true;
        _result = null;
        unawaited(_run(variant, fixedWeather: weather == 'fixed'));
      }
      return developer.ServiceExtensionResponse.result(
        jsonEncode({'running': _running, 'stage': _stage, 'result': _result}),
      );
    });
    const runId = String.fromEnvironment('PLANET_NAVIGATION_RUN_ID');
    if (runId.isNotEmpty) unawaited(_runOnDevice(runId));
  }

  Future<void> _runOnDevice(String runId) async {
    const variant = String.fromEnvironment(
      'PLANET_NAVIGATION_VARIANT',
      defaultValue: 'auto',
    );
    const weather = String.fromEnvironment(
      'PLANET_NAVIGATION_WEATHER',
      defaultValue: 'animated',
    );
    if (![
          'auto',
          'low',
          'medium',
          'high',
          'shadowsOff',
          'sparse',
        ].contains(variant) ||
        !['animated', 'fixed'].contains(weather)) {
      throw ArgumentError('Unknown variant or weather mode.');
    }
    _running = true;
    await _run(variant, fixedWeather: weather == 'fixed');
    await saveNavigationDeviceReport(
      Directory('${Directory.systemTemp.path}/planet-navigation'),
      runId,
      _result!,
    );
  }

  void _check() {
    if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      throw StateError('The benchmark app lost the foreground.');
    }
    if (lab.loadError != null) {
      throw StateError(
        'Provider initialization failed (${lab.loadError.runtimeType}).',
      );
    }
    if (controller.status.value case SceneFailed(:final issue)) {
      throw StateError('Renderer failed: ${issue.code}.');
    }
    if (_expectedSettings != null && _expectedSettings != _sceneSettings) {
      throw StateError('Benchmark scene settings changed during the run.');
    }
  }

  Object get _sceneSettings => (
    lab.profile.cloudQuality,
    lab.profile.cloudSparsity,
    lab.profile.cloudDensity,
    lab.profile.cloudAnimationEnabled,
    lab.profile.moonlight,
    lab.profile.nightView,
  );

  void _weather(bool fixed) {
    lab.profile.cloudAnimationEnabled = !fixed;
    if (fixed) {
      final cloud = lab.profile.cloudLayer!.controller;
      cloud.parameters = cloud.parameters.copyWith(
        localWeatherVelocity: (0, 0),
        shapeVelocity: Vec3.zero,
        shapeDetailVelocity: Vec3.zero,
      );
    }
  }

  Future<void> _settle({required Duration timeout}) async {
    final clock = Stopwatch()..start();
    int? quietAt;
    while (clock.elapsed < timeout) {
      _check();
      final tiles = lab.tiles;
      final ready =
          (tiles?.stats?.visibleTiles ?? 0) > 0 &&
          tiles!.attributions.isNotEmpty &&
          tiles.stats!.activeRequests == 0 &&
          controller.latestFrameStats?.admission?.candidateReady == true &&
          lab.profile.cloudLayer!.controller.history.accumulatedFrames >= 16;
      if (ready) {
        quietAt ??= clock.elapsedMilliseconds;
        if (clock.elapsedMilliseconds - quietAt >= 2000) return;
      } else {
        quietAt = null;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw StateError(
      'Tiles or cloud history did not settle before the measurement.',
    );
  }

  Future<void> _run(String variant, {required bool fixedWeather}) async {
    _expectedSettings = null;
    final loadingClock = Stopwatch()..start();
    final phases = <Map<String, Object?>>[];
    final report = <String, Object?>{
      'schema': 1,
      'suite': 'live-google-navigation',
      'variant': variant,
      'weather': fixedWeather ? 'fixed' : 'animated',
      'platform': defaultTargetPlatform.name,
      'buildMode': kProfileMode
          ? 'profile'
          : kReleaseMode
          ? 'release'
          : 'debug',
      'preset': 'tokyo',
      'lifecycle': WidgetsBinding.instance.lifecycleState?.name,
      'phases': phases,
      'passed': false,
    };
    Registration? demand;
    try {
      if (!kProfileMode) {
        throw StateError('Use a profile build for this benchmark.');
      }
      if (!GoogleTilesLabState.configured) {
        throw StateError(
          'Missing private Google Maps or Cesium Ion configuration.',
        );
      }
      _stage = 'loading';
      if (controller.status.value is SceneFailed) await controller.retry();
      await controller.firstFrame.timeout(const Duration(minutes: 3));
      final info = await controller.ready;
      lab.profile.apply(
        controller.scene,
        controller.camera,
        GoogleTilesPreset.tokyo,
      );
      navigation.resetForPreset();
      report.addAll({
        'backend': info.backend,
        'adapter': info.adapterName,
        'presentation': info.presentationPath.name,
        'deviceProfile': lab.deviceProfile.device.name,
        'fpsLimit': controller.options.maxFramesPerSecond,
      });
      demand = controller.onUpdate((_) {});
      await lab.profile.setCloudQuality(
        lab.deviceProfile.clouds(switch (variant) {
          'low' => CloudQualityPreset.low,
          'medium' => CloudQualityPreset.medium,
          'high' => CloudQualityPreset.high,
          _ => null,
        }, variant != 'shadowsOff'),
      );
      lab.profile.cloudSparsity = variant == 'sparse' ? .75 : 0;
      lab.profile.cloudDensity = 1;
      _weather(fixedWeather);
      _expectedSettings = _sceneSettings;
      await _settle(timeout: const Duration(minutes: 3));
      report['initialReadyMs'] = loadingClock.elapsedMilliseconds;
      final cloud = lab.profile.cloudLayer!.controller;
      report['settings'] = {
        'quality': cloud.quality.name,
        'shadows': cloud.shadowsEnabled,
        'sparsity': cloud.parameters.sparsity,
        'density': lab.profile.cloudDensity,
        'animation': lab.profile.cloudAnimationEnabled,
        'animationElapsedMs': cloud.animationElapsed.inMilliseconds,
        'moonlight': lab.profile.moonlight.name,
        'nightView': lab.profile.nightView,
        'cloudSize': [cloud.width, cloud.height],
        'resourceBudgetBytes': lab.deviceProfile.resourceBudgetBytes,
        'tileBudgetBytes': lab.deviceProfile.tileBytes,
      };
      for (final phase in ['stationary', 'rotate', 'drag', 'zoom']) {
        _stage = 'settling $phase';
        lab.profile.apply(
          controller.scene,
          controller.camera,
          GoogleTilesPreset.tokyo,
        );
        navigation.resetForPreset();
        _weather(fixedWeather);
        await _settle(timeout: const Duration(minutes: 2));
        if (lab.tiles!.failures.isNotEmpty) {
          throw StateError('Tile failures remain before the measurement.');
        }
        final controls = navigation.controls!;
        final viewport = controls.viewport;
        final center = ViewportPoint(viewport.width * .5, viewport.height * .7);
        final hit = await controller.pick(center);
        if (hit == null) {
          throw StateError('No rendered city geometry under the route pivot.');
        }
        final start = controller.camera.position;
        final renderSize = controller.latestFrameStats!.physicalSize;
        var displacement = 0.0;
        final samples = <Map<String, Object?>>[];
        final clock = Stopwatch();
        var previousWheel = 0.0;
        final subscription = controller.presentations.listen((sample) {
          final f = sample.frame, tiles = lab.tiles!.stats!;
          displacement = math.max(
            displacement,
            controller.camera.position.distanceTo(start),
          );
          samples.add({
            'atUs': sample.elapsed.inMicroseconds,
            'buildUs': f.cpuBuildTime.inMicroseconds,
            'submitUs': f.cpuSubmitTime.inMicroseconds,
            'gpuUs': f.gpuTime?.inMicroseconds,
            'profile': f.profile?.toJson(),
            if (f.admission case final admission?)
              'admission': {
                'candidateReady': admission.candidateReady,
                'publishedRevision': admission.publishedRevision,
                'uploadBacklogBytes': admission.uploadBacklogBytes,
                'stagedBytes': admission.stagedBytes,
                'presentedObjects': admission.presentedIdentities.length,
              },
            'drawCalls': f.drawCalls,
            'triangles': f.triangles,
            'uploadedBytes': f.uploadedBytes,
            'readbackBytes': f.readbackBytes,
            'loading': tiles.activeRequests,
            'visible': tiles.visibleTiles,
            'selected': tiles.selectedTiles,
            'tileBytes': tiles.residentBytes,
            'budgetLimited': tiles.budgetLimited,
            'cloudHistory': cloud.history.accumulatedFrames,
            'cloudReset': cloud.history.reason.name,
          });
        });
        if (phase == 'rotate' || phase == 'drag') {
          controls.handlePointer(
            ScenePointerEvent(
              point: center,
              phase: ScenePointerPhase.down,
              kind: ScenePointerKind.mouse,
              buttons: phase == 'rotate' ? 2 : 1,
            ),
          );
        }
        final motion = controller.onUpdate((_) {
          if (phase == 'stationary') return;
          final wave = math.sin(
            2 * math.pi * clock.elapsedMicroseconds / 12000000,
          );
          if (phase == 'zoom') {
            final wheel = wave * 240;
            controls.handleWheel(center, wheel - previousWheel);
            previousWheel = wheel;
          } else {
            controls.handlePointer(
              ScenePointerEvent(
                point: ViewportPoint(
                  center.x + viewport.width * .2 * wave,
                  center.y,
                ),
                phase: ScenePointerPhase.move,
                kind: ScenePointerKind.mouse,
              ),
            );
          }
        });
        _stage = 'measuring $phase';
        clock.start();
        Object? phaseFailure;
        try {
          while (clock.elapsed < const Duration(seconds: 12)) {
            await Future<void>.delayed(const Duration(milliseconds: 100));
            _check();
          }
        } catch (error) {
          phaseFailure = error;
        } finally {
          motion.dispose();
          if (identical(navigation.controls, controls)) controls.cancel();
          await subscription.cancel();
        }
        if (samples.length < 2 ||
            samples.any((s) => s['readbackBytes'] != 0 || s['visible'] == 0)) {
          phaseFailure ??= StateError(
            'The phase did not sustain native city presentations.',
          );
        }
        if (phase != 'stationary' && displacement < 1) {
          phaseFailure ??= StateError(
            'The navigation input did not move the camera.',
          );
        }
        if (lab.tiles!.failures.isNotEmpty) {
          phaseFailure ??= StateError(
            'Tile failures occurred during navigation.',
          );
        }
        final summary = summarizeNavigationFrames(samples);
        phases.add({
          'name': phase,
          ...summary,
          'maxCameraDisplacementM': displacement,
          'viewport': [viewport.width, viewport.height],
          'renderSize': [renderSize.width, renderSize.height],
          'failedTiles': lab.tiles!.failures.length,
          'completed': phaseFailure == null,
          if (phaseFailure != null) 'error': phaseFailure.toString(),
          'samples': samples,
        });
        if (phaseFailure != null) throw phaseFailure;
      }
      report['passed'] = true;
      _stage = 'complete';
    } catch (error) {
      report['error'] = error.toString();
      _stage = 'failed';
    } finally {
      try {
        demand?.dispose();
        navigation.controls?.cancel();
      } catch (error) {
        report['cleanupError'] = error.runtimeType.toString();
        report['passed'] = false;
        report['error'] ??= 'Benchmark controls could not be released.';
        _stage = 'failed';
      }
      report['lifecycleAtEnd'] = WidgetsBinding.instance.lifecycleState?.name;
      if (controller.status.value case SceneFailed(:final issue)) {
        report['rendererFailure'] = {
          'code': issue.code,
          'operation': issue.operation,
          'causeType': issue.cause.runtimeType.toString(),
          'uploadBudgetExceeded': issue.message.contains(
            'Scene resource upload exceeds the frame budget.',
          ),
        };
      }
      report['completePhaseNames'] = [
        for (final phase in phases)
          if (phase['completed'] == true) phase['name'],
      ];
      report['allPhasesComplete'] =
          phases.length == 4 &&
          phases.every((phase) => phase['completed'] == true);
      report['tileFailures'] = navigationTileFailures(lab.tiles?.failures);
      _result = report;
      _expectedSettings = null;
      _running = false;
    }
  }
}
