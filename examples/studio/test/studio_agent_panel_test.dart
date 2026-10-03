import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_agents/workflow.dart';
import 'package:zyren_studio/zyren_studio.dart';
import 'package:zyren_studio/modeling_agents.dart';
import 'package:zyren_studio_example/studio_agent_panel.dart';
import 'package:zyren_studio_example/studio_theme.dart';

class ModelingModel implements AgentModel {
  final AgentRegistry registry;
  int step = 0;
  ModelingModel(this.registry);
  @override
  Future<AgentReply> complete({
    required List<Map<String, Object?>> messages,
    required List<Map<String, Object?>> tools,
    required AgentCancellation cancellation,
  }) async {
    if (step++ > 0) return AgentReply(text: 'Sphere created.');
    final p = (registry.discover()['providers'] as List).single as Map;
    return AgentReply(
      calls: [
        AgentToolCall('create', 'call_tool', {
          'providerId': p['providerId'],
          'instanceId': p['instanceId'],
          'registrationId': p['registrationId'],
          'expectedRevision': p['revision'],
          'tool': 'create_nodes',
          'arguments': {
            'nodes': [
              {'id': 'sphere', 'kind': 'sphere'},
            ],
          },
        }),
      ],
    );
  }

  @override
  void close() {}
}

void main() {
  for (final size in [
    const Size(1280, 800),
    const Size(396, 844),
    const Size(328, 744),
  ]) {
    testWidgets(
      'configure, review and execute a real modeling tool at ${size.width}',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final scene = StudioScene(
          StudioDocument(id: 'test', title: 'Test', nodes: []),
        );
        final registry = AgentRegistry(grantedScopes: {'studio.edit'});
        registry.register(
          StudioModelingAgentProvider(
            scene: scene,
            instanceId: 'editor',
            isAvailable: () => true,
            onChanged: () {},
            hostRevision: () => 0,
          ),
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: studioTheme(Brightness.light),
            home: Scaffold(
              body: Align(
                alignment: Alignment.bottomRight,
                child: SizedBox(
                  width: 350,
                  height: size.height * .45,
                  child: StudioAgentPanel(
                    registry: registry,
                    sceneContext: () => {'documentId': 'test'},
                    modelFactory: (_) => ModelingModel(registry),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Agent settings'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byType(TextFormField).at(0),
          'http://localhost:11434/v1',
        );
        await tester.enterText(
          find.byType(TextFormField).at(1),
          'fixture-model',
        );
        await tester.tap(find.text('Save settings'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'Create a sphere');
        await tester.tap(find.byTooltip('Send request'));
        await tester.pumpAndSettle();
        expect(scene.document.nodes, isEmpty);
        expect(find.text('Apply change'), findsOneWidget);
        await tester.ensureVisible(find.text('Apply change'));
        await tester.tap(find.text('Apply change'));
        await tester.pumpAndSettle();
        expect(scene.document.nodes.single.kind, StudioNodeKind.sphere);
        expect(find.text('Sphere created.'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        registry.dispose();
      },
    );
  }
}
