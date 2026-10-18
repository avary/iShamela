import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:ishamela/core/auth/user_profile.dart';

/// Last profile from `GET /v1/me`, so a saved session restores without network.
abstract class ProfileCache {
  Future<UserProfile?> read();
  Future<void> write(UserProfile profile);
  Future<void> clear();
}

class MemoryProfileCache implements ProfileCache {
  UserProfile? profile;

  @override
  Future<UserProfile?> read() async => profile;

  @override
  Future<void> write(UserProfile profile) async => this.profile = profile;

  @override
  Future<void> clear() async => profile = null;
}

class SecureProfileCache implements ProfileCache {
  SecureProfileCache({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static const key = 'ishamela.profile';

  final FlutterSecureStorage _storage;

  @override
  Future<UserProfile?> read() async {
    final raw = await _storage.read(key: key);
    if (raw == null || raw.isEmpty) return null;
    try {
      return UserProfile.fromJson(jsonDecode(raw));
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> write(UserProfile profile) =>
      _storage.write(key: key, value: jsonEncode(profile.toJson()));

  @override
  Future<void> clear() => _storage.delete(key: key);
}
