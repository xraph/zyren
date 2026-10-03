/// Versioned game data and bounded simulation identity.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';

part 'src/project/component.dart';
part 'src/project/registry.dart';
part 'src/project/project.dart';
part 'src/project/spawn_template.dart';
part 'src/runtime/entity.dart';
part 'src/runtime/command_queue.dart';
part 'src/project/compiled_project.dart';
part 'src/runtime/clock.dart';
part 'src/runtime/events.dart';
part 'src/runtime/system.dart';
part 'src/runtime/session.dart';
part 'src/input/action_map.dart';
part 'src/input/action_state.dart';
part 'src/input/intent.dart';
part 'src/gameplay/inventory.dart';
part 'src/gameplay/ability.dart';
part 'src/gameplay/trigger.dart';
part 'src/gameplay/objective.dart';
part 'src/gameplay/interaction.dart';
part 'src/gameplay/behavior_tree.dart';
part 'src/gameplay/state_machine.dart';
part 'src/gameplay/systems.dart';
