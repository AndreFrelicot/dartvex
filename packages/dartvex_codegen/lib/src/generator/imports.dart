class ImportManager {
  final Set<String> _imports = <String>{};

  void add(String importPath) {
    _imports.add(importPath);
  }

  String render() {
    final sorted = _imports.toList()..sort();
    return sorted.map((importPath) => "import '$importPath';").join('\n');
  }
}
