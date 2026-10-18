import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import 'package:ishamela/core/auth/auth_errors.dart';
import 'package:ishamela/core/auth/firebase_bootstrap.dart';
import 'package:ishamela/core/auth/auth_state.dart';
import 'package:ishamela/core/auth/provider_sign_in.dart';
import 'package:ishamela/core/auth/user_profile.dart';
import 'package:ishamela/core/config.dart';
import 'package:ishamela/core/providers.dart';
import 'package:ishamela/core/sync/api_client.dart';

/// Apple Sign In is available on iOS, macOS, and web — hidden on Android.
bool get supportsAppleSignIn =>
    kIsWeb ||
    defaultTargetPlatform == TargetPlatform.iOS ||
    defaultTargetPlatform == TargetPlatform.macOS;

/// Session follows the project access token and `GET /v1/me` (SPEC-027 / SPEC-028).
class AuthController extends Notifier<AuthStatus> {
  GoogleSignIn? _google;
  Future<void>? _restoring;
  bool _deviceRegistered = false;

  /// `error.code` values that mean the server no longer accepts this session.
  static const _rejectedCodes = {'UNAUTHORIZED', 'TOKEN_INVALID'};

  @override
  AuthStatus build() {
    Future<void>.microtask(restoreSession);
    return const AuthGuest();
  }

  /// Shows the cached profile at once, then confirms it with `GET /v1/me`.
  /// Safe to call on every resume or reconnect; guests without a saved
  /// session never touch the network.
  Future<void> restoreSession() {
    return _restoring ??= _restore().whenComplete(() => _restoring = null);
  }

  Future<void> _restore() async {
    try {
      final hasFirebaseUser =
          firebaseReady && FirebaseAuth.instance.currentUser != null;
      if (!hasFirebaseUser) {
        final refresh = await ref.read(tokenStoreProvider).readRefresh();
        if (!ref.mounted) return;
        if (refresh == null || refresh.isEmpty) {
          if (state is AuthGuest) await ref.read(profileCacheProvider).clear();
          return;
        }
      }
      if (state is AuthGuest) {
        final cached = await ref.read(profileCacheProvider).read();
        if (!ref.mounted) return;
        if (cached != null && state is AuthGuest) {
          state = AuthSignedIn(cached);
        }
      }
      if (await revalidate() && !_deviceRegistered) {
        _deviceRegistered = true;
        await _registerDevice();
      }
    } catch (_) {}
  }

  /// True when the server confirmed the session. Network failures keep the
  /// current state; only a rejected session drops to guest.
  Future<bool> revalidate() async {
    try {
      final profile = await ref.read(syncApiProvider).getMe();
      if (!ref.mounted) return false;
      await _signedIn(_profile(profile));
      return true;
    } on ApiAuthException catch (error) {
      if (ref.mounted && _rejectedCodes.contains(error.code)) {
        await forceGuest();
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// The server rejected the session (SPEC-028 §8); tokens are already gone.
  Future<void> forceGuest() async {
    try {
      await ref.read(profileCacheProvider).clear();
    } catch (_) {}
    _deviceRegistered = false;
    if (ref.mounted) state = const AuthGuest();
  }

  Future<void> _signedIn(UserProfile profile) async {
    state = AuthSignedIn(profile);
    try {
      await ref.read(profileCacheProvider).write(profile);
    } catch (_) {}
  }

  UserProfile _profile(ApiProfile profile) {
    return UserProfile(
      uid: profile.id,
      email: profile.email,
      displayName: profile.displayName,
      photoUrl: null,
      providers: const {},
      emailVerified: true,
    );
  }

  /// Profile first, then the library upload. The button returns after `GET /v1/me`.
  Future<void> _finishProviderSignIn() async {
    final session = ref.read(accountSessionProvider);
    await session.adoptFirebase();
    final profile = await ref.read(syncApiProvider).getMe();
    await _signedIn(_profile(profile));
    session.replayInBackground();
    _deviceRegistered = true;
    unawaited(_registerDevice());
  }

  Future<void> _registerDevice() async {
    try {
      await ref.read(accountSessionProvider).registerDevice();
    } catch (_) {}
  }

  Future<void> _adopted() async {
    final profile = await ref.read(syncApiProvider).getMe();
    await _signedIn(_profile(profile));
    _deviceRegistered = true;
    await _registerDevice();
  }

  Future<void> requestEmailCode(String email) {
    return ref.read(syncApiProvider).requestOtp(email.trim());
  }

  Future<void> verifyEmailCode({
    required String email,
    required String code,
  }) async {
    await ref.read(accountSessionProvider).signInWithEmailCode(
      email: email.trim(),
      code: code,
    );
    await _adopted();
  }

  Future<void> signInGoogle() async {
    if (!firebaseReady) {
      throw AuthUnavailable('Authentication is unavailable');
    }
    if (kIsWeb) {
      await FirebaseAuth.instance.signInWithPopup(GoogleAuthProvider());
    } else {
      final applePlatform =
          defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS;
      _google ??= GoogleSignIn(
        clientId: applePlatform ? googleIosClientId : null,
        // Android and Apple platforms mint the ID token for the web client.
        // iOS still puts the iOS client ID in `aud`.
        serverClientId: googleWebClientId,
        scopes: const ['email', 'profile'],
      );
      final account = await _google!.signIn();
      if (account == null) return;
      final googleAuth = await account.authentication;
      final idToken = googleAuth.idToken;
      if (idToken == null || idToken.isEmpty) {
        throw AuthUnavailable('Google Sign-In did not return an ID token');
      }
      await FirebaseAuth.instance.signInWithCredential(
        GoogleAuthProvider.credential(
          idToken: idToken,
          accessToken: googleAuth.accessToken,
        ),
      );
    }
    await _finishProviderSignIn();
  }

  Future<void> signInApple() async {
    if (!supportsAppleSignIn) {
      throw AuthUnavailable('Apple Sign In is not available on this platform');
    }
    if (!firebaseReady) {
      throw AuthUnavailable('Authentication is unavailable');
    }
    if (kIsWeb) {
      final apple = OAuthProvider('apple.com')
        ..addScope('email')
        ..addScope('name');
      await FirebaseAuth.instance.signInWithPopup(apple);
      await _finishProviderSignIn();
      return;
    }
    // Firebase rejects an Apple credential that has no nonce, and the call
    // sits until that check times out. Apple gets the hash; Firebase gets the raw value.
    final rawNonce = generateAppleNonce();
    final apple = await SignInWithApple.getAppleIDCredential(
      scopes: [
        AppleIDAuthorizationScopes.email,
        AppleIDAuthorizationScopes.fullName,
      ],
      nonce: sha256OfNonce(rawNonce),
    );
    final identity = apple.identityToken;
    if (identity == null || identity.isEmpty) {
      throw AuthUnavailable('Apple Sign-In did not return an identity token');
    }
    final credential = OAuthProvider('apple.com').credential(
      idToken: identity,
      rawNonce: rawNonce,
    );
    await FirebaseAuth.instance.signInWithCredential(credential);
    await _finishProviderSignIn();
    final given = apple.givenName;
    final family = apple.familyName;
    final name = [given, family].whereType<String>().join(' ').trim();
    final current = state.profileOrNull?.displayName;
    if (name.isNotEmpty && (current == null || current.isEmpty)) {
      await updateDisplayName(name);
    }
  }

  Future<void> signOut({bool keepData = true}) async {
    try {
      await ref.read(accountSessionProvider).signOut(keepData: keepData);
    } catch (_) {}
    try {
      await _google?.signOut();
    } catch (_) {}
    try {
      if (firebaseReady) await FirebaseAuth.instance.signOut();
    } catch (_) {}
    await forceGuest();
  }

  Future<void> updateDisplayName(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed.length > 40) {
      throw ArgumentError('displayName must be 1–40 characters');
    }
    if (state is! AuthSignedIn) throw AuthUnavailable('Not signed in');
    final profile = await ref.read(syncApiProvider).patchMe(trimmed);
    await _signedIn(_profile(profile));
  }

  /// Deletes the account and the synced rows on this device.
  Future<void> deleteAccount() async {
    if (state is! AuthSignedIn) throw AuthUnavailable('Not signed in');
    await ref.read(accountSessionProvider).deleteAccount();
    await forceGuest();
  }
}
