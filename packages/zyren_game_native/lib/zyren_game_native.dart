/// Native physics and presentation adapters for the shared game clock.
library;

import 'dart:math' as math;

import 'package:zyren/zyren.dart';
import 'package:zyren_characters/physics.dart';
import 'package:zyren_interaction/zyren_interaction.dart';
import 'package:zyren_navigation/zyren_navigation.dart';
import 'package:zyren_timeline/zyren_timeline.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_physics/zyren_physics.dart';

part 'src/physics_driver.dart';
part 'src/simulation.dart';
part 'src/scene_plugin.dart';

part 'src/character.dart';
part 'src/character_intent.dart';
part 'src/camera_rig.dart';
part 'src/interaction_query.dart';
part 'src/sound_event.dart';

part 'src/vehicle/definition.dart';
part 'src/vehicle/wheel.dart';
part 'src/vehicle/controller.dart';
part 'src/vehicle/telemetry.dart';
