// ignore_for_file: unused_local_variable
/// Example: Generate type-safe Dart bindings from a Convex deployment.
///
/// Run from your project root:
/// ```bash
/// dart run dartvex_codegen generate \
///   --project ./convex \
///   --output ./lib/convex_api
/// ```
///
/// This runs `convex function-spec` and generates typed query, mutation, and
/// action helpers.
///
/// You can also generate from an exported spec:
/// ```bash
/// dart run dartvex_codegen generate \
///   --spec-file ./function_spec.json \
///   --output ./lib/convex_api
/// ```
///
/// For all options:
/// ```bash
/// dart run dartvex_codegen generate --help
/// ```
void main() {
  // dartvex_codegen is a CLI tool — run it via `dart run dartvex_codegen`.
  //
  // Example output (convex_api.dart):
  //
  //   class MessagesApi {
  //     final ConvexClient client;
  //     MessagesApi(this.client);
  //
  //     Future<List<Message>> list({int? limit}) =>
  //       client.query('messages:list', {'limit': limit});
  //
  //     Future<void> send({required String body, required String author}) =>
  //       client.mutate('messages:send', {'body': body, 'author': author});
  //   }
  //
  print('Run: dart run dartvex_codegen generate --help');
}
