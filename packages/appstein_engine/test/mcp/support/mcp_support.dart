import 'dart:convert';

import 'package:dart_mcp/server.dart';
import 'package:test/test.dart';

import '../../support/fixture_app.dart';

/// Checks [json] against the JSON Schema [schema] with `package:dart_mcp`'s
/// validator, the one the server's inputs go through.
void expectMatchesSchema(Map<String, Object?> schema, Object? json) {
  final errors = Schema.fromMap(schema).validate(json);
  expect(
    errors,
    isEmpty,
    reason: errors.map((error) => error.toErrorString()).join('\n'),
  );
}

/// The body of the map golden `<name>` (such as `features.json`), as the
/// map file holds it without its `meta`.
Map<String, Object?> golden(String name) =>
    jsonDecode(goldenText(name)) as Map<String, Object?>;
