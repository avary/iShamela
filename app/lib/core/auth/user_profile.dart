/// Auth identity providers linked to a Firebase user.
enum AuthProviderKind { apple, google, email }

/// Profile snapshot derived from Firebase [User].
class UserProfile {
  const UserProfile({
    required this.uid,
    required this.email,
    required this.displayName,
    required this.photoUrl,
    required this.providers,
    required this.emailVerified,
  });

  final String uid;
  final String? email;
  final String? displayName;
  final String? photoUrl;
  final Set<AuthProviderKind> providers;
  final bool emailVerified;

  bool get hasEmailProvider => providers.contains(AuthProviderKind.email);

  UserProfile copyWith({
    String? uid,
    String? email,
    String? displayName,
    String? photoUrl,
    Set<AuthProviderKind>? providers,
    bool? emailVerified,
  }) {
    return UserProfile(
      uid: uid ?? this.uid,
      email: email ?? this.email,
      displayName: displayName ?? this.displayName,
      photoUrl: photoUrl ?? this.photoUrl,
      providers: providers ?? this.providers,
      emailVerified: emailVerified ?? this.emailVerified,
    );
  }

  Map<String, Object?> toJson() => {
        'uid': uid,
        'email': email,
        'displayName': displayName,
        'photoUrl': photoUrl,
        'providers': [for (final p in providers) p.name],
        'emailVerified': emailVerified,
      };

  /// Null when [json] is not a profile written by [toJson].
  static UserProfile? fromJson(Object? json) {
    if (json is! Map) return null;
    final uid = json['uid'];
    if (uid is! String || uid.isEmpty) return null;
    final names = json['providers'];
    return UserProfile(
      uid: uid,
      email: json['email'] as String?,
      displayName: json['displayName'] as String?,
      photoUrl: json['photoUrl'] as String?,
      providers: {
        if (names is List)
          for (final kind in AuthProviderKind.values)
            if (names.contains(kind.name)) kind,
      },
      emailVerified: json['emailVerified'] == true,
    );
  }
}
