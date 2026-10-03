import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import '../studio_lighting.dart';
import 'settings.dart';

void main() => runApp(const StudioMockApp());

class StudioMockApp extends StatefulWidget {
  final bool nativeViewport;
  const StudioMockApp({super.key, this.nativeViewport = true});
  @override
  State<StudioMockApp> createState() => _StudioMockAppState();
}

class _StudioMockAppState extends State<StudioMockApp> {
  ThemeMode mode = ThemeMode.system;
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: studioTheme(Brightness.light),
    darkTheme: studioTheme(Brightness.dark),
    themeMode: mode,
    home: StudioMock(
      nativeViewport: widget.nativeViewport,
      themeMode: mode,
      onThemeChanged: (value) => setState(() => mode = value),
    ),
  );
}

class StudioMock extends StatefulWidget {
  final bool nativeViewport;
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeChanged;
  const StudioMock({
    super.key,
    required this.nativeViewport,
    required this.themeMode,
    required this.onThemeChanged,
  });
  @override
  State<StudioMock> createState() => _StudioMockState();
}

class _StudioMockState extends State<StudioMock> {
  StudioPalette get palette => StudioPalette.of(context);
  Color get paper => palette.panel;
  Color get ink => palette.text;
  Color get muted => palette.muted;
  Color get line => palette.border;
  Color get blue => palette.accent;
  Color get selectedFill => palette.selection;
  AgentProfile? agentProfile;
  bool exampleVisible = false;

  Future<void> _settings() async {
    final result = await showDialog<AgentProfile>(
      context: context,
      builder: (_) => StudioSettings(
        profile: agentProfile,
        themeMode: widget.themeMode,
        onThemeChanged: widget.onThemeChanged,
        narrowPreview: phonePreview,
      ),
    );
    if (result != null && mounted) setState(() => agentProfile = result);
  }

  final search = TextEditingController();
  final scene = Scene()..background = Color3.hex(0x283444);
  final parts = <String, Mesh>{};
  final camera = PerspectiveCamera(
    position: const Vec3(6.4, 4.6, 6.4),
    target: const Vec3(0, .6, 0),
    fieldOfView: .65,
  );
  SceneController? controller;
  String selection = 'Motor housing', tool = 'Move';
  bool expanded = true, playing = false;
  double time = 0;
  Timer? ticker;
  final notes = <String>['Check the clearance around the mounting feet.'];
  final noteInput = TextEditingController();
  final partColors = <String, int>{};
  int get color => partColors[selection] ?? 0x7e9cb2;
  bool phonePreview = false;
  (String?, String?, String?, double)? desktopLayout;
  void _togglePhone() => setState(() {
    if (!phonePreview) {
      desktopLayout = (leftPanel, rightPanel, bottomPanel, bottomHeight);
      phonePreview = true;
    } else {
      phonePreview = false;
      final previous = desktopLayout!;
      leftPanel = previous.$1;
      rightPanel = previous.$2;
      bottomPanel = previous.$3;
      bottomHeight = previous.$4;
    }
  });
  final prompt = TextEditingController();
  String? leftPanel = 'Scene', rightPanel = 'Agent', bottomPanel = 'Animation';
  final dockPositions = <String, String>{
    'Scene': 'left',
    'Assets': 'left',
    'Agent': 'right',
    'Properties': 'right',
    'Review': 'right',
    'Animation': 'bottom',
  };
  double leftWidth = 210, rightWidth = 300, bottomHeight = 140;
  bool applied = false, proposal = true;
  String request = 'Prepare an exploded view of the drive assembly.';

  @override
  void initState() {
    super.initState();
    _fixture();
    if (widget.nativeViewport) {
      controller = SceneController(
        scene: scene,
        camera: camera,
        runtime: Platform.isAndroid
            ? const SceneRuntime.nativeAndroid()
            : const SceneRuntime.nativeMetal(),
        options: const EngineOptions(
          presentation: PresentationPolicy.requireNative,
        ),
      )..use(OrbitControlsPlugin());
      controller!.status.addListener(_refresh);
    }
    _outline();
  }

  void _refresh() {
    if (!mounted) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    } else {
      setState(() {});
    }
  }

  void _fixture() {
    Mesh box(String name, Vec3 size, Vec3 position, int color) {
      final mesh = Mesh(
        BoxGeometry(width: size.x, height: size.y, depth: size.z),
        DiffuseMaterial(color: Color3.hex(color)),
        name: name,
      )..position = position;
      scene.add(mesh);
      parts[name] = mesh;
      partColors[name] = color;
      return mesh;
    }

    Mesh cylinder(
      String name,
      double radius,
      double length,
      Vec3 position,
      int color,
    ) {
      final mesh =
          Mesh(
              CylinderGeometry(
                radiusTop: radius,
                radiusBottom: radius,
                height: length,
                radialSegments: 64,
              ),
              DiffuseMaterial(color: Color3.hex(color)),
              name: name,
            )
            ..rotateZ(math.pi / 2)
            ..position = position;
      scene.add(mesh);
      parts[name] = mesh;
      partColors[name] = color;
      return mesh;
    }

    box(
      'Base plate',
      const Vec3(4.8, .22, 2.6),
      const Vec3(0, -.38, 0),
      0x647184,
    );
    box(
      'Motor feet',
      const Vec3(1.95, .35, 1.55),
      const Vec3(-.75, -.12, 0),
      0x92a5b5,
    );
    cylinder('Motor housing', .82, 2.1, const Vec3(-.7, .72, 0), color);
    cylinder('End shield', .9, .18, const Vec3(.4, .72, 0), 0xadc0ce);
    cylinder('Coupling', .42, .64, const Vec3(.84, .72, 0), 0xd0a365);
    cylinder('Drive shaft', .20, 1.2, const Vec3(1.55, .72, 0), 0xc3cdd4);
    box(
      'Terminal box',
      const Vec3(.95, .38, .72),
      const Vec3(-.75, 1.6, 0),
      0x8098ab,
    );
    for (var i = 0; i < 9; i++) {
      final ring =
          Mesh(
              TorusGeometry(radius: .83, tube: .032),
              DiffuseMaterial(color: Color3.hex(0x435e73)),
            )
            ..rotateY(math.pi / 2)
            ..position = Vec3(-1.57 + i * .2, .72, 0);
      scene.add(ring);
    }
    for (final x in [-1.95, 1.95]) {
      for (final z in [-.95, .95]) {
        scene.add(
          Mesh(
            CylinderGeometry(
              radiusTop: .12,
              radiusBottom: .12,
              height: .12,
              radialSegments: 6,
            ),
            DiffuseMaterial(color: Color3.hex(0xc7d3dd)),
          )..position = Vec3(x, -.2, z),
        );
      }
    }
    for (var n = -10; n <= 10; n++) {
      final material = UnlitMaterial(
        color: Color3.hex(n == 0 ? 0x51667b : 0x354457),
      );
      scene.add(
        Mesh(BoxGeometry(width: 20, height: .005, depth: .012), material)
          ..position = Vec3(0, -.53, n.toDouble()),
      );
      scene.add(
        Mesh(BoxGeometry(width: .012, height: .005, depth: 20), material)
          ..position = Vec3(n.toDouble(), -.53, 0),
      );
    }
    addStudioLighting(scene);
  }

  void _outline() {
    scene.outline = SceneOutline(
      objects: [parts[selection]!],
      color: Color3.hex(0x81a8ff),
      width: 2,
    );
  }

  void _select(String name) => setState(() {
    selection = name;
    _outline();
  });
  void _seek(double value) => setState(() {
    time = value;
    parts['End shield']!.position = Vec3(.4 + value * .13, .72, 0);
    parts['Coupling']!.position = Vec3(.84 + value * .22, .72, 0);
    parts['Drive shaft']!.position = Vec3(1.55 + value * .3, .72, 0);
  });
  void _play() {
    ticker?.cancel();
    setState(() => playing = !playing);
    if (playing) {
      ticker = Timer.periodic(
        const Duration(milliseconds: 50),
        (_) => _seek((time + .05) % 4),
      );
    }
  }

  void _message(String text) => ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(text),
      behavior: SnackBarBehavior.floating,
      width: MediaQuery.sizeOf(context).width > 500 ? 440 : null,
    ),
  );
  @override
  void dispose() {
    ticker?.cancel();
    search.dispose();
    noteInput.dispose();
    prompt.dispose();
    controller?.status.removeListener(_refresh);
    controller?.dispose();
    super.dispose();
  }

  Widget _icon(
    IconData icon,
    String label,
    VoidCallback action, {
    bool active = false,
    double size = 30,
  }) => Tooltip(
    message: label,
    child: IconButton(
      onPressed: action,
      style: IconButton.styleFrom(
        backgroundColor: active ? selectedFill : Colors.transparent,
        foregroundColor: active ? blue : muted,
        minimumSize: Size(size, size),
        maximumSize: Size(size, size),
        padding: const EdgeInsets.all(5),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      ),
      icon: Icon(icon, size: 16, semanticLabel: label),
    ),
  );
  Widget _button(
    String text,
    VoidCallback action, {
    bool primary = false,
    IconData? icon,
  }) => TextButton(
    onPressed: action,
    style: TextButton.styleFrom(
      foregroundColor: primary ? const Color(0xffe8eeff) : muted,
      backgroundColor: primary ? const Color(0xff385ca7) : Colors.transparent,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      minimumSize: const Size(32, 30),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[Icon(icon, size: 14), const SizedBox(width: 6)],
        Text(text, style: const TextStyle(fontSize: 11)),
      ],
    ),
  );
  Widget _label(
    String text, {
    Color? color,
    double size = 11,
    FontWeight weight = FontWeight.normal,
  }) => Text(
    text,
    overflow: TextOverflow.ellipsis,
    style: TextStyle(fontSize: size, color: color ?? muted, fontWeight: weight),
  );
  IconData _panelIcon(String panel) => switch (panel) {
    'Scene' => Icons.account_tree_outlined,
    'Assets' => Icons.inventory_2_outlined,
    'Agent' => Icons.auto_awesome_outlined,
    'Properties' => Icons.tune,
    'Review' => Icons.chat_bubble_outline,
    _ => Icons.view_timeline_outlined,
  };

  void _toggle(String panel, {bool narrow = false}) => setState(() {
    if (narrow) {
      bottomPanel = bottomPanel == panel ? null : panel;
      return;
    }
    switch (dockPositions[panel]) {
      case 'left':
        leftPanel = leftPanel == panel ? null : panel;
      case 'right':
        rightPanel = rightPanel == panel ? null : panel;
      default:
        bottomPanel = bottomPanel == panel ? null : panel;
    }
  });
  void _dock(String panel, String side) => setState(() {
    if (leftPanel == panel) leftPanel = null;
    if (rightPanel == panel) rightPanel = null;
    if (bottomPanel == panel) bottomPanel = null;
    dockPositions[panel] = side;
    if (side == 'bottom' && panel == 'Agent') {
      bottomHeight = math.max(bottomHeight, 300);
    }
    switch (side) {
      case 'left':
        leftPanel = panel;
      case 'right':
        rightPanel = panel;
      default:
        bottomPanel = panel;
    }
  });
  void _close(String panel) => setState(() {
    if (leftPanel == panel) leftPanel = null;
    if (rightPanel == panel) rightPanel = null;
    if (bottomPanel == panel) bottomPanel = null;
  });
  Widget _dropZone(String side, Widget child) => DragTarget<String>(
    onAcceptWithDetails: (details) => _dock(details.data, side),
    builder: (context, incoming, rejected) => DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(
          color: incoming.isEmpty ? Colors.transparent : blue,
          width: 1,
        ),
      ),
      child: child,
    ),
  );
  Widget _rail(List<String> panels, String side, bool narrow) => _dropZone(
    side,
    Container(
      width: 35,
      color: palette.chrome,
      child: Column(
        children: [
          const SizedBox(height: 5),
          for (final panel in panels)
            Padding(
              padding: const EdgeInsets.only(bottom: 5),
              child: _icon(
                _panelIcon(panel),
                '$panel tool window',
                () => _toggle(panel, narrow: narrow),
                active: narrow
                    ? bottomPanel == panel
                    : [leftPanel, rightPanel, bottomPanel].contains(panel),
              ),
            ),
          const Spacer(),
          if (side == 'right')
            _icon(
              phonePreview ? Icons.desktop_windows_outlined : Icons.smartphone,
              phonePreview
                  ? 'Return to desktop layout'
                  : 'Preview phone layout',
              _togglePhone,
            ),
          const SizedBox(height: 5),
        ],
      ),
    ),
  );
  Widget _resize(String side) => MouseRegion(
    cursor: side == 'bottom'
        ? SystemMouseCursors.resizeUpDown
        : SystemMouseCursors.resizeLeftRight,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanUpdate: (event) => setState(() {
        if (side == 'left') {
          leftWidth = (leftWidth + event.delta.dx).clamp(150, 360);
        }
        if (side == 'right') {
          rightWidth = (rightWidth - event.delta.dx).clamp(220, 420);
        }
        if (side == 'bottom') {
          bottomHeight = (bottomHeight - event.delta.dy).clamp(90, 420);
        }
      }),
      child: Container(
        width: side == 'bottom' ? null : 4,
        height: side == 'bottom' ? 4 : null,
        color: palette.chrome,
      ),
    ),
  );
  Widget _panel(String name, String side) => _dropZone(
    side,
    Material(
      color: paper,
      child: Column(
        children: [
          Container(
            height: 33,
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: line)),
            ),
            padding: const EdgeInsets.only(left: 10, right: 3),
            child: Row(
              children: [
                Expanded(
                  child: Draggable<String>(
                    data: name,
                    feedback: Material(
                      color: selectedFill,
                      borderRadius: BorderRadius.circular(4),
                      child: Padding(
                        padding: const EdgeInsets.all(10),
                        child: _label(name, color: ink),
                      ),
                    ),
                    child: MouseRegion(
                      cursor: SystemMouseCursors.grab,
                      child: Row(
                        children: [
                          Icon(_panelIcon(name), size: 13, color: muted),
                          const SizedBox(width: 7),
                          _label(name, color: ink, weight: FontWeight.w600),
                          if (name == 'Agent') ...[
                            const SizedBox(width: 7),
                            _label('Built-in', size: 10),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: 'Dock $name',
                  padding: EdgeInsets.zero,
                  icon: Icon(
                    Icons.more_horiz,
                    size: 16,
                    semanticLabel: 'Dock $name',
                  ),
                  constraints: const BoxConstraints(),
                  onSelected: (side) => _dock(name, side),
                  itemBuilder: (_) => [
                    for (final position
                        in (phonePreview ||
                                MediaQuery.sizeOf(context).width < 720)
                            ? ['bottom']
                            : ['left', 'right', 'bottom'])
                      PopupMenuItem(
                        value: position,
                        child: Text(
                          'Dock $position',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                  ],
                ),
                _icon(Icons.remove, 'Hide $name', () => _close(name)),
              ],
            ),
          ),
          Expanded(
            child: switch (name) {
              'Scene' => _tree(),
              'Assets' => _assets(),
              'Agent' => _agent(),
              'Properties' => _properties(),
              'Review' => _review(),
              _ => _timeline(),
            },
          ),
        ],
      ),
    ),
  );

  Widget _header(bool narrow) => Container(
    height: 40,
    color: palette.chrome,
    padding: const EdgeInsets.symmetric(horizontal: 10),
    child: Row(
      children: [
        Container(
          width: 22,
          height: 22,
          decoration: BoxDecoration(
            color: const Color(0xff486ba8),
            borderRadius: BorderRadius.circular(5),
          ),
          child: Icon(Icons.view_in_ar, size: 15, color: Colors.white),
        ),
        const SizedBox(width: 9),
        if (!narrow) ...[
          _label('Zyren Studio', color: ink, weight: FontWeight.w600),
          const SizedBox(width: 16),
          Container(width: 1, height: 16, color: line),
          const SizedBox(width: 16),
        ],
        Expanded(
          child: _label('Drive assembly', color: ink, weight: FontWeight.w500),
        ),
        _icon(Icons.settings_outlined, 'Settings', _settings),
        _label('UI mock', size: 10),
        const SizedBox(width: 12),
        _icon(
          Icons.save_outlined,
          'Save preview',
          () => _message('This UI mock keeps changes in the preview session.'),
        ),
      ],
    ),
  );
  Widget _editor() => Column(
    children: [
      Container(
        height: 34,
        color: palette.chrome,
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              height: 34,
              decoration: BoxDecoration(
                color: palette.raised,
                border: Border(bottom: BorderSide(color: blue, width: 2)),
              ),
              child: Row(
                children: [
                  Icon(Icons.view_in_ar_outlined, size: 13, color: blue),
                  const SizedBox(width: 7),
                  _label('drive.zyren', color: ink),
                  const SizedBox(width: 16),
                  if (time > 0)
                    Icon(Icons.circle, size: 6, color: blue)
                  else
                    Icon(Icons.close, size: 12, color: muted),
                ],
              ),
            ),
            const Spacer(),
            _icon(Icons.center_focus_strong, 'Reset camera', () {
              camera.position = const Vec3(6.4, 4.6, 6.4);
              camera.target = const Vec3(0, .6, 0);
            }),
          ],
        ),
      ),
      Container(
        height: 33,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        color: palette.raised,
        child: Row(
          children: [
            for (final entry in [
              ('Select', Icons.near_me_outlined),
              ('Move', Icons.open_with),
              ('Rotate', Icons.rotate_right),
              ('Scale', Icons.aspect_ratio),
            ])
              _icon(
                entry.$2,
                '${entry.$1} tool placement',
                () => setState(() => tool = entry.$1),
                active: tool == entry.$1,
                size: 27,
              ),
            const SizedBox(width: 10),
            Container(width: 1, height: 14, color: line),
            const SizedBox(width: 10),
            _label('Local', size: 10),
            const Spacer(),
            PopupMenuButton<String>(
              tooltip: 'Camera view',
              onSelected: (value) {
                camera.position = switch (value) {
                  'Top' => const Vec3(.01, 9, .01),
                  'Front' => const Vec3(0, .7, 9),
                  _ => const Vec3(6.4, 4.6, 6.4),
                };
                camera.target = const Vec3(0, .6, 0);
              },
              itemBuilder: (_) => [
                for (final view in ['Perspective', 'Top', 'Front'])
                  PopupMenuItem(value: view, child: Text(view)),
              ],
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: Row(
                  children: [
                    _label('View', size: 10),
                    Icon(Icons.expand_more, size: 13),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      Expanded(
        child: Stack(
          children: [
            Positioned.fill(
              child: controller == null
                  ? const ColoredBox(color: Color(0xff283444))
                  : SceneView(controller: controller!),
            ),
            Positioned(
              top: 12,
              left: 13,
              child: IgnorePointer(
                child: _label(
                  selection,
                  color: const Color(0xffb5c1cf),
                  size: 11,
                ),
              ),
            ),
            Positioned(
              bottom: 11,
              left: 13,
              child: IgnorePointer(
                child: _label(
                  'Orbit: drag    Zoom: scroll',
                  color: const Color(0xff8190a2),
                  size: 10,
                ),
              ),
            ),
            Positioned(
              bottom: 11,
              right: 12,
              child: IgnorePointer(
                child: Row(
                  children: [
                    _label('X', color: const Color(0xffc58383), size: 10),
                    const SizedBox(width: 8),
                    _label('Y', color: const Color(0xff8ebfa2), size: 10),
                    const SizedBox(width: 8),
                    _label('Z', color: const Color(0xff8aa8ff), size: 10),
                  ],
                ),
              ),
            ),
            if (controller?.status.value case SceneFailed(:final issue))
              Positioned.fill(
                child: Material(
                  color: paper,
                  child: ZeroState(
                    title: 'Native preview unavailable',
                    message: issue.message,
                  ),
                ),
              ),
          ],
        ),
      ),
    ],
  );
  Widget _tree() {
    final filtered = parts.keys
        .where((name) => name.toLowerCase().contains(search.text.toLowerCase()))
        .toList();
    return Column(
      children: [
        SizedBox(
          height: 34,
          child: TextField(
            controller: search,
            onChanged: (_) => setState(() {}),
            style: const TextStyle(fontSize: 11),
            decoration: InputDecoration(
              hintText: 'Filter objects',
              prefixIcon: Icon(Icons.search, size: 14),
              fillColor: paper,
              contentPadding: EdgeInsets.zero,
            ),
          ),
        ),
        Expanded(
          child: filtered.isEmpty
              ? ZeroState(
                  title: 'No matching objects',
                  message: 'Try another name.',
                  actionLabel: 'Clear filter',
                  onAction: () => setState(search.clear),
                )
              : ListView(
                  children: [
                    InkWell(
                      onTap: () => setState(() => expanded = !expanded),
                      child: SizedBox(
                        height: 29,
                        child: Row(
                          children: [
                            const SizedBox(width: 8),
                            Icon(
                              expanded
                                  ? Icons.expand_more
                                  : Icons.chevron_right,
                              size: 15,
                            ),
                            const SizedBox(width: 4),
                            Icon(Icons.layers_outlined, size: 13, color: muted),
                            const SizedBox(width: 7),
                            _label(
                              'Drive assembly',
                              color: ink,
                              weight: FontWeight.w500,
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (expanded || search.text.isNotEmpty)
                      for (final name in filtered)
                        Material(
                          color: selection == name
                              ? selectedFill
                              : Colors.transparent,
                          child: Row(
                            children: [
                              Expanded(
                                child: Semantics(
                                  button: true,
                                  selected: selection == name,
                                  child: InkWell(
                                    onTap: () => _select(name),
                                    child: SizedBox(
                                      height: 28,
                                      child: Row(
                                        children: [
                                          const SizedBox(width: 24),
                                          Icon(
                                            Icons.view_in_ar_outlined,
                                            size: 12,
                                            color: selection == name
                                                ? blue
                                                : muted,
                                          ),
                                          const SizedBox(width: 7),
                                          Expanded(
                                            child: _label(
                                              name,
                                              color: selection == name
                                                  ? ink
                                                  : ink,
                                              size: 11,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              _icon(
                                parts[name]!.visible
                                    ? Icons.visibility_outlined
                                    : Icons.visibility_off_outlined,
                                'Toggle $name visibility',
                                () => setState(
                                  () => parts[name]!.visible =
                                      !parts[name]!.visible,
                                ),
                                size: 24,
                              ),
                            ],
                          ),
                        ),
                  ],
                ),
        ),
        Container(
          height: 27,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: line)),
          ),
          child: Row(
            children: [
              _label('${parts.length} sample parts', size: 10),
              const Spacer(),
              _icon(Icons.add, 'Add sample box', _addPart, size: 24),
            ],
          ),
        ),
      ],
    );
  }

  void _addPart() => setState(() {
    final name = 'Box ${parts.length - 6}';
    final mesh = Mesh(
      BoxGeometry(width: .5, height: .5, depth: .5),
      DiffuseMaterial(color: Color3.hex(0x91a9bf)),
      name: name,
    )..position = const Vec3(0, 2.4, 0);
    parts[name] = mesh;
    partColors[name] = 0x91a9bf;
    scene.add(mesh);
    selection = name;
    expanded = true;
    search.clear();
    _outline();
  });
  Widget _assets() => ListView(
    padding: const EdgeInsets.all(9),
    children: [
      _label('Sample library', size: 10),
      const SizedBox(height: 8),
      for (final entry in [
        ('Drive assembly', Icons.precision_manufacturing_outlined),
        ('Machined steel', Icons.circle_outlined),
        ('Warm anodized', Icons.circle),
      ])
        ListTile(
          dense: true,
          minLeadingWidth: 14,
          contentPadding: const EdgeInsets.symmetric(horizontal: 4),
          leading: Icon(entry.$2, size: 15, color: blue),
          title: _label(entry.$1, color: ink),
          onTap: () => _message('${entry.$1} is a UI fixture.'),
        ),
      _button(
        'Import asset',
        () => _message(
          'Import is a proposed entry point. Use the existing editor for file imports.',
        ),
        icon: Icons.add,
      ),
    ],
  );

  Widget _agent() => LayoutBuilder(
    builder: (context, constraints) => constraints.maxHeight < 220
        ? SingleChildScrollView(
            child: SizedBox(height: 360, child: _agentContent()),
          )
        : _agentContent(),
  );
  Widget _agentContent() => Column(
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(9, 4, 4, 4),
        child: Row(
          children: [
            Icon(Icons.tune, size: 13, color: muted),
            const SizedBox(width: 6),
            Expanded(
              child: _label(
                agentProfile?.model ?? 'Choose your model',
                color: ink,
              ),
            ),
            _label(
              agentProfile == null ? 'Not configured' : 'Unverified',
              size: 10,
            ),
            _icon(Icons.settings_outlined, 'Agent settings', _settings),
          ],
        ),
      ),
      const Divider(),
      Container(
        padding: const EdgeInsets.all(9),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: line)),
        ),
        child: Row(
          children: [
            Icon(Icons.attach_file, size: 13),
            const SizedBox(width: 5),
            Expanded(child: _label('drive.zyren / $selection', size: 10)),
          ],
        ),
      ),
      Expanded(
        child: !exampleVisible
            ? ZeroState(
                title: agentProfile == null
                    ? 'Configure your agent'
                    : 'Start with your scene',
                message: agentProfile == null
                    ? 'Studio provides the agent workspace and scene tools. Choose your LLM in Settings.'
                    : 'Your model profile is saved for this preview. Live requests are not connected in this UI mock.',
                action: Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    _button(
                      agentProfile == null ? 'Configure LLM' : 'Edit model',
                      _settings,
                      primary: true,
                      icon: Icons.settings_outlined,
                    ),
                    _button(
                      'Try example',
                      () => setState(() => exampleVisible = true),
                    ),
                  ],
                ),
              )
            : ListView(
                padding: const EdgeInsets.all(12),
                children: [
                  _label('Example request', size: 10),
                  const SizedBox(height: 7),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: palette.raised,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      request,
                      style: const TextStyle(fontSize: 12, height: 1.5),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      Icon(Icons.auto_awesome_outlined, size: 14, color: blue),
                      const SizedBox(width: 7),
                      _label(
                        'Agent preview',
                        color: ink,
                        weight: FontWeight.w600,
                      ),
                    ],
                  ),
                  const SizedBox(height: 9),
                  Text(
                    'Separate the end shield, coupling and shaft. Keep the base and motor in place.',
                    style: TextStyle(fontSize: 12, height: 1.6, color: muted),
                  ),
                  const SizedBox(height: 14),
                  if (proposal)
                    Container(
                      decoration: BoxDecoration(
                        border: Border.all(color: line),
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Padding(
                            padding: const EdgeInsets.all(10),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.difference_outlined,
                                  size: 14,
                                  color: blue,
                                ),
                                const SizedBox(width: 7),
                                Expanded(
                                  child: _label(
                                    applied
                                        ? 'Applied to preview'
                                        : '3 proposed changes',
                                    color: ink,
                                    weight: FontWeight.w500,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const Divider(),
                          for (final edit in [
                            ('End shield', '+0.26'),
                            ('Coupling', '+0.44'),
                            ('Drive shaft', '+0.60'),
                          ])
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 7,
                              ),
                              child: Row(
                                children: [
                                  Expanded(child: _label(edit.$1)),
                                  _label(
                                    'X ${edit.$2}',
                                    color: palette.positive,
                                    size: 10,
                                  ),
                                ],
                              ),
                            ),
                          const Divider(),
                          Padding(
                            padding: const EdgeInsets.all(7),
                            child: Wrap(
                              spacing: 4,
                              children: [
                                if (!applied)
                                  _button(
                                    'Apply preview',
                                    () {
                                      _seek(2);
                                      setState(() => applied = true);
                                    },
                                    primary: true,
                                    icon: Icons.check,
                                  )
                                else
                                  _button('Undo', () {
                                    _seek(0);
                                    setState(() => applied = false);
                                  }, icon: Icons.undo),
                                _button('Discard', () {
                                  if (applied) _seek(0);
                                  setState(() {
                                    proposal = false;
                                    applied = false;
                                  });
                                }),
                              ],
                            ),
                          ),
                        ],
                      ),
                    )
                  else
                    _button(
                      'Show example proposal',
                      () => setState(() => proposal = true),
                      icon: Icons.add,
                    ),
                  const SizedBox(height: 12),
                  Text(
                    'Example response. No LLM request sent.',
                    style: TextStyle(fontSize: 10, color: muted),
                  ),
                ],
              ),
      ),
      if (exampleVisible)
        Container(
          margin: const EdgeInsets.all(9),
          decoration: BoxDecoration(
            color: palette.raised,
            border: Border.all(color: line),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Column(
            children: [
              TextField(
                controller: prompt,
                minLines: 2,
                maxLines: 3,
                style: const TextStyle(fontSize: 12),
                decoration: InputDecoration(
                  hintText: agentProfile == null
                      ? 'Configure your LLM to start…'
                      : 'Ask about this scene…',
                  filled: false,
                  contentPadding: EdgeInsets.all(10),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(5, 0, 5, 5),
                child: Row(
                  children: [
                    _icon(Icons.add, 'Include selected object', () {
                      prompt.text = 'Explain $selection in this assembly';
                    }),
                    Expanded(
                      child: _label('Review changes before applying', size: 10),
                    ),
                    _icon(Icons.arrow_upward, 'Preview agent request', () {
                      if (agentProfile == null) {
                        _settings();
                        return;
                      }
                      if (prompt.text.trim().isEmpty) return;
                      if (applied) _seek(0);
                      setState(() {
                        request = prompt.text.trim();
                        exampleVisible = true;
                        proposal = true;
                        applied = false;
                        prompt.clear();
                      });
                    }, active: true),
                  ],
                ),
              ),
            ],
          ),
        ),
    ],
  );
  Widget _section(String title, List<Widget> children) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 12, 12, 11),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.expand_more, size: 13),
            const SizedBox(width: 5),
            _label(title, color: ink, weight: FontWeight.w600),
          ],
        ),
        const SizedBox(height: 12),
        ...children,
      ],
    ),
  );
  Widget _properties() => ListView(
    children: [
      Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Icon(Icons.view_in_ar_outlined, color: blue, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: _label(selection, color: ink, weight: FontWeight.w600),
            ),
          ],
        ),
      ),
      const Divider(),
      _section('Transform', [
        _vector(
          'Position',
          parts[selection]!.position,
          (v) => setState(() => parts[selection]!.position = v),
        ),
        const SizedBox(height: 9),
        _vector('Scale', parts[selection]!.scale, (v) {
          if (v.x > 0 && v.y > 0 && v.z > 0) {
            setState(() => parts[selection]!.scale = v);
          }
        }),
        const SizedBox(height: 7),
        Row(
          children: [
            _label('Visible'),
            const Spacer(),
            SizedBox(
              height: 25,
              child: Switch(
                value: parts[selection]!.visible,
                onChanged: (v) => setState(() => parts[selection]!.visible = v),
              ),
            ),
          ],
        ),
      ]),
      const Divider(),
      _section('Material', [
        Row(
          children: [
            Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: Color(0xff000000 | color),
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 9),
            _label('Satin finish', color: ink),
          ],
        ),
        const SizedBox(height: 11),
        Wrap(
          spacing: 7,
          children: [
            for (final value in [
              0x7e9cb2,
              0xc3cdd4,
              0xd0a365,
              0x57616f,
              0x7d9c8b,
            ])
              Semantics(
                label: 'Material color ${value.toRadixString(16)}',
                button: true,
                selected: color == value,
                child: InkWell(
                  onTap: () => setState(() {
                    partColors[selection] = value;
                    parts[selection]!.material = DiffuseMaterial(
                      color: Color3.hex(value),
                    );
                  }),
                  child: Container(
                    width: 25,
                    height: 25,
                    decoration: BoxDecoration(
                      color: Color(0xff000000 | value),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(
                        color: color == value ? blue : line,
                        width: color == value ? 2 : 1,
                      ),
                    ),
                    child: color == value
                        ? Icon(Icons.check, size: 13, color: Colors.white)
                        : null,
                  ),
                ),
              ),
          ],
        ),
      ]),
      const Divider(),
      _section('Source', [
        _detail('Type', 'Primitive mesh'),
        _detail('Origin', 'Local sample'),
        _detail('Storage', 'Preview session'),
      ]),
      const Divider(),
      Padding(
        padding: const EdgeInsets.all(8),
        child: _button(
          'Frame selected',
          () => camera.target = parts[selection]!.position,
          icon: Icons.center_focus_weak,
        ),
      ),
    ],
  );
  Widget _detail(String title, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      children: [
        _label(title),
        const Spacer(),
        _label(value, color: ink),
      ],
    ),
  );
  Widget _vector(String title, Vec3 value, ValueChanged<Vec3> update) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _label(title, size: 10),
      const SizedBox(height: 5),
      Row(
        children: [
          for (var i = 0; i < 3; i++)
            Expanded(
              child: Padding(
                padding: EdgeInsets.only(right: i == 2 ? 0 : 4),
                child: TextFormField(
                  key: ValueKey(
                    '$selection-$title-$i-${[value.x, value.y, value.z][i]}',
                  ),
                  initialValue: [
                    value.x,
                    value.y,
                    value.z,
                  ][i].toStringAsFixed(2),
                  style: const TextStyle(fontSize: 11),
                  decoration: InputDecoration(
                    fillColor: palette.raised,
                    prefixText: '${['X', 'Y', 'Z'][i]} ',
                    prefixStyle: TextStyle(
                      fontSize: 10,
                      color: [
                        const Color(0xffc58383),
                        const Color(0xff8ebfa2),
                        blue,
                      ][i],
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 8,
                    ),
                  ),
                  onFieldSubmitted: (text) {
                    final n = double.tryParse(text);
                    if (n == null || !n.isFinite || n.abs() > 100) return;
                    final values = [value.x, value.y, value.z];
                    values[i] = n;
                    update(Vec3(values[0], values[1], values[2]));
                  },
                ),
              ),
            ),
        ],
      ),
    ],
  );
  Widget _review() => ListView(
    padding: const EdgeInsets.all(12),
    children: [
      _label('Preview notes', size: 10),
      const SizedBox(height: 12),
      for (final note in notes)
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Text(note, style: const TextStyle(fontSize: 12, height: 1.6)),
        ),
      TextField(
        controller: noteInput,
        maxLines: 3,
        style: const TextStyle(fontSize: 12),
        decoration: InputDecoration(
          hintText: 'Add a note',
          fillColor: palette.raised,
        ),
      ),
      const SizedBox(height: 8),
      Align(
        alignment: Alignment.centerRight,
        child: _button('Add note', () {
          if (noteInput.text.trim().isNotEmpty) {
            setState(() {
              notes.add(noteInput.text.trim());
              noteInput.clear();
            });
          }
        }),
      ),
    ],
  );
  Widget _timeline() => ListView(
    padding: const EdgeInsets.symmetric(horizontal: 10),
    children: [
      SizedBox(
        height: 31,
        child: Row(
          children: [
            _icon(
              playing ? Icons.pause : Icons.play_arrow,
              playing ? 'Pause preview' : 'Play preview',
              _play,
              size: 25,
            ),
            const SizedBox(width: 5),
            Expanded(child: _label('Exploded assembly')),
            _label('${time.toStringAsFixed(2)} / 4.00 s', size: 10),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [for (var n = 0; n <= 4; n++) _label('${n}s', size: 9)],
        ),
      ),
      SizedBox(
        height: 25,
        child: SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 2,
            activeTrackColor: blue,
            thumbColor: blue,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 4),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 9),
          ),
          child: Slider(
            value: time,
            max: 4,
            onChanged: _seek,
            semanticFormatterCallback: (v) => '${v.toStringAsFixed(2)} seconds',
          ),
        ),
      ),
      Container(
        height: 20,
        margin: const EdgeInsets.symmetric(horizontal: 8),
        padding: const EdgeInsets.symmetric(horizontal: 7),
        decoration: BoxDecoration(
          color: selectedFill,
          borderRadius: BorderRadius.circular(2),
        ),
        child: Row(
          children: [
            Icon(Icons.diamond_outlined, size: 9, color: blue),
            const SizedBox(width: 7),
            _label('Pose', color: blue, size: 10),
            const Spacer(),
            Icon(Icons.diamond, size: 8, color: blue),
          ],
        ),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: palette.chrome,
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: phonePreview ? 396 : double.infinity,
            maxHeight: phonePreview ? 844 : 900,
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final narrow = constraints.maxWidth < 720;
              final left = leftWidth
                  .clamp(150, math.max(150.0, constraints.maxWidth * .24))
                  .toDouble();
              final right = rightWidth
                  .clamp(220, math.max(220.0, constraints.maxWidth * .36))
                  .toDouble();
              final bottom = narrow
                  ? math.min(
                      bottomPanel == 'Animation' ? 140.0 : 330.0,
                      constraints.maxHeight * .47,
                    )
                  : math.min(bottomHeight, constraints.maxHeight * .5);
              return Column(
                children: [
                  _header(narrow),
                  const Divider(),
                  Expanded(
                    child: Row(
                      children: [
                        _rail(['Scene', 'Assets', 'Animation'], 'left', narrow),
                        if (!narrow && leftPanel != null) ...[
                          SizedBox(
                            width: left,
                            child: _panel(leftPanel!, 'left'),
                          ),
                          _resize('left'),
                        ],
                        Expanded(
                          child: Column(
                            children: [
                              Expanded(child: _editor()),
                              if (bottomPanel != null) ...[
                                _resize('bottom'),
                                SizedBox(
                                  height: bottom,
                                  child: _panel(bottomPanel!, 'bottom'),
                                ),
                              ] else
                                _dropZone(
                                  'bottom',
                                  SizedBox(
                                    height: 24,
                                    child: Align(
                                      alignment: Alignment.centerLeft,
                                      child: _button(
                                        'Animation',
                                        () => _toggle(
                                          'Animation',
                                          narrow: narrow,
                                        ),
                                        icon: Icons.view_timeline_outlined,
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        if (!narrow && rightPanel != null) ...[
                          _resize('right'),
                          SizedBox(
                            width: right,
                            child: _panel(rightPanel!, 'right'),
                          ),
                        ],
                        _rail(
                          ['Agent', 'Properties', 'Review'],
                          'right',
                          narrow,
                        ),
                      ],
                    ),
                  ),
                  Container(
                    height: 22,
                    padding: const EdgeInsets.symmetric(horizontal: 9),
                    color: palette.chrome,
                    child: Row(
                      children: [
                        Icon(Icons.circle, size: 5, color: Color(0xff91ad99)),
                        const SizedBox(width: 6),
                        _label('Local preview', size: 10),
                        if (!narrow) ...[
                          const SizedBox(width: 16),
                          _label(selection, size: 10),
                        ],
                        const Spacer(),
                        _label(
                          controller?.status.value is SceneReady
                              ? 'Native'
                              : 'Preparing viewport',
                          size: 10,
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    ),
  );
}
