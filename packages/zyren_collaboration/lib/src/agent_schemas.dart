const agentText = {'type': 'string', 'minLength': 1, 'maxLength': 256};
const agentRevision = {'type': 'integer', 'minimum': 0};
const agentBoolean = {'type': 'boolean'};
const agentData = {'type': 'object'};
Map<String, Object?> agentObject(
  Map<String, Object?> properties, {
  List<String> required = const [],
}) => {
  'type': 'object',
  'properties': properties,
  'required': required,
  'additionalProperties': false,
};
Map<String, Object?> agentArray(Map<String, Object?> items, int max) => {
  'type': 'array',
  'items': items,
  'maxItems': max,
};
Map<String, Object?> agentVector(int count) => {
  'type': 'array',
  'items': {'type': 'number'},
  'minItems': count,
  'maxItems': count,
};
final agentTarget = {'source': agentText, 'key': agentText};
final agentPageInput = agentObject({
  'offset': agentRevision,
  'limit': {'type': 'integer', 'minimum': 1, 'maximum': 50},
});
