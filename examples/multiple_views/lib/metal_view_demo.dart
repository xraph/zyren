import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'experimental/metal_proof_view.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await connectMetalProof();
  runApp(const MaterialApp(home: MetalProofDemo()));
}

class MetalProofDemo extends StatefulWidget {
  const MetalProofDemo({super.key});
  @override
  State<MetalProofDemo> createState() => _MetalProofDemoState();
}

class _MetalProofDemoState extends State<MetalProofDemo> {
  final packets = cornerPackets();
  Timer? timer;
  String status = 'Starting Metal views';
  bool shown = true;
  int generation = 0;
  @override
  void initState() {
    super.initState();
    timer = Timer.periodic(const Duration(seconds: 1), (_) async {
      final stats = await metalProofDiagnostics();
      if (mounted) {
        setState(
          () => status =
              '${stats['frames']} frames · ${stats['renderers']} renderers · ${stats['readbackBytes']} readback bytes',
        );
      }
    });
    if (const bool.fromEnvironment('METAL_PROOF_SMOKE')) unawaited(_smoke());
  }

  Future<void> _smoke() async {
    await Future<void>.delayed(const Duration(seconds: 8));
    final running = await metalProofDiagnostics();
    final passed =
        (running['frames'] as int) > 120 &&
        running['renderers'] == 2 &&
        running['errors'] == 0 &&
        running['readbackBytes'] == 0;
    if (mounted) setState(() => shown = false);
    for (var i = 0; i < 50; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final closed = await metalProofDiagnostics();
      if (closed['renderers'] == 0 &&
          closed['drawables'] == 0 &&
          closed['retiring'] == 0 &&
          closed['sessions'] == 0) {
        // Used by the standalone release smoke command in the checkpoint docs.
        // ignore: avoid_print
        print(
          'METAL_PROOF_SMOKE ${passed ? 'PASS' : 'FAIL'} running=$running closed=$closed',
        );
        exit(passed ? 0 : 1);
      }
    }
    // ignore: avoid_print
    print('METAL_PROOF_SMOKE FAIL: teardown did not release ownership');
    exit(1);
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  Widget composed(Widget child) => ColoredBox(
    color: Colors.yellow,
    child: ClipRRect(
      borderRadius: BorderRadius.circular(30),
      child: Transform.rotate(
        angle: .12,
        child: Opacity(opacity: .5, child: child),
      ),
    ),
  );
  Widget reference() => LayoutBuilder(
    builder: (_, size) => Stack(
      children: [
        const Positioned.fill(
          child: Column(
            children: [
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: ColoredBox(color: Color(0xffff0000))),
                    Expanded(child: ColoredBox(color: Color(0xff00ff00))),
                  ],
                ),
              ),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: ColoredBox(color: Color(0xff0000ff))),
                    Expanded(child: ColoredBox(color: Color(0xffffffff))),
                  ],
                ),
              ),
            ],
          ),
        ),
        Center(
          child: SizedBox(
            width: size.maxWidth * .2,
            height: size.maxHeight * .2,
            child: const ColoredBox(color: Color(0xff808080)),
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Native Metal proof'),
      actions: [
        TextButton(
          onPressed: () => setState(() {
            shown = !shown;
            generation++;
          }),
          child: Text(shown ? 'Remove' : 'Restore'),
        ),
      ],
    ),
    body: SafeArea(
      child: Column(
        children: [
          Padding(padding: const EdgeInsets.all(12), child: Text(status)),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              'The left column renders in Rust. Compare its colors, opacity, rotation and clipping with Flutter on the right.',
            ),
          ),
          if (shown)
            Expanded(
              child: LayoutBuilder(
                builder: (_, constraints) {
                  final side = ((constraints.maxWidth - 40) / 2).clamp(
                    64.0,
                    230.0,
                  );
                  Widget tile(Widget child) =>
                      SizedBox(width: side, height: side, child: child);
                  return Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            tileLabel(side, 'Native Metal'),
                            const SizedBox(width: 16),
                            tileLabel(side, 'Flutter reference'),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            tile(
                              MetalProofView(
                                key: ValueKey('plain-$generation'),
                                packets: packets,
                              ),
                            ),
                            const SizedBox(width: 16),
                            tile(reference()),
                          ],
                        ),
                        const SizedBox(height: 24),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            tile(
                              composed(
                                MetalProofView(
                                  key: ValueKey('composed-$generation'),
                                  packets: packets,
                                ),
                              ),
                            ),
                            const SizedBox(width: 16),
                            tile(composed(reference())),
                          ],
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    ),
  );
  Widget tileLabel(double width, String label) => SizedBox(
    width: width,
    child: Text(label, textAlign: TextAlign.center),
  );
}
