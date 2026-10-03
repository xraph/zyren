part of '../../training.dart';

enum TrainingRunState {
  unavailable,
  queued,
  running,
  stopping,
  completed,
  failed,
  cancelled,
}

final class TrainingRunRequest {
  final String executable,
      projectDirectory,
      configPath,
      configFileHash,
      configHash,
      workerPath,
      runPath;
  final List<String> executableArguments;
  final bool resume;
  final int? stopAfterUpdates;
  TrainingRunRequest({
    required this.executable,
    required this.projectDirectory,
    required this.configPath,
    required this.configFileHash,
    required this.configHash,
    required this.workerPath,
    required this.runPath,
    List<String> executableArguments = const [],
    this.resume = false,
    this.stopAfterUpdates,
  }) : executableArguments = List.unmodifiable(executableArguments) {
    if (!_digest(configHash) ||
        !_digest(configFileHash) ||
        executableArguments.length > 16 ||
        executableArguments.any(
          (v) => v.length > 4096 || v.contains('\u0000'),
        ) ||
        stopAfterUpdates != null && stopAfterUpdates! < 1) {
      throw ArgumentError('Invalid training request pins or budget.');
    }
  }
  TrainingRunRequest copyWith({String? runPath, bool? resume}) =>
      TrainingRunRequest(
        executable: executable,
        executableArguments: executableArguments,
        projectDirectory: projectDirectory,
        configPath: configPath,
        configFileHash: configFileHash,
        configHash: configHash,
        workerPath: workerPath,
        runPath: runPath ?? this.runPath,
        resume: resume ?? this.resume,
        stopAfterUpdates: stopAfterUpdates,
      );
}

bool _digest(Object? value) =>
    value is String && RegExp(r'^[0-9a-f]{64}$').hasMatch(value);

final class TrainingReceipt {
  final Map<String, dynamic> data;
  TrainingReceipt._(Map<String, dynamic> data) : data = Map.unmodifiable(data);
  int get steps => data['steps'] as int? ?? 0;
  int get sequence => data['sequence'] as int;
  String get state => data['state'] as String;
  String get hash => data['sha256'] as String;
}

/// Verify the canonical byte representation emitted by the Python toolchain.
/// Removing the sorted sha256 field preserves Python float and Unicode encoding.
final class TrainingReceiptChain {
  final String configHash;
  var _previous = '0' * 64, _sequence = 0;
  TrainingReceiptChain(this.configHash) {
    if (!_digest(configHash)) throw ArgumentError('Invalid config hash.');
  }
  TrainingReceipt accept(String line) {
    if (utf8.encode(line).length > 65536) {
      throw FormatException('Receipt exceeds byte budget.');
    }
    final decoded = jsonDecode(line);
    if (decoded is! Map<String, dynamic>) {
      throw FormatException('Receipt must be an object.');
    }
    final value = Map<String, dynamic>.from(decoded);
    final marker = RegExp(r'"sha256":"[0-9a-f]{64}",');
    final matches = marker.allMatches(line).toList();
    if (matches.length != 1 ||
        !_digest(value['sha256']) ||
        value['sequence'] != _sequence + 1 ||
        value['previous'] != _previous ||
        value['config_hash'] != configHash ||
        ![
          'running',
          'completed',
          'failed',
          'cancelled',
        ].contains(value['state']) ||
        (value['steps'] != null &&
            (value['steps'] is! int || value['steps'] < 0)) ||
        sha256.convert(utf8.encode(line.replaceFirst(marker, ''))).toString() !=
            value['sha256']) {
      throw FormatException('Run receipt chain or config pin differs.');
    }
    _sequence++;
    _previous = value['sha256'] as String;
    return TrainingReceipt._(value);
  }
}

final class TrainingRunHandle {
  final TrainingRunRequest request;
  TrainingRunHandle._(this.request);
  TrainingRunState _state = TrainingRunState.queued;
  TrainingRunState get state => _state;
  String? error;
  String? checkpointHash, checkpointFile;
  int? exitCode;
  int steps = 0, updates = 0;
  final _logs = <String>[];
  List<String> get logs => List.unmodifiable(_logs);
  final _receipts = <TrainingReceipt>[];
  List<TrainingReceipt> get receipts => List.unmodifiable(_receipts);
  final _changes = StreamController<void>.broadcast();
  Stream<void> get changes => _changes.stream;
  final _done = Completer<void>();
  Future<void> get done => _done.future;
  Process? _process;
  bool _stopRequested = false;
  Future<void> stop() async {
    if (_done.isCompleted) return;
    _stopRequested = true;
    _state = TrainingRunState.stopping;
    _notify();
    _process?.kill(ProcessSignal.sigterm);
    await done;
  }

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }

  void _log(String line) {
    _logs.add(line.length > 2048 ? line.substring(0, 2048) : line);
    if (_logs.length > 128) _logs.removeAt(0);
    _notify();
  }
}

final class TrainingRunner {
  TrainingRunner({
    this.maxConcurrent = 1,
    this.stopGrace = const Duration(seconds: 30),
  }) {
    if (maxConcurrent < 1 || maxConcurrent > 4 || stopGrace <= Duration.zero) {
      throw ArgumentError('Invalid runner bounds.');
    }
  }
  final int maxConcurrent;
  final Duration stopGrace;
  final _runs = <TrainingRunHandle>[];
  bool _closed = false;
  int revision = 0;
  List<TrainingRunHandle> get runs => List.unmodifiable(_runs);
  Future<TrainingRunHandle> start(
    TrainingRunRequest request, {
    bool Function()? authorize,
  }) async {
    if (_closed) throw StateError('Training runner is closed.');
    if (_runs.where((r) => !r._done.isCompleted).length >= maxConcurrent ||
        _runs.length >= 64) {
      throw StateError('Training run capacity reached.');
    }
    final project = await Directory(
      request.projectDirectory,
    ).resolveSymbolicLinks();
    await _scopedPath(project, request.configPath);
    await _scopedPath(project, request.runPath);
    if (_closed ||
        _runs.where((r) => !r._done.isCompleted).length >= maxConcurrent ||
        _runs.length >= 64) {
      throw StateError('Training run capacity changed.');
    }
    final run = TrainingRunHandle._(request);
    _runs.add(run);
    revision++;
    unawaited(_execute(run, authorize));
    return run;
  }

  Future<void> _execute(
    TrainingRunHandle run,
    bool Function()? authorize,
  ) async {
    final request = run.request;
    StreamSubscription<List<int>>? out, err;
    Timer? poll, kill;
    Future<void> reading = Future.value();
    var polling = false;
    try {
      final worker = File(request.workerPath),
          config = File(request.configPath);
      if (!await worker.exists() || !await config.exists()) {
        run._state = TrainingRunState.unavailable;
        run.error = 'Configured worker or configuration is missing.';
        return;
      }
      if ((await config.length()) > 1048576 ||
          sha256.convert(await config.readAsBytes()).toString() !=
              request.configFileHash) {
        throw FormatException('Configuration file pin differs.');
      }
      final data =
          jsonDecode(await config.readAsString()) as Map<String, dynamic>;
      if (!_digest(data['worker_sha256']) ||
          (await worker.length()) > 268435456 ||
          sha256.convert(await worker.readAsBytes()).toString() !=
              data['worker_sha256']) {
        throw FormatException('Prepared worker pin differs.');
      }
      final chain = TrainingReceiptChain(request.configHash);
      var offset = 0;
      var remainder = '';
      Future<void> read({bool finalRead = false}) async {
        final file = File('${request.runPath}/receipts.jsonl');
        if (!await file.exists()) return;
        final length = await file.length();
        if (length < offset || length > 16777216) {
          throw FormatException('Receipt stream truncated or exceeds budget.');
        }
        if (length != offset) {
          final bytes = await file
              .openRead(offset, length)
              .fold<List<int>>([], (v, n) => v..addAll(n));
          offset = length;
          remainder += utf8.decode(bytes);
          final lines = remainder.split('\n');
          remainder = lines.removeLast();
          for (final line in lines) {
            if (line.isEmpty) throw FormatException('Empty receipt.');
            final receipt = chain.accept(line);
            run._receipts.add(receipt);
            if (run._receipts.length > 256) run._receipts.removeAt(0);
            run.steps = receipt.steps;
            run.updates = receipt.data['updates'] as int? ?? run.updates;
            if (receipt.state == 'running' && !run._stopRequested) {
              run._state = TrainingRunState.running;
            }
            run._notify();
          }
        }
        if (finalRead && remainder.isNotEmpty) {
          throw FormatException('Receipt stream ended mid-record.');
        }
      }

      if (request.resume) {
        await read(finalRead: true);
        if (run._receipts.isEmpty || run._receipts.last.state == 'completed') {
          throw FormatException('Run cannot resume.');
        }
        await _checkpoint(run);
      } else if (await Directory(request.runPath).exists()) {
        throw FormatException('New run directory already exists.');
      }
      if (_closed || run._stopRequested || authorize != null && !authorize()) {
        run._state = TrainingRunState.cancelled;
        return;
      }
      final args = [
        ...request.executableArguments,
        'train',
        '--config',
        request.configPath,
        '--worker',
        request.workerPath,
        '--cwd',
        request.projectDirectory,
        '--run',
        request.runPath,
        if (request.resume) '--resume',
        if (request.stopAfterUpdates != null) ...[
          '--stop-after-updates',
          '${request.stopAfterUpdates}',
        ],
      ];
      await Directory(request.runPath).parent.create(recursive: true);
      run._process = await Process.start(
        request.executable,
        args,
        workingDirectory: request.projectDirectory,
        runInShell: false,
      );
      void consume(List<int> chunk) =>
          run._log(utf8.decode(chunk, allowMalformed: true));
      out = run._process!.stdout.listen(consume);
      err = run._process!.stderr.listen(consume);
      poll = Timer.periodic(const Duration(milliseconds: 100), (_) {
        if (!polling) {
          polling = true;
          reading = read().catchError((Object error) {
            run.error = '$error';
            run._stopRequested = true;
            run._process?.kill(ProcessSignal.sigterm);
          }).whenComplete(() => polling = false);
        }
        if (run._stopRequested && kill == null) {
          kill = Timer(
            stopGrace,
            () => run._process?.kill(ProcessSignal.sigkill),
          );
        }
      });
      if (run._stopRequested) run._process!.kill(ProcessSignal.sigterm);
      run.exitCode = await run._process!.exitCode;
      poll.cancel();
      await reading;
      await read(finalRead: true);
      if (run.error != null) throw FormatException(run.error!);
      if (run._receipts.isEmpty || run._receipts.last.state == 'running') {
        throw FormatException('Trainer exited without a final receipt.');
      }
      final last = run._receipts.last;
      if (last.data['workers_closed'] != true ||
          last.data['worker_exit_codes'] is! List ||
          (last.state == 'completed' &&
              (run.exitCode != 0 ||
                  (last.data['worker_exit_codes'] as List).any((v) => v != 0)))) {
        throw FormatException('Trainer/worker closure is unverified.');
      }
      if (last.state == 'completed' || last.state == 'cancelled') {
        await _checkpoint(run);
        if (last.data['checkpoint_sha256'] != run.checkpointHash) {
          throw FormatException('Final checkpoint pin differs.');
        }
      }
      run._state = TrainingRunState.values.byName(last.state);
      run.error = last.data['error'] as String?;
    } on ProcessException catch (error) {
      run._state = TrainingRunState.unavailable;
      run.error = '$error';
    } catch (error) {
      run._state = TrainingRunState.failed;
      run.error = '$error';
    } finally {
      poll?.cancel();
      kill?.cancel();
      await out?.cancel();
      await err?.cancel();
      run._process = null;
      revision++;
      run._notify();
      run._done.complete();
    }
  }

  Future<void> _checkpoint(TrainingRunHandle run) async {
    final pointer = File('${run.request.runPath}/checkpoint.json');
    if (!await pointer.exists() || await pointer.length() > 65536) {
      throw FormatException('Checkpoint pointer missing or oversized.');
    }
    final data =
        jsonDecode(await pointer.readAsString()) as Map<String, dynamic>;
    final name = data['file'];
    if (data['version'] != 1 ||
        data['config_hash'] != run.request.configHash ||
        name is! String ||
        !RegExp(r'^checkpoint-[A-Za-z0-9-]{1,80}\.pt$').hasMatch(name) ||
        !_digest(data['sha256'])) {
      throw FormatException('Checkpoint identity differs.');
    }
    final project = await Directory(
      run.request.projectDirectory,
    ).resolveSymbolicLinks();
    await _scopedPath(project, '${run.request.runPath}/$name');
    final file = File('${run.request.runPath}/$name');
    if (!await file.exists() ||
        await file.length() > 100663296 ||
        sha256.convert(await file.readAsBytes()).toString() != data['sha256']) {
      throw FormatException('Checkpoint hash differs.');
    }
    run.checkpointFile = name;
    run.checkpointHash = data['sha256'] as String;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await Future.wait(
      _runs.where((r) => !r._done.isCompleted).map((r) => r.stop()),
    );
    for (final run in _runs) {
      await run._changes.close();
    }
  }
}

Future<void> _scopedPath(String project, String path) async {
  final uri = File(path).absolute.uri.normalizePath();
  if (path.contains('\u0000')) throw ArgumentError('Invalid training path.');
  var parent = File.fromUri(uri).parent;
  while (!await parent.exists()) {
    final next = parent.parent;
    if (next.path == parent.path) break;
    parent = next;
  }
  final resolved = await parent.resolveSymbolicLinks();
  if (resolved != project && !resolved.startsWith('$project/')) {
    throw ArgumentError('Training path escapes through a symlink.');
  }
  if (await Directory(path).exists() &&
      !(await Directory(path).resolveSymbolicLinks()).startsWith('$project/')) {
    throw ArgumentError('Training directory escapes project scope.');
  }
  if (await File(path).exists() &&
      !(await File(path).resolveSymbolicLinks()).startsWith('$project/')) {
    throw ArgumentError('Training file escapes project scope.');
  }
}
