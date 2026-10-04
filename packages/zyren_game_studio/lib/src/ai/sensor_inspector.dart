part of '../../ai.dart';

class GameSensorInspector extends StatelessWidget {
  final GameAiWorkspace workspace;
  const GameSensorInspector({super.key, required this.workspace});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: workspace,
    builder: (_, _) {
      if (!workspace.canInspect) {
        return const ZeroState(
          title: 'Sensor access denied',
          message: 'You need project AI inspection access.',
        );
      }
      final actor = workspace.selectedActor;
      final profile = workspace.sensors[actor];
      final observation = workspace.cameras[actor];
      return SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (workspace.captureCamera != null)
              TextButton.icon(
                icon: const Icon(Icons.camera_alt_outlined),
                label: Text(
                  workspace.cameraBusy
                      ? 'Capturing NPC camera'
                      : 'Capture NPC camera',
                ),
                onPressed: workspace.cameraBusy || actor == null
                    ? null
                    : () async {
                        workspace.cameraBusy = true;
                        workspace.cameraError = null;
                        workspace.refresh();
                        try {
                          await workspace.captureCamera!();
                        } catch (error) {
                          workspace.cameraError = '$error';
                        } finally {
                          workspace.cameraBusy = false;
                          workspace.refresh();
                        }
                      },
              ),
            if (workspace.cameraError != null)
              ZeroState(
                title: 'NPC capture failed',
                message: workspace.cameraError!,
              ),
            const Text(
              'Semantic visibility uses Rapier queries. Rendered visibility uses the NPC camera.',
            ),
            if (profile != null) ...[
              SelectableText('Profile ${profile.hash}'),
              Text(
                'Range ${profile.range}m · cadence ${profile.cadenceTicks} ticks · catalog ${profile.maxCandidates} · ray budget ${profile.queryBudget}',
              ),
              const Text(
                'Unprobed catalog slots remain unknown. Hidden world state is not an observation.',
              ),
            ],
            if (observation == null)
              const ZeroState(
                title: 'NPC camera unavailable',
                message:
                    'Select an NPC with a completed native camera capture. Semantic visibility does not imply rendered pixels.',
              ),
            if (observation != null) ...[
              Text(
                'NPC ${observation.entity.id} · captured tick ${observation.receipt.tick} · frame ${observation.receipt.frameId}',
              ),
              GameCameraPreview(observation: observation),
              SelectableText(jsonEncode(observation.receipt.toJson())),
            ],
          ],
        ),
      );
    },
  );
}

class GameCameraPreview extends StatefulWidget {
  final CameraObservation observation;
  const GameCameraPreview({super.key, required this.observation});
  @override
  State<GameCameraPreview> createState() => _GameCameraPreviewState();
}

class _GameCameraPreviewState extends State<GameCameraPreview> {
  ui.Image? image;
  int epoch = 0;
  @override
  void initState() {
    super.initState();
    _decode();
  }

  @override
  void didUpdateWidget(GameCameraPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.observation, widget.observation)) _decode();
  }

  void _decode() {
    final serial = ++epoch;
    final receipt = widget.observation.receipt;
    ui.decodeImageFromPixels(
      Uint8List.fromList(receipt.image.pixels),
      receipt.width,
      receipt.height,
      ui.PixelFormat.rgba8888,
      (next) {
        if (!mounted || serial != epoch) {
          next.dispose();
          return;
        }
        final old = image;
        setState(() => image = next);
        old?.dispose();
      },
    );
  }

  @override
  void dispose() {
    epoch++;
    image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Rendered NPC camera at tick ${widget.observation.receipt.tick}',
    image: true,
    child: SizedBox(
      height: 160,
      child: image == null
          ? const Center(child: CircularProgressIndicator())
          : RawImage(image: image, fit: BoxFit.contain),
    ),
  );
}
