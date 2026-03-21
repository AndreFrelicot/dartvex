/// Code generation APIs for producing typed Dart bindings from Convex specs.
library;

export 'src/cli/config.dart';
export 'src/cli/generate_command.dart' show GenerateCommand, runConvexCodegen;
export 'src/cli/process_runner.dart';
export 'src/generator/dart_generator.dart';
export 'src/generator/file_emitter.dart';
export 'src/generator/naming.dart';
export 'src/spec/function_spec.dart';
export 'src/spec/spec_parser.dart';
export 'src/types/dart_type.dart';
export 'src/types/type_mapper.dart';
