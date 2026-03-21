/// Collects and renders unique import statements for generated files.
class ImportManager {
  final Set<String> _imports = <String>{};

  /// Adds an import path if it has not already been recorded.
  void add(String importPath) {
    _imports.add(importPath);
  }

  /// Renders the managed imports in sorted order.
  String render() {
    final sorted = _imports.toList()..sort();
    return sorted.map((importPath) => "import '$importPath';").join('\n');
  }
}
