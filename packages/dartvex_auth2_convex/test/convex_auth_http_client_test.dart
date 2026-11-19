import 'dart:async';
import 'dart:convert';

import 'package:dartvex_auth2_convex/dartvex_auth2_convex.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

import 'support.dart';

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
            .having((e) => e.message, 'message', isNot(contains('nope')))
            .having((e) => e.serverMessage, 'serverMessage', contains('nope'))
            .having((e) => e.statusCode, 'statusCode', 560)
            .having((e) => e.data, 'data', {'code': 'NOPE'}).having(
                (e) => e.logLines,
                'logLines',
                ['log line']).having((e) => e.retryable, 'retryable', isFalse)),
      );
    });

    test('server text never reaches the message or toString', () async {
      const sentinel = 'SENTINEL-rt_secret-password123';
      final responses = <http.Response>[
        // A gateway echoing the request.
        http.Response('<html>Bad gateway: $sentinel</html>', 502),
        // A Convex API error.
        http.Response(
          jsonEncode({'code': 'BadJsonBody', 'message': sentinel}),
          400,
        ),
        // A function that threw, with log lines.
        http.Response(
          jsonEncode({
            'status': 'error',
            'errorMessage': 'Uncaught Error: $sentinel',
            'logLines': ['[LOG] $sentinel'],
          }),
          560,
        ),
        // An error code that is not a short identifier.
        http.Response(jsonEncode({'code': sentinel}), 400),
      ];
      final seen = <ConvexAuthException>[];
      for (final response in responses) {
        final client = ConvexAuthHttpClient(
          deploymentUrl: 'https://test-app.convex.cloud',
          httpClient: MockClient((_) async => response),
        );
        try {
          await client.mutation('auth:refreshSession', {'refreshToken': 'rt'});
          fail('expected a ConvexAuthException');
        } on ConvexAuthException catch (error) {
          seen.add(error);
          expect(error.message, isNot(contains('SENTINEL')));
          expect(error.toString(), isNot(contains('SENTINEL')));
        }
      }

      expect(seen[0].statusCode, 502);
      expect(seen[0].message, contains('HTTP 502'));
      expect(seen[1].message, contains('(BadJsonBody)'));
      // The server's own text stays available on purpose-read fields.
      expect(seen[2].serverMessage, contains(sentinel));
      expect(seen[2].logLines.single, contains(sentinel));
    });

    test('plain http is only accepted for the local machine', () {
      for (final origin in <String>[
        'http://localhost:3210',
        'http://127.0.0.1:3210',
        'http://[::1]:3210',
        'http://10.0.2.2:3210',
      ]) {
        expect(
          ConvexAuthHttpClient(
            deploymentUrl: origin,
            httpClient: MockClient((_) async => http.Response('', 200)),
          ).deploymentUrl,
          origin,
        );
      }
      for (final origin in <String>[
        'http://192.168.1.20:3210',
        'http://test-app.convex.cloud',
        'http://localhost.example.com',
      ]) {
        expect(
          () => ConvexAuthHttpClient(deploymentUrl: origin),
          throwsA(
            isA<ArgumentError>().having(
              (error) => error.message,
              'message',
              contains('allowInsecureHttp'),
            ),
          ),
          reason: origin,
        );
        expect(
          ConvexAuthHttpClient(
            deploymentUrl: origin,
            allowInsecureHttp: true,
            httpClient: MockClient((_) async => http.Response('', 200)),
          ).deploymentUrl,
          origin,
        );
      }
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

    test('sessionId is the sub claim of the access token', () {
      final first = ConvexAuthSession.fromJson(bundle('a', session: 's1'));
      final rotated = ConvexAuthSession.fromJson(bundle('b', session: 's1'));
      final other = ConvexAuthSession.fromJson(bundle('c', session: 's2'));
      final opaque = ConvexAuthSession.fromJson(bundle('d'));

      expect(first.sessionId, 's1');
      expect(rotated.sessionId, 's1');
      expect(other.sessionId, 's2');
      expect(opaque.sessionId, isNull);
      expect(
        ConvexAuthSession.fromJson({
          ...bundle('e'),
          'accessToken': 'a.%%%.c',
        }).sessionId,
        isNull,
      );
    });

    test('rejects an incomplete bundle', () {
      expect(
        () => ConvexAuthSession.fromJson({'accessToken': 'jwt'}),
        throwsFormatException,
      );
    });
  });
}
