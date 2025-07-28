import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'nextcloud_file.dart'; // Assuming your data class is here

String remoteToLocalPath(Uri uri, String localPath) {
  final uriList = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  return p.join(localPath, uriList.sublist(4).toString());
}

String remoteToBasePath(String uri) {
  final uriList = Uri.parse(
    uri,
  ).pathSegments.where((s) => s.isNotEmpty).toList();
  final basePath = uriList.sublist(4).join('/');
  return Uri.decodeFull(basePath);
}

String baseToRemotePath(String uriPath, String basePath) {
  final encoded = Uri.encodeFull(uriPath).replaceAll('+', '%20');
  return '$basePath/$encoded';
}

String localPathToRemote(
  String baseUri,
  Directory localRootPath,
  File localFile,
) {
  final relative = p.relative(localFile.path, from: localRootPath.path);
  final encoded = Uri.encodeFull(relative).replaceAll('+', '%20');
  return '$baseUri/$encoded';
}

void createNextcloudFileListFromQuery({
  required Database dbConnection,
  required String sqlString,
  required List<NextcloudFile> nextCloudFiles,
  required String remoteBase,
  required String localBase,
}) {
  final ResultSet resultSet = dbConnection.select(sqlString);

  for (final row in resultSet) {
    nextCloudFiles.add(
      NextcloudFile(
        remoteUrl: baseToRemotePath(row['path'] as String, remoteBase),
        remoteLastModified: row['remoteLastModified'] as int? ?? 0,
        localPath: p.join(localBase, row['path'] as String),
        localLastModified: row['localLastModified'] as int? ?? 0,
        captured: row['captured'] as int? ?? 0,
      ),
    );
  }
}
