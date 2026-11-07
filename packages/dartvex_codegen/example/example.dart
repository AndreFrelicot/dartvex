/// Example: Generate type-safe Dart bindings from a Convex deployment.
///
/// Run from your project root:
/// ```bash
/// dart run dartvex_codegen generate \
///   --project ./backend \
///   --output ./lib/convex_api
/// ```
///
/// This runs `convex function-spec` in `./backend` (which reads the functions
/// deployed to its dev deployment, so keep `npx convex dev` running) and
/// generates typed query, mutation, and action helpers.
///
/// You can also generate from an exported spec:
/// ```bash
/// dart run dartvex_codegen generate \
///   --spec-file ./function_spec.json \
///   --output ./lib/convex_api
/// ```
///
/// For all commands and options:
/// ```bash
/// dart run dartvex_codegen --help
/// dart run dartvex_codegen generate --help
/// ```
void main() {
  // dartvex_codegen is a CLI tool — run it via `dart run dartvex_codegen`.
  //
  // Using the generated bindings (lib/convex_api/api.dart):
  //
  //   final client = ConvexClient('https://your-deployment.convex.cloud');
  //   final api = ConvexApi(client);
  //
  //   final messages = await api.messages.list();
  //   await api.messages.send(author: 'Andre', text: 'Hello');
  //
  //   final subscription = api.messages.listSubscribe();
  //   subscription.stream.listen((result) {
  //     switch (result) {
  //       case TypedQuerySuccess(:final value, :final hasPendingWrites):
  //         print('${value.length} messages (pending: $hasPendingWrites)');
  //       case TypedQueryLoading():
  //         print('loading');
  //       case TypedQueryError(:final message):
  //         print('error: $message');
  //     }
  //   });
  //
  print('Run: dart run dartvex_codegen --help');
}
