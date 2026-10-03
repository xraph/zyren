import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren_studio/flutter_zyren_studio.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_studio/agent_extensions.dart';
import 'package:zyren_studio/modeling_agents.dart';
import 'package:zyren_agents/plugins.dart';
import 'support.dart';

void main() {
  test('registrations use one scope and disappear together', () async {
    final host = makeHost();
    final registration = host.register(panelContribution('game'));
    expect(host.panelIds, contains('game.panel'));
    expect(host.commandIds, contains('game.command'));
    registration.dispose();
    registration.dispose();
    expect(host.panelIds, isEmpty);
    expect(host.commandIds, isEmpty);
    await host.close();
  });
  test(
    'duplicate contributions and UI IDs do not remove the original',
    () async {
      final host = makeHost();
      final original = host.register(panelContribution('game'));
      expect(() => host.register(panelContribution('game')), throwsStateError);
      expect(
        () => host.register(
          StudioEditorContribution(
            id: 'other',
            version: 1,
            attach: (context) => context.registerPanel(
              StudioEditorPanel(
                id: 'game.panel',
                title: 'Collision',
                icon: Icons.error,
                builder: (_, _) => const SizedBox(),
              ),
            ),
          ),
        ),
        throwsStateError,
      );
      expect(host.panelIds, ['game.panel']);
      original.dispose();
      await host.close();
    },
  );
  test(
    'batch dependencies are ordered, cycles and missing dependencies fail before attach',
    () async {
      final host = makeHost();
      var attached = 0;
      StudioEditorContribution item(String id, String dependency) =>
          StudioEditorContribution(
            id: id,
            version: 1,
            dependencies: {dependency},
            attach: (_) => attached++,
          );
      expect(
        () => host.registerAll([item('a', 'b'), item('b', 'a')]),
        throwsStateError,
      );
      expect(() => host.register(item('a', 'missing')), throwsStateError);
      expect(attached, 0);
      host.registerAll([
        panelContribution('b', dependencies: {'a'}),
        panelContribution('a'),
      ]);
      expect(host.contributionIds, ['a', 'b']);
      await host.close();
    },
  );
  test(
    'attach failure rolls back every registration and batch attachment',
    () async {
      final host = makeHost();
      expect(
        () => host.registerAll([
          panelContribution('good'),
          StudioEditorContribution(
            id: 'bad',
            version: 1,
            attach: (context) {
              context.registerCommand(
                StudioEditorCommand(
                  id: 'temporary',
                  label: 'Temporary',
                  enabled: (_) => true,
                  handler: (_) {},
                ),
              );
              throw StateError('attach failed');
            },
          ),
        ]),
        throwsStateError,
      );
      expect(host.panelIds, isEmpty);
      expect(host.commandIds, isEmpty);
      expect(host.contributionIds, isEmpty);
      await host.close();
    },
  );
  test('removing a dependency detaches dependents first', () async {
    final host = makeHost();
    final order = <String>[];
    StudioEditorContribution item(String id, Set<String> dependencies) =>
        StudioEditorContribution(
          id: id,
          version: 1,
          dependencies: dependencies,
          attach: (context) =>
              context.scope.keep(Registration(() => order.add(id))),
        );
    final base = host.register(item('a', {}));
    host.register(item('b', {'a'}));
    base.dispose();
    expect(order, ['b', 'a']);
    expect(host.contributionIds, isEmpty);
    await host.close();
  });
  test(
    'shortcut conflicts roll back while enabled state is checked at invocation',
    () async {
      var available = true, calls = 0;
      final host = makeHost(isAvailable: () => available);
      StudioEditorContribution item(String id) => StudioEditorContribution(
        id: id,
        version: 1,
        attach: (context) => context.registerCommand(
          StudioEditorCommand(
            id: id,
            label: id,
            shortcut: const SingleActivator(
              LogicalKeyboardKey.keyP,
              control: true,
            ),
            enabled: (_) => true,
            handler: (_) => calls++,
          ),
        ),
      );
      host.register(item('first'));
      expect(() => host.register(item('second')), throwsStateError);
      expect(host.commandIds, ['first']);
      await host.executeCommand('first');
      expect(calls, 1);
      available = false;
      await expectLater(host.executeCommand('first'), throwsStateError);
      expect(calls, 1);
      await host.close();
    },
  );
  test(
    'all editor surfaces register and validation results retire on detach',
    () async {
      final host = makeHost();
      final completed = Completer<List<StudioEditorProblem>>();
      final registration = host.register(
        StudioEditorContribution(
          id: 'surface',
          version: 1,
          attach: (context) {
            context.registerInspector(
              StudioEditorInspector(
                id: 'inspect',
                title: 'Inspect',
                applies: (_) => true,
                builder: (_, _) => const Text('Inspector'),
              ),
            );
            context.registerAssetKind(
              StudioEditorAssetKind(
                id: 'asset',
                label: 'Custom',
                extensions: {'asset'},
                importAsset: (_, _) async {},
              ),
            );
            context.registerCreationTool(
              StudioEditorCreationTool(
                id: 'create',
                label: 'Create',
                icon: Icons.add,
                enabled: (_) => true,
                create: (_) {},
              ),
            );
            context.registerOverlay(
              StudioEditorOverlay(
                id: 'overlay',
                builder: (_, _) => const Text('Overlay'),
              ),
            );
            context.registerValidator(
              StudioEditorValidator(
                id: 'validate',
                validate: (_, _) => completed.future,
              ),
            );
            context.registerPlayFactory(
              StudioEditorPlayFactory(
                id: 'play',
                label: 'Play',
                supports: (_, _) => true,
                create: (_, _) async => TestPlaySession(),
              ),
            );
          },
        ),
      );
      expect(host.inspectorIds, ['inspect']);
      expect(host.assetKindIds, ['asset']);
      expect(host.creationToolIds, ['create']);
      expect(host.overlayIds, ['overlay']);
      expect(host.validatorIds, ['validate']);
      expect(host.playFactoryIds, ['play']);
      final result = host.validate();
      registration.dispose();
      completed.complete([
        const StudioEditorProblem('old', 'Stale', blocking: true),
      ]);
      expect(await result, isEmpty);
      expect(host.inspectorIds, isEmpty);
      expect(host.assetKindIds, isEmpty);
      expect(host.creationToolIds, isEmpty);
      expect(host.overlayIds, isEmpty);
      expect(host.validatorIds, isEmpty);
      expect(host.playFactoryIds, isEmpty);
      await host.close();
    },
  );
  test(
    'play sessions close on detach and in-flight creation cannot revive a removed factory',
    () async {
      final host = makeHost();
      final session = TestPlaySession();
      final created = Completer<StudioEditorPlaySession>();
      final registration = host.register(
        StudioEditorContribution(
          id: 'play',
          version: 1,
          attach: (context) => context.registerPlayFactory(
            StudioEditorPlayFactory(
              id: 'factory',
              label: 'Play',
              supports: (_, _) => true,
              create: (_, _) => created.future,
            ),
          ),
        ),
      );
      final starting = host.startPlay('factory');
      await Future<void>.delayed(Duration.zero);
      registration.dispose();
      created.complete(session);
      await expectLater(starting, throwsStateError);
      expect(session.closed, 1);
      expect(host.activePlaySession, isNull);
      await host.close();
    },
  );
  test(
    'runtime extensions compose the existing Studio binding and roll back failed installation',
    () async {
      final installed = <List<String>>[];
      final host = makeHost(
        installRuntimePlugins: (plugins) async {
          installed.add(plugins.map((p) => p.id).toList());
          if (plugins.isNotEmpty) throw StateError('native attach failed');
        },
      );
      host.register(
        StudioEditorContribution(
          id: 'runtime',
          version: 1,
          runtimeExtension: StudioAgentExtension(
            id: 'runtime',
            scopes: {},
            attach: (_) {},
          ),
          attach: (context) => context.registerCommand(
            StudioEditorCommand(
              id: 'runtime.command',
              label: 'Runtime',
              enabled: (_) => true,
              handler: (_) {},
            ),
          ),
        ),
      );
      await expectLater(host.whenSettled, throwsStateError);
      expect(installed.first, ['studio.editor.binding.runtime']);
      expect(host.commandIds, isEmpty);
      expect(host.contributionIds, isEmpty);
      await host.close();
    },
  );
  test('closed contexts cannot change history or register callbacks', () async {
    final host = makeHost();
    late StudioEditorContext context;
    final registration = host.register(
      StudioEditorContribution(
        id: 'a',
        version: 1,
        attach: (value) => context = value,
      ),
    );
    registration.dispose();
    expect(context.isActive, isFalse);
    expect(
      () => context.applyDocument(context.scene.document),
      throwsStateError,
    );
    expect(
      () => context.registerValidator(
        StudioEditorValidator(id: 'v', validate: (_, _) => []),
      ),
      throwsStateError,
    );
    await host.close();
  });
  test(
    'cleanup failures retain evidence and still remove all dependents',
    () async {
      final host = makeHost();
      final cleaned = <String>[];
      final base = host.register(
        StudioEditorContribution(
          id: 'base',
          version: 1,
          attach: (context) =>
              context.scope.keep(Registration(() => cleaned.add('base'))),
        ),
      );
      host.register(
        StudioEditorContribution(
          id: 'dependent',
          version: 1,
          dependencies: {'base'},
          attach: (context) {
            context.registerCommand(
              StudioEditorCommand(
                id: 'dependent',
                label: 'Dependent',
                enabled: (_) => true,
                handler: (_) {},
              ),
            );
            context.scope.keep(Registration(() => cleaned.add('dependent')));
            context.scope.keep(
              Registration(() => throw StateError('cleanup failed')),
            );
          },
        ),
      );
      base.dispose();
      expect(cleaned, ['dependent', 'base']);
      expect(host.commandIds, isEmpty);
      expect(host.lastError, isNotNull);
      await expectLater(host.close(), throwsA(isA<ScopeCleanupException>()));
    },
  );
  test(
    'runtime failure retires dependents registered during attachment',
    () async {
      final attached = Completer<void>();
      final host = makeHost(
        installRuntimePlugins: (plugins) =>
            plugins.isEmpty ? Future.value() : attached.future,
      );
      host.register(
        StudioEditorContribution(
          id: 'base',
          version: 1,
          runtimeExtension: StudioAgentExtension(
            id: 'base',
            scopes: {},
            attach: (_) {},
          ),
          attach: (_) {},
        ),
      );
      final settlement = host.whenSettled;
      host.register(panelContribution('dependent', dependencies: {'base'}));
      attached.completeError(StateError('runtime failed'));
      await expectLater(settlement, throwsStateError);
      expect(host.contributionIds, isEmpty);
      expect(host.panelIds, isEmpty);
      expect(host.commandIds, isEmpty);
      await host.close();
    },
  );
  test(
    'an active play session survives failed replacement and closes with its factory',
    () async {
      final host = makeHost();
      final session = TestPlaySession();
      final registration = host.register(
        StudioEditorContribution(
          id: 'play',
          version: 1,
          attach: (context) {
            context.registerPlayFactory(
              StudioEditorPlayFactory(
                id: 'working',
                label: 'Working',
                supports: (_, _) => true,
                create: (_, _) async => session,
              ),
            );
            context.registerPlayFactory(
              StudioEditorPlayFactory(
                id: 'failed',
                label: 'Failed',
                supports: (_, _) => true,
                create: (_, _) async => throw StateError('compile failed'),
              ),
            );
          },
        ),
      );
      await host.startPlay('working');
      await expectLater(host.startPlay('failed'), throwsStateError);
      expect(host.activePlaySession, same(session));
      expect(session.closed, 0);
      await host.pausePlay();
      await host.stepPlay();
      expect(session.steps, 1);
      await host.resumePlay();
      await expectLater(host.stepPlay(), throwsStateError);
      registration.dispose();
      await host.whenSettled;
      expect(session.closed, 1);
      expect(host.activePlaySession, isNull);
      await host.close();
    },
  );
  test(
    'providers attach through existing scene services and retire on detach',
    () async {
      late SceneEngine engine;
      late AgentRegistryPlugin bridge;
      final host = makeHost(
        installRuntimePlugins: (plugins) =>
            engine.updatePlugins([bridge, ...plugins]),
      );
      bridge = AgentRegistryPlugin(host.services.agents);
      engine = await SceneEngine.create(
        scene: host.services.scene.scene,
        camera: host.services.scene.camera,
        rendererFactory: () async => ContractRenderer(),
        plugins: [bridge],
      );
      final lease = host.register(
        StudioEditorContribution(
          id: 'provider',
          version: 1,
          attach: (context) {
            context.agentExtensionContext.register(
              StudioModelingAgentProvider(
                scene: context.scene,
                instanceId: 'contribution',
                isAvailable: () => context.isAvailable,
                hostRevision: () => context.scene.revision,
                onChanged: () {},
              ),
            );
          },
        ),
      );
      expect(host.services.agents.discover()['providers'], isEmpty);
      await host.whenSettled;
      expect((host.services.agents.discover()['providers'] as List).length, 1);
      expect(host.services.agents.grantedScopes, isEmpty);
      lease.dispose();
      await host.whenSettled;
      expect(host.services.agents.discover()['providers'], isEmpty);
      await host.close();
      await engine.dispose();
    },
  );
  test(
    'disposing an individual play factory closes its session and retires pending creation',
    () async {
      final host = makeHost();
      final first = TestPlaySession(), late = TestPlaySession();
      final pending = Completer<StudioEditorPlaySession>();
      late Registration factoryLease;
      host.register(
        StudioEditorContribution(
          id: 'play',
          version: 1,
          attach: (context) {
            factoryLease = context.registerPlayFactory(
              StudioEditorPlayFactory(
                id: 'factory',
                label: 'Factory',
                supports: (_, _) => true,
                create: (_, _) async => first,
              ),
            );
          },
        ),
      );
      await host.startPlay('factory');
      factoryLease.dispose();
      await host.whenSettled;
      expect(first.closed, 1);
      expect(host.activePlaySession, isNull);
      host.register(
        StudioEditorContribution(
          id: 'pending',
          version: 1,
          attach: (context) {
            factoryLease = context.registerPlayFactory(
              StudioEditorPlayFactory(
                id: 'pending',
                label: 'Pending',
                supports: (_, _) => true,
                create: (_, _) => pending.future,
              ),
            );
          },
        ),
      );
      final starting = host.startPlay('pending');
      await Future<void>.delayed(Duration.zero);
      factoryLease.dispose();
      pending.complete(late);
      await expectLater(starting, throwsStateError);
      expect(late.closed, 1);
      await host.close();
    },
  );
}
