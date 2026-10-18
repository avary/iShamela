import 'package:dio/dio.dart';

import 'package:ishamela/core/sync/token_store.dart';

/// Result of one shared token refresh.
sealed class _Refresh {
  const _Refresh();
}

final class _Refreshed extends _Refresh {
  const _Refreshed();
}

/// The server rejected the refresh token; the session is gone.
final class _Rejected extends _Refresh {
  const _Rejected();
}

/// The server could not be reached; tokens are kept for a later retry.
final class _Unreachable extends _Refresh {
  const _Unreachable(this.error);
  final Object error;
}

/// Attaches the access token and retries once after a shared refresh (SPEC-028 §8).
class AuthInterceptor extends Interceptor {
  AuthInterceptor({
    required this.tokens,
    required this.dio,
    required this.refreshPath,
    required this.onSignedOut,
    this.readFirebaseToken,
    this.readDeviceId,
  });

  final TokenStore tokens;
  final Dio dio;
  final String refreshPath;
  final Future<void> Function() onSignedOut;

  /// SPEC-032. When this returns a token, it replaces the project access JWT.
  final Future<String?> Function()? readFirebaseToken;
  final Future<String?> Function()? readDeviceId;

  Future<_Refresh>? _refreshing;

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    if (options.extra['skipAuth'] == true) {
      handler.next(options);
      return;
    }
    final firebaseToken = await readFirebaseToken?.call();
    if (firebaseToken != null && firebaseToken.isNotEmpty) {
      options.extra['firebaseAuth'] = true;
      options.headers['Authorization'] = 'Bearer $firebaseToken';
      final deviceId = await readDeviceId?.call();
      if (deviceId != null && deviceId.isNotEmpty) {
        options.headers['X-Device-Id'] = deviceId;
      }
      handler.next(options);
      return;
    }
    final access = await tokens.readAccess();
    if (access != null && access.isNotEmpty) {
      options.headers['Authorization'] = 'Bearer $access';
    }
    handler.next(options);
  }

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final status = err.response?.statusCode;
    final options = err.requestOptions;
    if (status == 401 && options.extra['firebaseAuth'] == true) {
      await _signOut();
      handler.next(err);
      return;
    }
    if (status != 401 ||
        options.extra['skipAuth'] == true ||
        options.extra['retried'] == true) {
      if (status == 401 && options.extra['skipAuth'] != true) {
        await _signOut();
      }
      handler.next(err);
      return;
    }
    final outcome = await (_refreshing ??= _refresh().whenComplete(() {
      _refreshing = null;
    }));
    switch (outcome) {
      case _Rejected():
        handler.next(err);
        return;
      case _Unreachable(:final error):
        // A network failure, not the original 401: the session is still valid.
        handler.next(
          error is DioException
              ? error.copyWith(requestOptions: options)
              : DioException(
                  requestOptions: options,
                  type: DioExceptionType.connectionError,
                  error: error,
                ),
        );
        return;
      case _Refreshed():
        break;
    }
    try {
      options.extra['retried'] = true;
      final access = await tokens.readAccess();
      if (access != null) {
        options.headers['Authorization'] = 'Bearer $access';
      }
      final response = await dio.fetch<dynamic>(options);
      handler.resolve(response);
    } on DioException catch (retry) {
      handler.next(retry);
    }
  }

  Future<_Refresh> _refresh() async {
    final refresh = await tokens.readRefresh();
    if (refresh == null || refresh.isEmpty) {
      await _signOut();
      return const _Rejected();
    }
    try {
      final response = await dio.post<Map<String, dynamic>>(
        refreshPath,
        data: {'refreshToken': refresh},
        options: Options(extra: const {'skipAuth': true}),
      );
      final body = response.data;
      final access = body?['accessToken'] as String?;
      final next = body?['refreshToken'] as String?;
      if (access == null || next == null) {
        await _signOut();
        return const _Rejected();
      }
      await tokens.write(access: access, refresh: next);
      return const _Refreshed();
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      if (status == 400 || status == 401 || status == 403) {
        await _signOut();
        return const _Rejected();
      }
      return _Unreachable(error);
    } catch (error) {
      return _Unreachable(error);
    }
  }

  Future<void> _signOut() async {
    await tokens.clear();
    await onSignedOut();
  }
}
