#!/usr/bin/env dart

import 'dart:collection';
import 'dart:io';

Future<void> main(List<String> args) async {
  final cli = CliOptions.parse(args);
  if (cli.showHelp) {
    stdout.writeln(_usage);
    exit(0);
  }

  if (cli.command == null) {
    stderr.writeln('Missing command.\n');
    stderr.writeln(_usage);
    exit(64);
  }

  final repoRoot = await _gitRepoRoot();
  final gitState = await _gitStatusSummary(repoRoot);
  final packages = await _loadPackages(repoRoot);

  if (packages.isEmpty) {
    stderr.writeln('No publishable packages found under packages/.');
    exit(1);
  }

  final baselines = await _resolveBaselines(
    repoRoot: repoRoot,
    packages: packages,
    sinceRef: cli.sinceRef,
  );

  final directlyChanged = cli.selectAll
      ? packages.map((package) => package.name).toSet()
      : await _computeDirectChanges(
          repoRoot: repoRoot,
          packages: packages,
          baselines: baselines,
        );

  final impactedDependents = _computeImpactedDependents(
    packages,
    directlyChanged,
  );

  final selected = <String>{
    ...directlyChanged,
    if (cli.includeDependents) ...impactedDependents,
  };

  final selectedPackages = packages
      .where((package) => selected.contains(package.name))
      .toList();
  final publishOrder = _topologicalPublishOrder(
    packages: packages,
    selectedPackageNames: selected,
  );
  final internalConstraintIssues = _findInternalConstraintIssues(packages);

  switch (cli.command) {
    case 'plan':
      _printPlan(
        gitState: gitState,
        packages: packages,
        directlyChanged: directlyChanged,
        impactedDependents: impactedDependents,
        publishOrder: publishOrder,
        baselines: baselines,
        internalConstraintIssues: internalConstraintIssues,
        includeDependents: cli.includeDependents,
        selectAll: cli.selectAll,
      );
      break;
    case 'dry-run':
      _printPlan(
        gitState: gitState,
        packages: packages,
        directlyChanged: directlyChanged,
        impactedDependents: impactedDependents,
        publishOrder: publishOrder,
        baselines: baselines,
        internalConstraintIssues: internalConstraintIssues,
        includeDependents: cli.includeDependents,
        selectAll: cli.selectAll,
        brief: true,
      );
      if (selectedPackages.isEmpty) {
        stdout.writeln('No packages selected for dry-run.');
        exit(0);
      }

      final missingBaselines = !cli.selectAll
          ? packages.where((package) {
              final baseline = baselines[package.name];
              return selected.contains(package.name) && baseline == null;
            }).toList()
          : const <PackageInfo>[];
      if (missingBaselines.isNotEmpty) {
        stderr.writeln(
          'Cannot run dry-run without a baseline for: '
          '${missingBaselines.map((package) => package.name).join(', ')}.',
        );
        stderr.writeln(
          'Add per-package tags like <package>-v<version> or pass --since-ref=<git-ref>.',
        );
        exit(2);
      }

      final dirtySelectedPackages = await _packagesWithTrackedChanges(
        repoRoot: repoRoot,
        packages: publishOrder,
      );
      if (dirtySelectedPackages.isNotEmpty) {
        stderr.writeln(
          'Dry-run requires a clean git state for selected packages. '
          'Commit or stash release edits first.',
        );
        stderr.writeln(
          'Tracked changes found in: ${dirtySelectedPackages.join(', ')}',
        );
        exit(2);
      }

      final failures = await _runDryRuns(
        repoRoot: repoRoot,
        packages: publishOrder,
      );
      if (failures.isNotEmpty) {
        stderr.writeln('\nDry-run failures: ${failures.join(', ')}');
        exit(1);
      }
      break;
    default:
      stderr.writeln('Unsupported command: ${cli.command}');
      exit(64);
  }
}

const _usage = '''
Usage:
  dart scripts/release_packages.dart plan [--since-ref=<git-ref>] [--include-dependents] [--all]
  dart scripts/release_packages.dart dry-run [--since-ref=<git-ref>] [--include-dependents] [--all]

What it does:
  - Detects packages changed since their package tag (<package>-v<version>)
  - Falls back to --since-ref when tags do not exist yet
  - Computes internal dependents affected by those changes
  - Orders selected packages so dependencies publish first
  - Runs pub.dev dry-runs with dart or flutter as appropriate

Recommended tag format:
  dartvex-v0.1.0
  dartvex_flutter-v0.1.0
''';

class CliOptions {
  CliOptions({
    required this.command,
    required this.sinceRef,
    required this.includeDependents,
    required this.selectAll,
    required this.showHelp,
  });

  final String? command;
  final String? sinceRef;
  final bool includeDependents;
  final bool selectAll;
  final bool showHelp;

  static CliOptions parse(List<String> args) {
    String? command;
    String? sinceRef;
    var includeDependents = false;
    var selectAll = false;
    var showHelp = false;

    for (final arg in args) {
      if (arg == '-h' || arg == '--help') {
        showHelp = true;
      } else if (arg == '--include-dependents') {
        includeDependents = true;
      } else if (arg == '--all') {
        selectAll = true;
      } else if (arg.startsWith('--since-ref=')) {
        sinceRef = arg.substring('--since-ref='.length);
      } else if (arg.startsWith('-')) {
        stderr.writeln('Unknown option: $arg');
        exit(64);
      } else if (command == null) {
        command = arg;
      } else {
        stderr.writeln('Unexpected argument: $arg');
        exit(64);
      }
    }

    return CliOptions(
      command: command,
      sinceRef: sinceRef,
      includeDependents: includeDependents,
      selectAll: selectAll,
      showHelp: showHelp,
    );
  }
}

class PackageInfo {
  PackageInfo({
    required this.name,
    required this.version,
    required this.directoryName,
    required this.directory,
    required this.publishTool,
    required this.internalDependencies,
    required this.internalDependencyConstraints,
  });

  final String name;
  final SemVer version;
  final String directoryName;
  final Directory directory;
  final PublishTool publishTool;
  final Set<String> internalDependencies;
  final Map<String, String> internalDependencyConstraints;
}

enum PublishTool { dart, flutter }

class SemVer implements Comparable<SemVer> {
  const SemVer(this.major, this.minor, this.patch, [this.prerelease]);

  final int major;
  final int minor;
  final int patch;
  final String? prerelease;

  factory SemVer.parse(String input) {
    final match = RegExp(
      r'^(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?$',
    ).firstMatch(input.trim());
    if (match == null) {
      throw FormatException('Unsupported version format: $input');
    }
    return SemVer(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
      match.group(4),
    );
  }

  @override
  int compareTo(SemVer other) {
    final majorCompare = major.compareTo(other.major);
    if (majorCompare != 0) {
      return majorCompare;
    }
    final minorCompare = minor.compareTo(other.minor);
    if (minorCompare != 0) {
      return minorCompare;
    }
    final patchCompare = patch.compareTo(other.patch);
    if (patchCompare != 0) {
      return patchCompare;
    }
    if (prerelease == null && other.prerelease == null) {
      return 0;
    }
    if (prerelease == null) {
      return 1;
    }
    if (other.prerelease == null) {
      return -1;
    }
    return prerelease!.compareTo(other.prerelease!);
  }

  @override
  String toString() {
    if (prerelease == null || prerelease!.isEmpty) {
      return '$major.$minor.$patch';
    }
    return '$major.$minor.$patch-$prerelease';
  }
}

class ConstraintIssue {
  const ConstraintIssue({
    required this.dependentPackage,
    required this.dependencyPackage,
    required this.constraint,
    required this.actualVersion,
  });

  final String dependentPackage;
  final String dependencyPackage;
  final String constraint;
  final SemVer actualVersion;
}

Future<String> _gitRepoRoot() async {
  final result = await _runGit(Directory.current.path, [
    'rev-parse',
    '--show-toplevel',
  ]);
  return result.stdout.trim();
}

Future<String> _gitStatusSummary(String repoRoot) async {
  final result = await Process.run('git', [
    'status',
    '--short',
  ], workingDirectory: repoRoot);
  _ensureSuccess(result, 'git status --short');
  final lines = (result.stdout as String)
      .split('\n')
      .where((line) => line.trim().isNotEmpty)
      .toList();
  if (lines.isEmpty) {
    return 'clean';
  }
  return 'dirty (${lines.length} change${lines.length == 1 ? '' : 's'})';
}

Future<List<PackageInfo>> _loadPackages(String repoRoot) async {
  final packagesDir = Directory('$repoRoot/packages');
  final packageDirs = packagesDir.listSync().whereType<Directory>().toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  final packageNames = <String>{};
  final packages = <PackageInfo>[];
  for (final directory in packageDirs) {
    final pubspecFile = File('${directory.path}/pubspec.yaml');
    if (!pubspecFile.existsSync()) {
      continue;
    }

    final parsed = _parsePubspec(pubspecFile.readAsLinesSync());
    final name = parsed['name'] as String?;
    final versionRaw = parsed['version'] as String?;
    if (name == null || versionRaw == null) {
      continue;
    }
    packageNames.add(name);
    packages.add(
      PackageInfo(
        name: name,
        version: SemVer.parse(versionRaw),
        directoryName: directory.uri.pathSegments
            .where((segment) => segment.isNotEmpty)
            .last,
        directory: directory,
        publishTool: parsed['flutterSdkDependency'] == 'true'
            ? PublishTool.flutter
            : PublishTool.dart,
        internalDependencies: <String>{},
        internalDependencyConstraints: <String, String>{},
      ),
    );
  }

  for (var index = 0; index < packages.length; index++) {
    final package = packages[index];
    final pubspecFile = File('${package.directory.path}/pubspec.yaml');
    final parsed = _parsePubspec(pubspecFile.readAsLinesSync());
    final dependencies = <String>{};
    final constraints = <String, String>{};
    for (final section in ['dependencies', 'dev_dependencies']) {
      final entries = parsed[section] as Map<String, String>? ?? {};
      for (final entry in entries.entries) {
        if (packageNames.contains(entry.key)) {
          dependencies.add(entry.key);
          constraints[entry.key] = entry.value;
        }
      }
    }
    packages[index] = PackageInfo(
      name: package.name,
      version: package.version,
      directoryName: package.directoryName,
      directory: package.directory,
      publishTool: package.publishTool,
      internalDependencies: dependencies,
      internalDependencyConstraints: constraints,
    );
  }

  return packages;
}

Map<String, Object> _parsePubspec(List<String> lines) {
  final data = <String, Object>{};
  var currentSection = '';
  String? currentDependencyName;
  Map<String, String>? currentMap;

  void resetNestedDependency() {
    currentDependencyName = null;
  }

  for (final rawLine in lines) {
    final line = rawLine.replaceAll('\r', '');
    final trimmed = line.trimRight();
    if (trimmed.isEmpty || trimmed.trimLeft().startsWith('#')) {
      continue;
    }

    final indent = line.length - line.trimLeft().length;
    final content = line.trimLeft();

    if (indent == 0) {
      resetNestedDependency();
      currentMap = null;
      if (content == 'dependencies:' || content == 'dev_dependencies:') {
        currentSection = content.substring(0, content.length - 1);
        currentMap = <String, String>{};
        data[currentSection] = currentMap;
        continue;
      }
      currentSection = '';
      final split = content.split(':');
      if (split.length >= 2) {
        final key = split.first.trim();
        final value = content.substring(content.indexOf(':') + 1).trim();
        if (value.isNotEmpty) {
          data[key] = _stripYamlQuotes(value);
        }
      }
      continue;
    }

    if (currentSection.isEmpty || currentMap == null) {
      continue;
    }

    if (indent == 2 && content.endsWith(':')) {
      final dependencyName = content.substring(0, content.length - 1).trim();
      currentDependencyName = dependencyName;
      currentMap[dependencyName] = '<path-or-sdk>';
      continue;
    }

    if (indent == 2 && content.contains(':')) {
      final key = content.substring(0, content.indexOf(':')).trim();
      final value = content.substring(content.indexOf(':') + 1).trim();
      currentMap[key] = value.isEmpty
          ? '<path-or-sdk>'
          : _stripYamlQuotes(value);
      currentDependencyName = null;
      continue;
    }

    if (indent == 4 &&
        currentSection == 'dependencies' &&
        currentDependencyName == 'flutter' &&
        content == 'sdk: flutter') {
      data['flutterSdkDependency'] = 'true';
      continue;
    }
  }

  return data;
}

String _stripYamlQuotes(String value) {
  if (value.length >= 2) {
    final startsWithSingle = value.startsWith("'");
    final endsWithSingle = value.endsWith("'");
    final startsWithDouble = value.startsWith('"');
    final endsWithDouble = value.endsWith('"');
    if ((startsWithSingle && endsWithSingle) ||
        (startsWithDouble && endsWithDouble)) {
      return value.substring(1, value.length - 1);
    }
  }
  return value;
}

Future<Map<String, String?>> _resolveBaselines({
  required String repoRoot,
  required List<PackageInfo> packages,
  required String? sinceRef,
}) async {
  if (sinceRef != null) {
    return {for (final package in packages) package.name: sinceRef};
  }

  final result = await _runGit(repoRoot, ['tag', '--list']);
  final tags = (result.stdout as String)
      .split('\n')
      .where((tag) => tag.trim().isNotEmpty)
      .toList();

  final baselines = <String, String?>{};
  for (final package in packages) {
    final matchingTags = tags
        .where((tag) => tag.startsWith('${package.name}-v'))
        .toList();
    if (matchingTags.isEmpty) {
      baselines[package.name] = null;
      continue;
    }
    matchingTags.sort((a, b) => _compareReleaseTags(a, b));
    baselines[package.name] = matchingTags.last;
  }
  return baselines;
}

int _compareReleaseTags(String left, String right) {
  final leftVersion = _parseReleaseTagVersion(left);
  final rightVersion = _parseReleaseTagVersion(right);
  if (leftVersion != null && rightVersion != null) {
    return leftVersion.compareTo(rightVersion);
  }
  return left.compareTo(right);
}

SemVer? _parseReleaseTagVersion(String tag) {
  final index = tag.lastIndexOf('-v');
  if (index == -1) {
    return null;
  }
  try {
    return SemVer.parse(tag.substring(index + 2));
  } on FormatException {
    return null;
  }
}

Future<Set<String>> _computeDirectChanges({
  required String repoRoot,
  required List<PackageInfo> packages,
  required Map<String, String?> baselines,
}) async {
  final changed = <String>{};
  for (final package in packages) {
    final baseline = baselines[package.name];
    if (baseline == null) {
      continue;
    }
    final result = await Process.run('git', [
      'diff',
      '--name-only',
      '$baseline..HEAD',
      '--',
      package.directory.path,
    ], workingDirectory: repoRoot);
    _ensureSuccess(
      result,
      'git diff --name-only $baseline..HEAD -- ${package.directory.path}',
    );
    final hasChanges = (result.stdout as String).trim().isNotEmpty;
    if (hasChanges) {
      changed.add(package.name);
    }
  }
  return changed;
}

Set<String> _computeImpactedDependents(
  List<PackageInfo> packages,
  Set<String> directlyChanged,
) {
  final dependentsByDependency = <String, Set<String>>{};
  for (final package in packages) {
    for (final dependency in package.internalDependencies) {
      dependentsByDependency
          .putIfAbsent(dependency, () => <String>{})
          .add(package.name);
    }
  }

  final impacted = <String>{};
  final queue = Queue<String>()..addAll(directlyChanged);
  while (queue.isNotEmpty) {
    final packageName = queue.removeFirst();
    for (final dependent
        in dependentsByDependency[packageName] ?? const <String>{}) {
      if (directlyChanged.contains(dependent) || impacted.contains(dependent)) {
        continue;
      }
      impacted.add(dependent);
      queue.add(dependent);
    }
  }
  return impacted;
}

List<PackageInfo> _topologicalPublishOrder({
  required List<PackageInfo> packages,
  required Set<String> selectedPackageNames,
}) {
  final packageByName = {for (final package in packages) package.name: package};
  final selectedPackages = packages
      .where((package) => selectedPackageNames.contains(package.name))
      .toList();
  final inDegree = <String, int>{
    for (final package in selectedPackages) package.name: 0,
  };
  final dependents = <String, List<String>>{};

  for (final package in selectedPackages) {
    for (final dependency in package.internalDependencies) {
      if (!selectedPackageNames.contains(dependency)) {
        continue;
      }
      inDegree[package.name] = (inDegree[package.name] ?? 0) + 1;
      dependents.putIfAbsent(dependency, () => <String>[]).add(package.name);
    }
  }

  final ready = SplayTreeSet<String>()
    ..addAll(
      inDegree.entries
          .where((entry) => entry.value == 0)
          .map((entry) => entry.key),
    );

  final ordered = <PackageInfo>[];
  while (ready.isNotEmpty) {
    final next = ready.first;
    ready.remove(next);
    ordered.add(packageByName[next]!);
    for (final dependent in dependents[next] ?? const <String>[]) {
      final updated = (inDegree[dependent] ?? 0) - 1;
      inDegree[dependent] = updated;
      if (updated == 0) {
        ready.add(dependent);
      }
    }
  }

  if (ordered.length != selectedPackages.length) {
    throw StateError('Internal dependency graph contains a cycle.');
  }
  return ordered;
}

List<ConstraintIssue> _findInternalConstraintIssues(
  List<PackageInfo> packages,
) {
  final packageByName = {for (final package in packages) package.name: package};
  final issues = <ConstraintIssue>[];
  for (final package in packages) {
    for (final entry in package.internalDependencyConstraints.entries) {
      final dependency = packageByName[entry.key];
      if (dependency == null) {
        continue;
      }
      if (!_constraintAllows(entry.value, dependency.version)) {
        issues.add(
          ConstraintIssue(
            dependentPackage: package.name,
            dependencyPackage: dependency.name,
            constraint: entry.value,
            actualVersion: dependency.version,
          ),
        );
      }
    }
  }
  return issues;
}

bool _constraintAllows(String constraint, SemVer version) {
  final normalized = constraint.trim();
  if (normalized.isEmpty ||
      normalized == 'any' ||
      normalized == '<path-or-sdk>') {
    return true;
  }

  if (normalized.startsWith('^')) {
    final base = SemVer.parse(normalized.substring(1));
    final upper = _caretUpperBound(base);
    return version.compareTo(base) >= 0 && version.compareTo(upper) < 0;
  }

  if (!normalized.contains(' ') &&
      !normalized.startsWith('>') &&
      !normalized.startsWith('<') &&
      !normalized.startsWith('=')) {
    return version.compareTo(SemVer.parse(normalized)) == 0;
  }

  final tokens = normalized.split(RegExp(r'\s+'));
  for (final token in tokens) {
    if (token.isEmpty) {
      continue;
    }
    if (!_singleConstraintAllows(token, version)) {
      return false;
    }
  }
  return true;
}

SemVer _caretUpperBound(SemVer version) {
  if (version.major > 0) {
    return SemVer(version.major + 1, 0, 0);
  }
  if (version.minor > 0) {
    return SemVer(0, version.minor + 1, 0);
  }
  return SemVer(0, 0, version.patch + 1);
}

bool _singleConstraintAllows(String token, SemVer version) {
  if (token.startsWith('>=')) {
    return version.compareTo(SemVer.parse(token.substring(2))) >= 0;
  }
  if (token.startsWith('<=')) {
    return version.compareTo(SemVer.parse(token.substring(2))) <= 0;
  }
  if (token.startsWith('>')) {
    return version.compareTo(SemVer.parse(token.substring(1))) > 0;
  }
  if (token.startsWith('<')) {
    return version.compareTo(SemVer.parse(token.substring(1))) < 0;
  }
  if (token.startsWith('=')) {
    return version.compareTo(SemVer.parse(token.substring(1))) == 0;
  }
  return version.compareTo(SemVer.parse(token)) == 0;
}

void _printPlan({
  required String gitState,
  required List<PackageInfo> packages,
  required Set<String> directlyChanged,
  required Set<String> impactedDependents,
  required List<PackageInfo> publishOrder,
  required Map<String, String?> baselines,
  required List<ConstraintIssue> internalConstraintIssues,
  required bool includeDependents,
  required bool selectAll,
  bool brief = false,
}) {
  stdout.writeln('Git status: $gitState');
  if (!brief) {
    stdout.writeln('Packages discovered: ${packages.length}');
  }

  if (selectAll) {
    stdout.writeln('Selection mode: all packages');
  } else if (baselines.values.any((baseline) => baseline == null)) {
    final missing =
        baselines.entries
            .where((entry) => entry.value == null)
            .map((entry) => entry.key)
            .toList()
          ..sort();
    if (missing.isNotEmpty) {
      stdout.writeln(
        'Missing release tags for: ${missing.join(', ')}. Use --since-ref or add <package>-v<version> tags.',
      );
    }
  }

  final directList = directlyChanged.toList()..sort();
  stdout.writeln(
    'Directly changed packages: ${directList.isEmpty ? 'none' : directList.join(', ')}',
  );

  final dependentList = impactedDependents.toList()..sort();
  stdout.writeln(
    'Impacted dependents: ${dependentList.isEmpty ? 'none' : dependentList.join(', ')}',
  );

  if (publishOrder.isEmpty) {
    stdout.writeln('Selected release set: none');
  } else {
    stdout.writeln(
      'Selected release set${includeDependents ? ' (including dependents)' : ''}: '
      '${publishOrder.map((package) => package.name).join(' -> ')}',
    );
  }

  if (!brief) {
    stdout.writeln('\nPackage status:');
    for (final package in packages) {
      final baseline = baselines[package.name];
      final flags = <String>[
        if (directlyChanged.contains(package.name)) 'changed',
        if (impactedDependents.contains(package.name)) 'dependent',
      ];
      final marker = flags.isEmpty ? 'unchanged' : flags.join(', ');
      final deps = package.internalDependencies.toList()..sort();
      stdout.writeln(
        '  - ${package.name} ${package.version} '
        '[${package.publishTool.name}] '
        'baseline=${baseline ?? 'missing'} '
        'status=$marker '
        'internal_deps=${deps.isEmpty ? 'none' : deps.join(',')}',
      );
    }
  }

  if (internalConstraintIssues.isEmpty) {
    stdout.writeln('Internal dependency constraints: OK');
  } else {
    stdout.writeln('Internal dependency constraints:');
    for (final issue in internalConstraintIssues) {
      stdout.writeln(
        '  - ${issue.dependentPackage} depends on ${issue.dependencyPackage} '
        'with ${issue.constraint}, but local version is ${issue.actualVersion}',
      );
    }
  }

  if (!brief) {
    stdout.writeln('\nSuggested next step:');
    stdout.writeln(
      '  dart scripts/release_packages.dart dry-run'
      '${baselines.values.any((baseline) => baseline == null) && !selectAll ? ' --since-ref=<git-ref>' : ''}'
      '${includeDependents ? ' --include-dependents' : ''}',
    );
  }
}

Future<List<String>> _runDryRuns({
  required String repoRoot,
  required List<PackageInfo> packages,
}) async {
  final failures = <String>[];
  for (final package in packages) {
    stdout.writeln(
      '\n==> ${package.name} ${package.version} (${package.publishTool.name})',
    );
    final getArgs = package.publishTool == PublishTool.flutter
        ? ['pub', 'get']
        : ['pub', 'get'];
    final publishArgs = package.publishTool == PublishTool.flutter
        ? ['pub', 'publish', '--dry-run']
        : ['pub', 'publish', '--dry-run'];
    final executable = package.publishTool == PublishTool.flutter
        ? 'flutter'
        : 'dart';

    final getResult = await Process.start(
      executable,
      getArgs,
      workingDirectory: package.directory.path,
      mode: ProcessStartMode.inheritStdio,
    );
    final getExitCode = await getResult.exitCode;
    if (getExitCode != 0) {
      failures.add(package.name);
      stdout.writeln('Failed during `$executable ${getArgs.join(' ')}`.');
      continue;
    }

    final publishResult = await Process.start(
      executable,
      publishArgs,
      workingDirectory: package.directory.path,
      mode: ProcessStartMode.inheritStdio,
    );
    final publishExitCode = await publishResult.exitCode;
    if (publishExitCode != 0) {
      failures.add(package.name);
    }
  }
  return failures;
}

Future<List<String>> _packagesWithTrackedChanges({
  required String repoRoot,
  required List<PackageInfo> packages,
}) async {
  final dirtyPackages = <String>[];
  for (final package in packages) {
    final result = await Process.run('git', [
      'diff',
      '--name-only',
      'HEAD',
      '--',
      package.directory.path,
    ], workingDirectory: repoRoot);
    _ensureSuccess(
      result,
      'git diff --name-only HEAD -- ${package.directory.path}',
    );
    if ((result.stdout as String).trim().isNotEmpty) {
      dirtyPackages.add(package.name);
    }
  }
  return dirtyPackages;
}

Future<ProcessResult> _runGit(String repoRoot, List<String> args) async {
  final result = await Process.run('git', args, workingDirectory: repoRoot);
  _ensureSuccess(result, 'git ${args.join(' ')}');
  return result;
}

void _ensureSuccess(ProcessResult result, String command) {
  if (result.exitCode == 0) {
    return;
  }
  throw ProcessException(
    command,
    const [],
    '${result.stderr}',
    result.exitCode,
  );
}
