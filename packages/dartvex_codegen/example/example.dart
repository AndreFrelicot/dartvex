// ignore_for_file: unused_local_variable
/// Example: Generate type-safe Dart bindings from a Convex deployment.
///
/// Run from your project root:
/// ```bash
/// dart run dartvex_codegen --url https://your-app.convex.cloud
/// ```
///
/// This generates a `convex_api.dart` file with typed query/mutation helpers.
///
/// For more options:
/// ```bash
/// dart run dartvex_codegen --help
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
  //       client.mutation('messages:send', {'body': body, 'author': author});
  //   }
  //
  print('Run: dart run dartvex_codegen --url https://your-app.convex.cloud');
}
