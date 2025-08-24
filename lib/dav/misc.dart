import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'nextcloud_file.dart';

/// Converts a full remote WebDAV URI to a relative base path.
///
/// Skips the first 4 path segments (e.g., protocol, host, user, etc.) and joins the rest.
/// Returns '/' if the resulting path is empty.
///
/// Example:
///   remoteToBasePath('https://host/remote.php/dav/files/user/Documents/file.txt')
///   -> 'Documents/file.txt'
///
/// [uri] The full remote WebDAV URI as a string.
/// Returns the decoded relative path as a string.
String remoteToBasePath(String uri) {
  final uriList = Uri.parse(
    uri,
  ).pathSegments.where((s) => s.isNotEmpty).toList();
  final basePath = uriList.sublist(4).join('/');
  if (basePath.isEmpty) {
    return '/';
  }
  return Uri.decodeFull(basePath);
}

/// Populates a list of NextcloudSyncFile objects from a database query result.
///
/// Executes [sqlString] on [dbConnection], and for each row, creates a NextcloudSyncFile
/// with remote and local paths, last modified times, and captured timestamp.
/// The [remoteBase] and [localBase] are used as prefixes for constructing full paths.
///
/// Parameters:
///   - dbConnection: The SQLite database connection.
///   - sqlString: The SQL SELECT query to execute.
///   - nextCloudFiles: The list to populate with NextcloudSyncFile objects.
///   - remoteBase: The base remote URL prefix.
///   - localBase: The base local path prefix.
Future<void> createNextcloudFileListFromQuery({
  required Database dbConnection,
  required String sqlString,
  required List<NextcloudSyncFile> nextCloudFiles,
  required String remoteBase,
  required String localBase,
}) async {
  final List<Map<String, dynamic>> resultSet = await dbConnection.rawQuery(
    sqlString,
  );

  for (final row in resultSet) {
    nextCloudFiles.add(
      NextcloudSyncFile(
        remoteUrl: "$remoteBase/${row['path']}",
        remoteLastModified: row['remoteLastModified'] as int? ?? 0,
        localPath: p.join(localBase, row['path'] as String),
        localLastModified: row['localLastModified'] as int? ?? 0,
        captured: row['captured'] as int? ?? 0,
      ),
    );
  }
}
