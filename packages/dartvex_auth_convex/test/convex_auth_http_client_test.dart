import 'dart:async';
import 'dart:convert';

import 'package:dartvex_auth_convex/dartvex_auth_convex.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  group('ConvexAuthHttpClient', () {
    test('posts the mutation in the Convex HTTP API format', () async {
      late http.Request seen;
      final client = ConvexAuthHttpClient(
        deploymentUrl: 'https://test-app.convex.cloud/',
        httpClient: MockClient((request) async {
          seen = request;
          return http.Response(
            jsonEncode({
              'status': 'success',
              'value': {'ok': true},
              'logLines': <String>[],
            }),
            200,
          );
        }),
      );

      final result =
          await client.mutation('auth:refreshSession', {'refreshToken': 'rt'});

      expect(result, {'ok': true});
      expect(seen.method, 'POST');
      expect(seen.url.toString(), 'https://test-app.convex.cloud/api/mutation');
      expect(seen.headers['Content-Type'], startsWith('application/json'));
      expect(seen.headers['Convex-Client'], startsWith('dartvex-'));
      expect(jsonDecode(seen.body), {
        'path': 'auth:refreshSession',
        'format': 'convex_encoded_json',
        'args': [
          {'refreshToken': 'rt'},
        ],
      });
    });

    test('a function error (HTTP 560) throws with its ConvexError data',
        () async {
      final client = ConvexAuthHttpClient(
        deploymentUrl: 'https://test-app.convex.cloud',
        httpClient: MockClient((request) async => http.Response(
              jsonEncode({
                'status': 'error',
                'errorMessage': 'Uncaught ConvexError: nope',
                'errorData': {'code': 'NOPE'},
                'logLines': ['log line'],
              }),
              560,
            )),
      );

      await expectLater(
        client.mutation('auth:signOut', {'refreshToken': 'rt'}),
        throwsA(isA<ConvexAuthException>()
            .having((e) => e.message, 'message', contains('nope'))
            .having((e) => e.data, 'data', {'code': 'NOPE'}).having(
                (e) => e.logLines,
                'logLines',
                ['log line']).having((e) => e.retryable, 'retryable', isFalse)),
      );
    });

    test('HTTP 5xx and 429 are retryable, 4xx is not', () async {
      Future<ConvexAuthException> failWith(int status) async {
        final client = ConvexAuthHttpClient(
          deploymentUrl: 'https://test-app.convex.cloud',
          httpClient:
              MockClient((request) async => http.Response('boom', status)),
        );
        try {
          await client.mutation('auth:signOut');
        } on ConvexAuthException catch (error) {
          return error;
        }
        fail('expected a ConvexAuthException');
      }

      expect((await failWith(503)).retryable, isTrue);
      expect((await failWith(429)).retryable, isTrue);
      expect((await failWith(400)).retryable, isFalse);
    });

    test('network errors and timeouts are retryable', () async {
      final offline = ConvexAuthHttpClient(
        deploymentUrl: 'https://test-app.convex.cloud',
        httpClient: MockClient(
            (request) async => throw http.ClientException('offline')),
      );
      await expectLater(
        offline.mutation('auth:signOut'),
        throwsA(isA<ConvexAuthException>()
            .having((e) => e.retryable, 'retryable', isTrue)),
      );

      final slow = ConvexAuthHttpClient(
        deploymentUrl: 'https://test-app.convex.cloud',
        requestTimeout: const Duration(milliseconds: 10),
        httpClient: MockClient((request) => Completer<http.Response>().future),
      );
      await expectLater(
        slow.mutation('auth:signOut'),
        throwsA(isA<ConvexAuthException>()
            .having((e) => e.message, 'message', contains('timed out'))
            .having((e) => e.retryable, 'retryable', isTrue)),
      );
    });

    test('rejects a deployment URL with a path', () {
      expect(
        () => ConvexAuthHttpClient(
            deploymentUrl: 'https://test-app.convex.cloud/api'),
        throwsArgumentError,
      );
    });
  });

  group('ConvexAuthSession', () {
    test('round-trips through JSON', () {
      final session = ConvexAuthSession.fromJson({
        'accessToken': 'jwt',
        'refreshToken': 'rt',
        'refreshTokenExpiresAt': 1893456000000,
        'userId': 'u1',
      });
      expect(session.refreshTokenExpiresAt.isUtc, isTrue);
      expect(ConvexAuthSession.fromJson(session.toJson()), session);
      expect(session.toString(), isNot(contains('rt')));
    });

    test('rejects an incomplete bundle', () {
      expect(
        () => ConvexAuthSession.fromJson({'accessToken': 'jwt'}),
        throwsFormatException,
      );
    });
  });
}
