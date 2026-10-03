/// Build controls contributed to the existing Studio workspace.
library;

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:flutter_zyren_studio/flutter_zyren_studio.dart';
import 'package:zyren_pipeline/zyren_pipeline.dart';
import 'export.dart';
import 'agents.dart';
part 'src/export/build_panel.dart';

final class GameBuildContribution {
  final GameBuildCommands Function(StudioEditorContext) createCommands;
  final GameCollaborationAdapter? collaboration;
  final Future<void> Function()? leaveSession;
  final Future<void> Function()? importAssets;
  GameBuildContribution({
    required this.createCommands,
    this.collaboration,
    this.leaveSession,
    this.importAssets,
  });
  StudioEditorContribution get contribution => StudioEditorContribution(
    id: 'zyren.game-export',
    version: 1,
    dependencies: {'zyren.game-editor'},
    attach: (context) {
      final commands = createCommands(context);
      context.scope.onClose(commands.close);
      context.scope.keep(
        GameStudioAgentProvider(
          commands: commands,
          instanceId: context.scene.document.id,
        ).attach(context.services.agents),
      );
      context.registerPanel(
        StudioEditorPanel(
          id: 'game.build',
          title: 'Game export',
          icon: Icons.inventory_2_outlined,
          defaultDock: StudioEditorDock.bottom,
          builder: (_, c) => GameBuildPanel(
            commands: commands,
            collaboration: collaboration,
            leaveSession: leaveSession,
            importAssets: importAssets,
          ),
        ),
      );
      context.registerCommand(
        StudioEditorCommand(
          id: 'game.export',
          label: 'Export game',
          enabled: (c) =>
              c.isAvailable &&
              commands.activeJobs.isEmpty &&
              commands.allows('game.build'),
          handler: (c) {
            commands.startNewBuild(expectedRevision: commands.revision());
          },
        ),
      );
    },
  );
}
