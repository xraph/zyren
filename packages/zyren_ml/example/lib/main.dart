import 'dart:convert';
import 'package:flutter/material.dart';
import 'probe.dart';

void main() => runApp(const ProbeApp());

class ProbeApp extends StatelessWidget {
  const ProbeApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Native ML probe',
    theme: ThemeData(colorSchemeSeed: Colors.teal),
    home: const ProbePage(),
  );
}

class ProbePage extends StatefulWidget {
  const ProbePage({super.key});
  @override
  State<ProbePage> createState() => _ProbePageState();
}

class _ProbePageState extends State<ProbePage> {
  bool running = false;
  String status =
      'Run local authored fixtures through the native CPU provider.';
  Future<void> run() async {
    setState(() {
      running = true;
      status = 'Starting native worker';
    });
    try {
      final receipt = await runNativeProbe(
        progress: (value) {
          if (mounted) setState(() => status = value);
        },
      );
      if (mounted) {
        setState(
          () => status = const JsonEncoder.withIndent('  ').convert(receipt),
        );
      }
    } catch (error) {
      if (mounted) setState(() => status = 'Probe failed: $error');
    } finally {
      if (mounted) setState(() => running = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Native ML qualification')),
    body: SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            FilledButton(
              onPressed: running ? null : run,
              child: const Text('Run native probes'),
            ),
            const SizedBox(height: 8),
            SelectableText(status),
          ],
        ),
      ),
    ),
  );
}
