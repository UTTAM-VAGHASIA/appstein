<!-- covers: none -->

# How to: add a curated note

A curated note tells agents about a Flutter change that the SDK's own files can't express: a new default, a language feature gated by the project's language version, a removed API, or a build change (spec §6.4). Read [knowledge-store](../knowledge-store.md#the-curated-notes) first.

**Notes are reviewed by the owner like spec text.** A wrong note is worse than a missing one, because agents trust it.

## 1. Check the fact

Confirm the change in an official source: docs.flutter.dev, dart.dev, api.flutter.dev, the flutter or dart-lang GitHub repos, the Flutter blog, developer.android.com or developer.apple.com.

Then find the first **stable** Flutter release it shipped in. Breaking-change pages often name a pre-release, and deprecation messages say "after v3.12.0-1.0.pre". Check the API in the SDK at that stable tag.

## 2. Pick the file

- A change in Flutter X.Y goes in `notes/X.Y.yaml`. Changes before the oldest supported minor go in that minor's file (today `notes/3.44.yaml`).
- A new stable minor gets a new file. Copy the top of the previous one, and set `flutter`, `released`, `dart` and the `toolchain` block from that version's SDK files. The toolchain test checks the block against fixtures for that version, so add them too (see [toolchain](../toolchain.md#when-a-new-flutter-stable-is-released)).
- A store build minimum (target API, Xcode, deployment target) goes in `notes/stores.yaml`, in date order.

## 3. Write the note

```yaml
  - id: dot-shorthands          # kebab-case, unique across every file
    since: "3.38"               # the first stable minor; quoted
    languageVersion: "3.10"     # only for Dart language features; quoted
    priority: 2                 # 1 = agents get it wrong often and it matters; 3 = niche
    area: dart                  # framework, dart, android, ios (also macOS) or tooling
    summary: One sentence, what changed.
    use: What to write now.
    avoid: What not to write.
    source: https://dart.dev/language/dot-shorthands
```

Quote every version. YAML reads an unquoted `3.40` as the number 3.4, and the parser refuses it.

## 4. Compile it in and test

From the repo root:

```powershell
fvm dart run tool/gen_notes.dart
fvm dart test test/notes_bundle_test.dart
cd packages/appstein_engine; fvm dart test test/notes test/toolchain
```

The parser names the file and line of any problem.
