/// Specialize the fixed atmosphere templates by texture binding. Some Vulkan
/// drivers cannot compile SPIR-V image arguments passed through helper functions.
/// Each generated helper reads one global image; the numerical body is unchanged.
String specializeAtmosphereTextures(String source) {
  const names = [
    'sample2',
    'sample3',
    'transTop',
    'transPath',
    'transSun',
    'scattering',
    'irradiance',
  ];
  final templates = <String, String>{};
  for (final name in names) {
    final signature = RegExp('fn $name\\(t:texture_[23]d<f32>,');
    final match = signature.firstMatch(source);
    if (match == null) {
      throw StateError('Missing atmosphere texture helper $name.');
    }
    final body = source.indexOf('{', match.end);
    var end = body + 1, depth = 1;
    while (depth > 0 && end < source.length) {
      if (source[end] == '{') depth++;
      if (source[end] == '}') depth--;
      end++;
    }
    if (depth != 0) {
      throw StateError('Unterminated atmosphere texture helper $name.');
    }
    templates[name] = source.substring(match.end, end);
    source = source.replaceRange(match.start, end, '');
  }
  final call = RegExp('\\b(${names.join('|')})\\(\\s*([A-Za-z_]\\w*)\\s*,');
  final pending = <(String, String)>[];
  final emitted = <(String, String)>{};
  String rewrite(String code) => code.replaceAllMapped(call, (m) {
    final name = m[1]!, texture = m[2]!;
    final key = (name, texture);
    if (emitted.add(key)) pending.add(key);
    return '${name}_$texture(';
  });
  final output = StringBuffer(rewrite(source));
  for (var index = 0; index < pending.length; index++) {
    final (name, texture) = pending[index];
    if (!RegExp('\\bvar\\s+$texture\\s*:').hasMatch(source)) {
      throw StateError(
        'Atmosphere texture helper requires a global image: $texture.',
      );
    }
    final body = templates[name]!.replaceAll(RegExp(r'\bt\b'), texture);
    output.write('\nfn ${name}_$texture(${rewrite(body)}\n');
  }
  return output.toString();
}
