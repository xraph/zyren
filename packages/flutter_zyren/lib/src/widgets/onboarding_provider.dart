import 'package:flutter/material.dart';

/// A registered step resolves its live anchor after optional route preparation.
class WalkthroughStep {
  final GlobalKey anchor;
  final String title, message;
  final Future<void> Function()? prepare;
  const WalkthroughStep({
    required this.anchor,
    required this.title,
    required this.message,
    this.prepare,
  });
}

class OnboardingProvider extends InheritedWidget {
  final Map<String, List<WalkthroughStep>> walkthroughs;
  OnboardingProvider({
    super.key,
    required Map<String, List<WalkthroughStep>> walkthroughs,
    required super.child,
  }) : walkthroughs = Map.unmodifiable(
         walkthroughs.map(
           (key, value) =>
               MapEntry(key, List<WalkthroughStep>.unmodifiable(value)),
         ),
       );

  static OnboardingProvider of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<OnboardingProvider>()!;

  Future<void> start(BuildContext context, String id) async {
    final steps = walkthroughs[id];
    if (steps == null || steps.isEmpty) {
      throw StateError('Walkthrough is not registered: $id');
    }
    await showDialog<void>(
      context: context,
      useSafeArea: false,
      builder: (_) => _Walkthrough(steps),
    );
  }

  @override
  bool updateShouldNotify(OnboardingProvider oldWidget) =>
      walkthroughs != oldWidget.walkthroughs;
}

class _Walkthrough extends StatefulWidget {
  final List<WalkthroughStep> steps;
  const _Walkthrough(this.steps);
  @override
  State<_Walkthrough> createState() => _WalkthroughState();
}

class _WalkthroughState extends State<_Walkthrough> {
  int _index = 0;
  Rect? _rect;
  String? _error;
  bool _loading = true;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _show(0));
  }

  Future<void> _show(int index) async {
    setState(() {
      _loading = true;
      _error = null;
      _rect = null;
    });
    try {
      final step = widget.steps[index];
      await step.prepare?.call();
      if (!mounted) return;
      final anchor = step.anchor.currentContext;
      if (anchor == null) {
        throw StateError('This step is unavailable on the current page.');
      }
      await Scrollable.ensureVisible(anchor, alignment: .5);
      if (!mounted) return;
      if (!anchor.mounted) {
        throw StateError('Walkthrough target left the page.');
      }
      final box = anchor.findRenderObject();
      if (box is! RenderBox || !box.hasSize) {
        throw StateError('Walkthrough target is not laid out.');
      }
      setState(() {
        _index = index;
        _rect = box.localToGlobal(Offset.zero) & box.size;
      });
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      if (_rect case final rect?)
        Positioned.fromRect(
          rect: rect,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(
                  color: Theme.of(context).colorScheme.primary,
                  width: 3,
                ),
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
        ),
      Align(
        alignment: Alignment.bottomCenter,
        child: AlertDialog(
          title: Text(widget.steps[_index].title),
          content: SingleChildScrollView(
            child: Text(_error ?? widget.steps[_index].message),
          ),
          actions: [
            Text('${_index + 1} / ${widget.steps.length}'),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close tour'),
            ),
            if (_index > 0)
              TextButton(
                onPressed: _loading ? null : () => _show(_index - 1),
                child: const Text('Back'),
              ),
            TextButton(
              onPressed: _loading || _error != null
                  ? null
                  : () {
                      if (_index + 1 == widget.steps.length) {
                        Navigator.pop(context);
                      } else {
                        _show(_index + 1);
                      }
                    },
              child: Text(
                _index + 1 == widget.steps.length ? 'Finish tour' : 'Next',
              ),
            ),
          ],
        ),
      ),
    ],
  );
}
