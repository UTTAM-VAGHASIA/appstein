import 'package:analyzer/dart/element/element.dart';

/// Whether [library] is an interface file for the `interfaces` layer rule
/// (spec §9.6). It must declare at least one class, and every class it
/// declares must be abstract, like a repository's interface.
///
/// Appstein's engine has the same rule for `layers.json`
/// (`appstein_engine/lib/src/map/interface_library.dart`). The lints can't
/// import the engine, so keep the two in step.
bool isInterfaceLibrary(LibraryElement library) {
  final classes = library.classes;
  return classes.isNotEmpty && classes.every((c) => c.isAbstract);
}
