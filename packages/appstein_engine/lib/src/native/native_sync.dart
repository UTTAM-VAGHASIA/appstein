import 'dart:convert';

import 'package:appstein_protocol/appstein_protocol.dart';

import '../knowledge/generated_file.dart';
import '../knowledge/input_hash.dart';
import '../packs/pack.dart';
import 'native_extractor.dart';

/// What the native part of a sync did.
final class NativeReport {
  /// Creates the report.
  const NativeReport({this.sections = const {}, this.errors = const {}});

  /// Each section's outcome in a few words, by section: `read`,
  /// `absent: <why>` (such as `absent: no ios/ folder`), or
  /// `internal error (<type>)`.
  final Map<String, String> sections;

  /// The full error of each section whose pack failed (an Appstein bug),
  /// for the person running the sync. It may hold a machine path, so it
  /// never goes into a generated file.
  final Map<String, String> errors;
}

/// `map/native.json`, built but not yet written.
final class NativeBuild {
  /// Creates the build.
  const NativeBuild({this.file, this.report = const NativeReport()});

  /// The file, or null when no pack has a native extractor.
  final GeneratedFile? file;

  /// What happened.
  final NativeReport report;
}

/// Builds `map/native.json` (spec §6.5) from the platform packs' native
/// extractors. It needs no Dart analysis, so `KnowledgeSync` runs it even
/// when the rest of the map is skipped.
final class NativeSync {
  /// Creates the sync for [packs]; only their native extractors run.
  const NativeSync({required this.appsteinVersion, required this.packs});

  /// The version of the running Appstein; part of the input hash.
  final String appsteinVersion;

  /// The project's packs.
  final List<Pack> packs;

  /// Builds the file.
  ///
  /// A pack that throws costs only its own section: it becomes an `error`
  /// value with the error's type, and the error is in
  /// [NativeReport.errors]. Throws a [StateError] when two packs write the
  /// same section, a mistake in Appstein's pack list.
  NativeBuild build(NativeContext context) {
    final extractors = [
      for (final pack in packs)
        if (pack.nativeExtractor case final extractor?) (pack, extractor),
    ];
    if (extractors.isEmpty) return const NativeBuild();
    final seen = <String>{};
    for (final (_, extractor) in extractors) {
      if (!seen.add(extractor.section)) {
        throw StateError(
          'Two packs write the "${extractor.section}" section of '
          '${MapFiles.native}.',
        );
      }
    }

    final sections = <String, NativeNode>{};
    final inputs = <String, List<int>?>{};
    final outcomes = <String, String>{};
    final errors = <String, String>{};
    for (final (_, extractor) in extractors) {
      final name = extractor.section;
      try {
        final section = extractor.extract(context);
        sections[name] = section.node;
        for (final MapEntry(:key, :value) in section.inputs.entries) {
          inputs['$name:$key'] = value;
        }
        outcomes[name] = switch (section.node) {
          NativeValue(status: NativeStatus.absent, :final reason) =>
            'absent: $reason',
          _ => 'read',
        };
        // Any failure is an Appstein bug and must not cost the other
        // sections or the sync. `on Object` is deliberate, as in MapSync.
      } on Object catch (error) {
        final type = '${error.runtimeType}';
        sections[name] = NativeValue.error(type);
        inputs['$name:error'] = utf8.encode(type);
        outcomes[name] = 'internal error ($type)';
        errors[name] = '$error';
      }
    }

    final hash = inputHash(
      {
        ...inputs,
        'flutter': utf8.encode(context.flutterVersion),
        'channel': utf8.encode(context.channel),
        'packs': utf8.encode(
          [
            for (final (pack, _) in extractors) '${pack.id}@${pack.version}',
          ].join(','),
        ),
      },
      appsteinVersion: appsteinVersion,
      formatVersion: knowledgeFormatVersion,
    );
    return NativeBuild(
      file: GeneratedFile(
        path: MapFiles.native,
        body: NativeConfig(sections).toJson(),
        inputHash: hash,
      ),
      report: NativeReport(sections: outcomes, errors: errors),
    );
  }
}
