/// The project map's files, by their path inside `.appstein/` (spec §6.2).
abstract final class MapFiles {
  /// Public declarations in `lib/`.
  static const symbols = 'map/symbols.json';

  /// Each file's layer tag and imports, and the forbidden imports.
  static const layers = 'map/layers.json';

  /// The packages and where they are imported.
  static const deps = 'map/deps.json';

  /// The features under `lib/ui/` (written by the stack pack).
  static const features = 'map/features.json';

  /// The go_router routes (written by the stack pack).
  static const routes = 'map/routes.json';

  /// All of them, sorted.
  static const all = [deps, features, layers, routes, symbols];
}
