/// Scoped Flutter contributions for an existing Studio editor workspace.
library;

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_agents/plugins.dart';
import 'package:zyren_studio/zyren_studio.dart';
import 'package:zyren_studio/commands.dart';
import 'package:zyren_studio/agent_extensions.dart';

part 'src/contribution.dart';
part 'src/context.dart';
part 'src/registry.dart';
part 'src/host.dart';
part 'src/panels.dart';
part 'src/commands.dart';

String _editorId(String value) {
  if (value.isEmpty || value.trim() != value || value.length > 256) {
    throw ArgumentError.value(value, 'id', 'Use 1 to 256 unpadded characters.');
  }
  return value;
}
