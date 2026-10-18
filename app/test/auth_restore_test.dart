import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ishamela/core/auth/auth_state.dart';
import 'package:ishamela/core/auth/firebase_bootstrap.dart';
import 'package:ishamela/core/auth/profile_cache.dart';
import 'package:ishamela/core/auth/user_profile.dart';
import 'package:ishamela/core/providers.dart';
import 'package:ishamela/core/sync/api_client.dart';
import 'package:ishamela/core/sync/auth_interceptor.dart';
import 'package:ishamela/core/sync/token_store.dart';

typedef _Route = Future<ResponseBody> Function(RequestOptions options);

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.routes);

  final Map<String, _Route> routes;
  final paths = <String>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    final path = options.uri.path;
    paths.add(path);
    final route = routes[path];
    if (route == null) throw StateError('unexpected request $path');
    return route(options);
  }

  @override
  void close({bool force = false}) {}
}

const _base = 'https://api.example.test';

ResponseBody _json(int status, Object body) => ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );

_Route _status(int status, Object body) => (_) async => _json(status, body);

Future<ResponseBody> _offline(RequestOptions options) async {
  throw DioException(
    requestOptions: options,
    type: DioExceptionType.connectionError,
  );
}

const _cached = UserProfile(
  uid: 'u1',
  email: 'reader@example.test',
  displayName: 'Cached Name',
  photoUrl: null,
  providers: {},
  emailVerified: true,
);

class _Harness {
  _Harness(Map<String, _Route> routes) : adapter = _FakeAdapter(routes) {
    container = ProviderContainer(
      overrides: [
        tokenStoreProvider.overrideWithValue(tokens),
        profileCacheProvider.overrideWithValue(cache),
        syncApiProvider.overrideWith((ref) {
          final dio = Dio(BaseOptions(baseUrl: _base))
            ..httpClientAdapter = adapter;
          dio.interceptors.add(
            AuthInterceptor(
              tokens: tokens,
              dio: dio,
              refreshPath: '/v1/auth/refresh',
              onSignedOut: () => ref.read(authProvider.notifier).forceGuest(),
            ),
          );
          return IshamelaApi(dio, baseUrl: _base);
        }),
      ],
    );
  }

  final _FakeAdapter adapter;
  final tokens = MemoryTokenStore();
  final cache = MemoryProfileCache();
  late final ProviderContainer container;

  void signedInWithCache() {
    tokens
      ..access = 'access'
      ..refresh = 'refresh';
    cache.profile = _cached;
  }

  Future<AuthStatus> restore() async {
    container.read(authProvider);
    await container.read(authProvider.notifier).restoreSession();
    return container.read(authProvider);
  }
}

void main() {
  setUp(() => firebaseReady = false);

  test('offline restore keeps the cached profile and the tokens', () async {
    final h = _Harness({'/v1/me': _offline});
    addTearDown(h.container.dispose);
    h.signedInWithCache();

    final status = await h.restore();

    expect(status, isA<AuthSignedIn>());
    expect(status.profileOrNull?.displayName, 'Cached Name');
    expect(h.tokens.refresh, 'refresh');
    expect(h.cache.profile, isNotNull);
  });

  test('a successful /v1/me refreshes the cached profile', () async {
    final h = _Harness({
      '/v1/me': _status(200, {
        'id': 'u1',
        'email': 'reader@example.test',
        'displayName': 'Server Name',
      }),
    });
    addTearDown(h.container.dispose);
    h.signedInWithCache();

    final status = await h.restore();

    expect(status.profileOrNull?.displayName, 'Server Name');
    expect(h.cache.profile?.displayName, 'Server Name');
  });

  test('a rejected session signs out and clears cache and tokens', () async {
    final unauthorized = _status(401, {
      'error': {'code': 'UNAUTHORIZED', 'message': 'no'},
    });
    final h = _Harness({
      '/v1/me': unauthorized,
      '/v1/auth/refresh': _status(401, {
        'error': {'code': 'TOKEN_INVALID', 'message': 'no'},
      }),
    });
    addTearDown(h.container.dispose);
    h.signedInWithCache();

    final status = await h.restore();

    expect(status, isA<AuthGuest>());
    expect(h.cache.profile, isNull);
    expect(h.tokens.refresh, isNull);
  });

  test('an unreachable refresh keeps the session', () async {
    final h = _Harness({
      '/v1/me': _status(401, {
        'error': {'code': 'UNAUTHORIZED', 'message': 'expired'},
      }),
      '/v1/auth/refresh': _offline,
    });
    addTearDown(h.container.dispose);
    h.signedInWithCache();

    final status = await h.restore();

    expect(h.adapter.paths, contains('/v1/auth/refresh'));
    expect(status, isA<AuthSignedIn>());
    expect(status.profileOrNull?.displayName, 'Cached Name');
    expect(h.tokens.refresh, 'refresh');
    expect(h.cache.profile, isNotNull);
  });

  test('without a saved session the stale cache is dropped offline', () async {
    final h = _Harness({});
    addTearDown(h.container.dispose);
    h.cache.profile = _cached;

    final status = await h.restore();

    expect(status, isA<AuthGuest>());
    expect(h.cache.profile, isNull);
    expect(h.adapter.paths, isEmpty);
  });

  test('UserProfile survives a JSON round trip', () {
    const profile = UserProfile(
      uid: 'u2',
      email: null,
      displayName: 'Name',
      photoUrl: null,
      providers: {AuthProviderKind.google},
      emailVerified: true,
    );
    final back = UserProfile.fromJson(jsonDecode(jsonEncode(profile.toJson())));
    expect(back?.uid, 'u2');
    expect(back?.displayName, 'Name');
    expect(back?.providers, {AuthProviderKind.google});
    expect(UserProfile.fromJson({'uid': ''}), isNull);
  });
}
