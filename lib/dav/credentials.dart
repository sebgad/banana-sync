import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Handles secure storage of Nextcloud credentials (username, password, base URL).
///
/// Provides methods to read and write credentials using FlutterSecureStorage.
class CredentialsStorage {
  /// Internal instance of FlutterSecureStorage for secure key-value storage.
  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  /// Retrieves the stored username from secure storage.
  ///
  /// Returns the username as a [String], or an empty string if not set.
  Future<String> getUsername() async =>
      (await _storage.read(key: 'username')) ?? '';

  /// Retrieves the stored password from secure storage.
  ///
  /// Returns the password as a [String], or an empty string if not set.
  Future<String> getPassword() async =>
      (await _storage.read(key: 'password')) ?? '';

  /// Retrieves the stored base URL from secure storage.
  ///
  /// Returns the base URL as a [String], or an empty string if not set.
  Future<String> getBaseUrl() async =>
      (await _storage.read(key: 'baseUrl')) ?? '';

  /// Stores the [username] in secure storage.
  Future<void> setUsername(String username) =>
      _storage.write(key: 'username', value: username);

  /// Stores the [password] in secure storage.
  Future<void> setPassword(String password) =>
      _storage.write(key: 'password', value: password);

  /// Stores the [baseUrl] in secure storage.
  Future<void> setBaseUrl(String baseUrl) =>
      _storage.write(key: 'baseUrl', value: baseUrl);

  /// Checks if all credentials (username, password, base URL) are present in secure storage.
  ///
  /// Returns `true` if all credentials are set, otherwise `false`.
  Future<bool> hasCredentials() async {
    final username = await getUsername();
    final password = await getPassword();
    final baseUrl = await getBaseUrl();
    return username != '' && password != '' && baseUrl != '';
  }
}
