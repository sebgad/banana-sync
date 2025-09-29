import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:banana_sync/dav/dav_sync.dart';
import 'package:intl/intl.dart';
import 'package:banana_sync/dav/misc.dart';
import 'package:banana_sync/dav/nextcloud_file.dart';
import 'package:pool/pool.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:logger/logger.dart';

/// Represents a root folder sync configuration in the Nextcloud database.
///
/// Each instance links a remote root path (on Nextcloud) to a local root path (on disk),
/// and has a unique [rootFolderId] as its database primary key.
class RootPath {
  /// The remote root path on Nextcloud (e.g., 'Documents' or 'Photos').
  final String remoteRootPath;

  /// The local root path on disk where files are synced.
  final String localRootPath;

  /// The unique database ID for this root folder sync entry.
  final int rootFolderId;

  final List<String> allowedFileExtensions;

  /// Creates a new root folder sync configuration.
  RootPath({
    required this.remoteRootPath,
    required this.localRootPath,
    required this.rootFolderId,
    required this.allowedFileExtensions,
  });
}

/// Handles synchronization between local folders and Nextcloud via WebDAV.
///
/// This class manages database operations, file transfers (download/upload), conflict resolution,
/// and sync logic for multiple root folders. It interacts with Nextcloud's WebDAV API to keep
/// local and remote files in sync, using a SQLite database to track file states and changes.
///
/// Key responsibilities:
/// - Initialize and manage the sync database
/// - Add/delete root sync folders
/// - Fetch remote file lists via WebDAV PROPFIND
/// - Update local/remote file lists in the database
/// - Download/upload files as needed
/// - Resolve sync conflicts and handle deletions
/// - Provide a single `sync()` method to synchronize all configured folders
class NextcloudDAV {
  late String baseUrl;
  late String username;
  late String password;
  late String remoteUrl;
  final File databasePath;

  late Database db;
  late String authHeader;

  bool hasLogin = false;
  int captured = 0;

  final logger = Logger();

  NextcloudDAV({required this.databasePath});

  /// Initializes the SQLite database connection.
  ///
  /// [databasePath] The file path to the SQLite database.
  Future<void> initDb() async {
    db = await openDatabase(databasePath.path);
    await createSyncDatabase();
  }

  /// Checks if the remote server is a Nextcloud instance by looking for Nextcloud-specific headers or content.
  Future<bool> isNextcloudServer() async {
    final client = HttpClient();
    bool isNextcloud = false;
    try {
      client.badCertificateCallback =
          (X509Certificate cert, String host, int port) {
            logger.e('Self-signed or invalid certificate detected for $host');
            return false;
          };
      final url = Uri.parse(baseUrl);
      final request = await client.getUrl(url);
      request.headers.set('Authorization', authHeader);
      final response = await request.close();
      // Check for Nextcloud header
      if (response.headers.value('X-Nextcloud') != null) {
        isNextcloud = true;
      } else {
        // Fallback: check for Nextcloud branding in HTML
        final body = await response.transform(utf8.decoder).join();
        if (body.contains('nextcloud') || body.contains('Nextcloud')) {
          isNextcloud = true;
          logger.i('Nextcloud branding found in HTML content.');
        }
      }
    } catch (e) {
      logger.e('Error checking Nextcloud server: $e');
    } finally {
      client.close();
    }
    if (!isNextcloud) {
      logger.e('Remote server does not appear to be a Nextcloud instance.');
    }
    return isNextcloud;
  }

  /// Adds a new root folder sync configuration to the database.
  /// [remoteRootPath] The remote root path on Nextcloud.
  /// [localRootPath] The local root path on disk.
  Future<void> addRootPath(
    String remoteRootPath,
    String localRootPath,
    List<String> allowedFileExtensions,
  ) async {
    // Normalize extensions to lowercase
    allowedFileExtensions = allowedFileExtensions
        .map((e) => e.toLowerCase())
        .toList();

    db.execute('''
      INSERT INTO rootFolder (remoteRootPath, localRootPath, allowedFileExtensions)
      VALUES ("$remoteRootPath", "$localRootPath", "${allowedFileExtensions.join(',')}")
    ''');
    logger.i(
      'Added root path: $remoteRootPath -> $localRootPath, allowedFileExtensions: $allowedFileExtensions',
    );
  }

  /// Deletes a root folder sync configuration from the database.
  /// [rootFolderId] The unique ID of the root folder to delete.
  Future<void> deleteRootPathById(int rootFolderId) async {
    // Delete entries from syncTable where rootFolderId matches
    db.execute('DELETE FROM syncTable WHERE rootFolderId = $rootFolderId');
    db.execute('''DELETE FROM rootFolder WHERE id = $rootFolderId''');
  }

  /// Retrieves a list of all root folder sync configurations from the database.
  Future<List<RootPath>> getRootPaths() async {
    final result = await db.query('rootFolder');
    return result.map((row) {
      final allowedExtensionString = row['allowedFileExtensions'] as String;
      final allowedExtensions = allowedExtensionString.split(',');

      return RootPath(
        remoteRootPath: row['remoteRootPath'] as String,
        localRootPath: row['localRootPath'] as String,
        rootFolderId: row['id'] as int,
        allowedFileExtensions: allowedExtensions,
      );
    }).toList();
  }

  /// Creates the synchronization database tables.
  Future<void> createSyncDatabase() async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS syncTable (
        rootFolderId INTEGER NOT NULL,
        path TEXT NOT NULL,
        remoteLastModified INTEGER,
        remoteLastModifiedPrev INTEGER,
        existsRemote BOOLEAN DEFAULT FALSE,
        localLastModified INTEGER,
        localLastModifiedPrev INTEGER,
        existsLocal BOOLEAN DEFAULT FALSE,
        synced BOOLEAN DEFAULT FALSE,
        captured INTEGER,
        PRIMARY KEY (rootFolderId, path)
      );
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS rootFolder (
        id INTEGER PRIMARY KEY,
        remoteRootPath TEXT NOT NULL,
        localRootPath TEXT NOT NULL,
        allowedFileExtensions TEXT NOT NULL DEFAULT '.*'
      );
    ''');
  }

  /// Begins a new synchronization session for the specified root folder.
  void begin(int rootFolderId) {
    db.execute('''
      UPDATE syncTable
      SET existsRemote = FALSE, existsLocal = FALSE
      WHERE rootFolderId = $rootFolderId
    ''');

    captured = DateTime.now().millisecondsSinceEpoch;
  }

  void setLogin(String username, String password, String baseUrl) {
    this.username = username;
    this.password = password;
    this.baseUrl = baseUrl;
    remoteUrl = '$baseUrl/remote.php/dav/files/$username';
    authHeader = 'Basic ${base64Encode(utf8.encode('$username:$password'))}';
    hasLogin = true;
  }

  /// Retrieves a list of remote files and folders from the Nextcloud server using WebDAV PROPFIND.
  ///
  /// Sends a PROPFIND request to the specified [remoteRootPath] on the Nextcloud server,
  /// with the given [depth] (default: 20). Parses the XML response and returns a list
  /// of [NextcloudDavProp] objects representing files and folders found at the remote path.
  ///
  /// Parameters:
  /// - [remoteRootPath]: The remote folder path to query (relative to the user's Nextcloud root).
  /// - [depth]: The WebDAV PROPFIND depth header (default: 20).
  ///
  /// Returns:
  ///   A Future that resolves to a list of [NextcloudDavProp] objects. Returns an empty list on error.
  Future<List<NextcloudDavProp>> getRemoteFileList({
    String remoteRootPath = "",
    int depth = 20,
  }) async {
    final url = Uri.parse('$remoteUrl/$remoteRootPath');
    logger.i("Fetching remote file list from: $url");

    final nextcloudPropFind = NextcloudDavPropFindResponse();
    final xmlBody = nextcloudPropFind.getPropfindXmlRequestBody();

    final client = HttpClient();
    try {
      client.badCertificateCallback =
          (X509Certificate cert, String host, int port) {
            // Reject self-signed or invalid certificates
            logger.e('Self-signed or invalid certificate detected for $host');
            return false;
          };

      final request = await client.openUrl('PROPFIND', url);
      request.headers.set('Depth', depth.toString());
      request.headers.set('Authorization', authHeader);
      request.headers.set('Content-Type', 'application/xml');
      request.add(utf8.encode(xmlBody));

      final response = await request.close();
      if (response.statusCode >= 200 && response.statusCode < 300) {
        final body = await response.transform(utf8.decoder).join();
        await nextcloudPropFind.deserialize(body);
        return nextcloudPropFind.getDavObjects();
      } else {
        logger.e('Error: ${response.statusCode}');
      }
    } catch (e) {
      logger.e('Error during PROPFIND: $e');
    } finally {
      client.close();
    }

    return <NextcloudDavProp>[];
  }

  /// Updates the sync database with the latest remote file list from Nextcloud for a given root folder.
  ///
  /// Fetches the list of remote files (excluding folders) from the specified [remoteRootPath]
  /// and updates the `syncTable` in the database for the given [rootFolderId].
  /// Existing entries are updated with the latest modification time and marked as present on the remote.
  ///
  /// Parameters:
  /// - [remoteRootPath]: The remote folder path to query (relative to the user's Nextcloud root).
  /// - [rootFolderId]: The database ID of the root folder being synced.
  ///
  /// On error, rolls back the transaction and logs the error.
  Future<void> updateRemoteFileList(
    String remoteRootPath,
    int rootFolderId,
    List<String> allowedFileExtensions,
  ) async {
    final davObjects = await getRemoteFileList(remoteRootPath: remoteRootPath);

    logger.i('Updating remote file list for remote folder: $remoteRootPath');

    await db.transaction((txn) async {
      for (final object in davObjects) {
        if (object.isFolder) continue;
        if (!allowedFileExtensions.contains('.*')) {
          // Filter by allowed extensions
          final String extension = p
              .extension(object.relativePath)
              .toLowerCase();

          if (!allowedFileExtensions.contains(extension)) {
            continue;
          }
        }

        await txn.rawInsert(
          '''
        INSERT INTO syncTable (path, remoteLastModified, existsRemote, captured, rootFolderId)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(rootFolderId, path) DO UPDATE SET
            remoteLastModified = excluded.remoteLastModified,
            existsRemote = TRUE,
            captured = excluded.captured;
        ''',
          [
            object.relativePath,
            object.remoteLastModified,
            1,
            captured,
            rootFolderId,
          ],
        );
      }
    });
  }

  Future<void> updateLocalFileList(
    String localRootPath,
    int rootFolderId,
    List<String> allowedFileExtensions,
  ) async {
    final dir = Directory(localRootPath);
    final allFiles = dir.listSync(recursive: true).whereType<File>().toList();

    logger.i('Updating local file list for local folder: $localRootPath');

    await db.transaction((txn) async {
      for (final file in allFiles) {
        if (!allowedFileExtensions.contains('.*')) {
          // Filter by allowed extensions
          final String extension = p.extension(file.path);

          if (!allowedFileExtensions.contains(extension)) {
            continue;
          }
        }

        final relPath = p.relative(file.path, from: localRootPath);
        final modTime =
            file.lastModifiedSync().millisecondsSinceEpoch ~/
            1000 *
            1000; // Round to seconds

        await txn.rawInsert(
          '''
        INSERT INTO syncTable (path, localLastModified, existsLocal, captured, rootFolderId)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(rootFolderId, path) DO UPDATE SET
            localLastModified = excluded.localLastModified,
            existsLocal = TRUE,
            captured = excluded.captured;
      ''',
          [relPath, modTime, 1, captured, rootFolderId],
        );
      }
    });
  }

  String remoteToBasePath(String href) {
    final uri = Uri.parse(href);
    return Uri.decodeFull(uri.pathSegments.skip(4).join('/'));
  }

  Future<void> resolveConflicts(String localRootPath, int rootFolderId) async {
    // 1. Query for conflicting files
    final List<NextcloudSyncFile> fileList = [];

    logger.i('Resolving conflicts for local folder: $localRootPath');

    final sqlString =
        '''
      SELECT *
      FROM syncTable
      WHERE
        (localLastModifiedPrev != localLastModified) AND
        (remoteLastModifiedPrev != remoteLastModified) AND
        (remoteLastModifiedPrev != 0) AND
        (localLastModifiedPrev != 0) AND
        (existsRemote = TRUE) AND
        (existsLocal = TRUE) AND
        (rootFolderId = $rootFolderId);
    ''';

    final result = await db.rawQuery(sqlString);
    for (final row in result) {
      final nextcloudFile = NextcloudSyncFile(
        remoteUrl: remoteUrl,
        remoteLastModified: row['remoteLastModified'] as int,
        localPath: p.join(localRootPath, row['path'] as String),
        localLastModified: row['localLastModified'] as int,
        captured: row['captured'] as int,
      );
      if (nextcloudFile.localPath.endsWith('.nextcloud-dav-sync.db')) {
        continue; // Skip the database file
      }
      fileList.add(nextcloudFile);
    }

    // 2. Insert new conflict files in a transaction
    await db.transaction((txn) async {
      for (final file in fileList) {
        final localFile = File(file.localPath);
        if (!localFile.existsSync()) continue;

        final now = DateTime.now();
        final formatter = DateFormat('yyyyMMdd_HHmmss');
        final formatted = formatter.format(now);

        final ext = p.extension(localFile.path);
        final nameWithoutExt = p.basenameWithoutExtension(localFile.path);
        final parentDir = p.dirname(localFile.path);

        final newFileName = '${nameWithoutExt}_conflict_$formatted$ext';
        final newFilePath = p.join(parentDir, newFileName);

        final newFile = localFile.copySync(newFilePath);

        if (newFile.existsSync()) {
          final relPath = p.relative(newFile.path, from: localRootPath);
          final modTime =
              newFile.lastModifiedSync().millisecondsSinceEpoch ~/ 1000 * 1000;
          await txn.rawInsert(
            '''
          INSERT INTO syncTable (path, localLastModified, existsLocal, captured, rootFolderId)
          VALUES (?, ?, ?, ?, ?)
          ON CONFLICT(rootFolderId, path) DO UPDATE SET
            localLastModified = excluded.localLastModified,
            existsLocal = TRUE,
            captured = excluded.captured;
          ''',
            [relPath, modTime, 1, captured, rootFolderId],
          );
        }
      }
    });
  }

  Future<void> download(String localRootPath, int rootFolderId) async {
    final List<NextcloudSyncFile> downloadList = [];
    final pool = Pool(10); // Limit concurrent downloads

    logger.i('Preparing downloads for local folder: $localRootPath');

    // Load files from server which are not on client and have never been synced
    var sqlString =
        '''
    SELECT *
    FROM syncTable
    WHERE (existsLocal = FALSE) AND 
    (synced = FALSE) AND 
    (rootFolderId = $rootFolderId);
    ''';

    createNextcloudFileListFromQuery(
      sqlString: sqlString,
      dbConnection: db,
      nextCloudFiles: downloadList,
      remoteBase: remoteUrl,
      localBase: localRootPath,
    );

    // Load files from server which are newer and have already been synced
    sqlString =
        '''
    SELECT *
    FROM syncTable
    WHERE 
    (remoteLastModified > localLastModified) AND 
    (synced = TRUE) AND 
    (rootFolderId = $rootFolderId);
    ''';

    createNextcloudFileListFromQuery(
      sqlString: sqlString,
      dbConnection: db,
      nextCloudFiles: downloadList,
      remoteBase: remoteUrl,
      localBase: localRootPath,
    );

    final updateSql =
        '''
    UPDATE syncTable
    SET existsLocal = TRUE,
        localLastModified = ?,
        synced = TRUE
    WHERE path = ? AND rootFolderId = $rootFolderId
    ''';

    await db.transaction((txn) async {
      // Download all files concurrently
      await Future.wait(
        downloadList.map((nextcloudFile) async {
          final resource = await pool.request();
          try {
            final success = await downloadRemoteFileAsync(
              nextcloudFile.remoteUrl,
              nextcloudFile.localPath,
              localRootPath,
              nextcloudFile.remoteLastModified,
            );
            if (!success) {
              logger.e('Failed to download ${nextcloudFile.remoteUrl}');
            } else {
              // After download, update the database
              await txn.rawUpdate(updateSql, [
                nextcloudFile.remoteLastModified,
                p.relative(nextcloudFile.localPath, from: localRootPath),
              ]);
            }
          } finally {
            resource.release();
          }
        }),
      );
      await pool.close();
    });
  }

  Future<bool> downloadRemoteFileAsync(
    String fileUri,
    String localFilePath,
    String localRootPath,
    int lastModifiedTime,
  ) async {
    final client = HttpClient();
    bool success = false;

    try {
      client.badCertificateCallback =
          (X509Certificate cert, String host, int port) {
            logger.e('Self-signed or invalid certificate detected for $host');
            return false;
          };

      final url = Uri.parse(fileUri);
      final request = await client.openUrl('GET', url);
      request.headers.set('Authorization', authHeader);

      final response = await request.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        logger.e('Failed to download $fileUri: ${response.statusCode}');
        return success;
      }

      final file = File(localFilePath);
      await file.parent.create(recursive: true);

      final sink = file.openWrite();
      await response.pipe(sink);
      await sink.close();

      await file.setLastModified(
        DateTime.fromMillisecondsSinceEpoch(lastModifiedTime),
      );
      logger.i('Downloaded $fileUri to $localFilePath');

      if (await file.exists()) {
        success = true;
      }
    } catch (e) {
      logger.e('Error downloading $fileUri: $e');
    } finally {
      client.close();
    }
    return success;
  }

  Future<void> upload(
    String remoteRootPath,
    String localRootPath,
    int rootFolderId,
  ) async {
    final List<NextcloudSyncFile> uploadList = [];
    final pool = Pool(10); // Limit to 10 concurrent uploads

    logger.i('Preparing uploads for local folder: $localRootPath');

    // Files not on server and never synced
    var sqlString =
        '''
    SELECT *
    FROM syncTable
    WHERE (existsRemote = FALSE) AND 
    (synced = FALSE) AND 
    (rootFolderId = $rootFolderId)
    ;
    ''';

    createNextcloudFileListFromQuery(
      sqlString: sqlString,
      dbConnection: db,
      nextCloudFiles: uploadList,
      remoteBase: remoteUrl,
      localBase: localRootPath,
    );

    // Files newer locally and already synced
    sqlString =
        '''
    SELECT *
    FROM syncTable
    WHERE (remoteLastModified < localLastModified) AND (synced = TRUE) AND (rootFolderId = $rootFolderId);
    ''';

    createNextcloudFileListFromQuery(
      sqlString: sqlString,
      dbConnection: db,
      nextCloudFiles: uploadList,
      remoteBase: remoteUrl,
      localBase: localRootPath,
    );

    final updateSql =
        '''
      UPDATE syncTable
      SET existsRemote = TRUE,
          remoteLastModified = ?,
          synced = TRUE
      WHERE path = ? AND rootFolderId = $rootFolderId
    ''';

    await db.transaction((txn) async {
      await Future.wait(
        uploadList.map((nextcloudFile) async {
          final resource = await pool.request();
          try {
            logger.i('uploading file: ${nextcloudFile.localPath}');
            final success = await uploadLocalFileAsync(
              nextcloudFile.remoteUrl,
              File(nextcloudFile.localPath),
              localRootPath,
            );
            if (success) {
              final modTime =
                  File(
                    nextcloudFile.localPath,
                  ).lastModifiedSync().millisecondsSinceEpoch ~/
                  1000 *
                  1000;
              final relPath = p.relative(
                nextcloudFile.localPath,
                from: localRootPath,
              );
              await txn.rawUpdate(updateSql, [modTime, relPath]);
            }
          } finally {
            resource.release();
          }
        }),
      );
      await pool.close();
    });
  }

  Future<bool> uploadLocalFileAsync(
    String remoteFileUrl,
    File localFile,
    String localRootPath,
  ) async {
    final client = HttpClient();
    bool success = false;

    try {
      client.badCertificateCallback =
          (X509Certificate cert, String host, int port) {
            logger.e('Self-signed or invalid certificate detected for $host');
            return false;
          };

      logger.i('start uploading $remoteFileUrl...');
      final modTime =
          (localFile.lastModifiedSync().millisecondsSinceEpoch ~/ 1000);
      final url = Uri.parse(remoteFileUrl);
      final request = await client.openUrl('PUT', url);
      request.headers.set('Authorization', authHeader);
      request.headers.set('Content-Type', 'application/octet-stream');
      request.headers.set('X-OC-MTime', modTime.toString());
      request.add(await localFile.readAsBytes());

      final response = await request.close();

      if (response.statusCode < 200 || response.statusCode >= 300) {
        logger.e('Failed to upload ${localFile.path}: ${response.statusCode}');
        return success;
      } else {
        logger.i('Uploaded ${localFile.path} with mtime $modTime');
        success = true;
      }
    } catch (e) {
      logger.e('Error uploading $remoteFileUrl: $e');
      success = false;
    } finally {
      client.close();
    }
    return success;
  }

  Future<void> deleteOnRemote(
    String remoteRootPath,
    String localRootPath,
    int rootFolderId,
  ) async {
    final List<NextcloudSyncFile> deleteList = [];
    final pool = Pool(10); // Limit to 10 concurrent deletions (optional)

    logger.i('Preparing deletions for remote folder: $remoteRootPath');

    // Query for files to delete on remote
    final sqlString =
        '''
    SELECT * FROM syncTable
    WHERE
      (existsRemote = TRUE) AND
      (existsLocal = FALSE) AND
      (synced = TRUE) AND
      (rootFolderId = $rootFolderId);
    ''';

    createNextcloudFileListFromQuery(
      sqlString: sqlString,
      dbConnection: db,
      nextCloudFiles: deleteList,
      remoteBase: remoteUrl,
      localBase: localRootPath,
    );

    final deleteSql =
        '''
    DELETE FROM syncTable
    WHERE path = ? AND rootFolderId = $rootFolderId;
    ''';

    await db.transaction((txn) async {
      await Future.wait(
        deleteList.map((nextcloudFile) async {
          final resource = await pool.request();
          try {
            final success = await deleteOnRemoteAsync(nextcloudFile.remoteUrl);
            // Remove from syncTable after successful remote delete
            final relPath = remoteToBasePath(nextcloudFile.remoteUrl);
            if (success) {
              await txn.rawDelete(deleteSql, [relPath]);
            }
          } finally {
            resource.release();
          }
        }),
      );
      await pool.close();
    });
  }

  Future<bool> deleteOnRemoteAsync(String fileUri) async {
    final client = HttpClient();
    bool success = false;

    try {
      client.badCertificateCallback =
          (X509Certificate cert, String host, int port) {
            logger.e('Self-signed or invalid certificate detected for $host');
            return false;
          };

      final url = Uri.parse(fileUri);
      final request = await client.openUrl('DELETE', url);
      request.headers.set('Authorization', authHeader);

      final response = await request.close();

      if (response.statusCode < 200 || response.statusCode >= 300) {
        logger.e('Failed to delete $fileUri: ${response.statusCode}');
        success = false;
      } else {
        logger.i('File $fileUri deleted on Remote.');
        success = true;
      }
    } catch (e) {
      logger.e('Error deleting $fileUri: $e');
      success = false;
    } finally {
      client.close();
    }
    return success;
  }

  Future<bool> sync() async {
    bool returnValue = true;
    captured = DateTime.now().millisecondsSinceEpoch;

    // Initial Nextcloud server check
    if (!await isNextcloudServer()) {
      logger.e('Aborting sync: remote server is not Nextcloud.');
      return false;
    }

    // Get all root folders from the database
    final rootFolders = await getRootPaths();

    if (rootFolders.isEmpty) {
      logger.i('No root folders found in the database.');
      returnValue = false;
    } else {
      for (final rootFolder in rootFolders) {
        begin(rootFolder.rootFolderId);
        await updateRemoteFileList(
          rootFolder.remoteRootPath,
          rootFolder.rootFolderId,
          rootFolder.allowedFileExtensions,
        );
        await updateLocalFileList(
          rootFolder.localRootPath,
          rootFolder.rootFolderId,
          rootFolder.allowedFileExtensions,
        );
        await resolveConflicts(
          rootFolder.localRootPath,
          rootFolder.rootFolderId,
        );
        await download(rootFolder.localRootPath, rootFolder.rootFolderId);
        await upload(
          rootFolder.remoteRootPath,
          rootFolder.localRootPath,
          rootFolder.rootFolderId,
        );
        await deleteOnRemote(
          rootFolder.remoteRootPath,
          rootFolder.localRootPath,
          rootFolder.rootFolderId,
        );
        await deleteOnLocal(rootFolder.localRootPath, rootFolder.rootFolderId);
        finish(rootFolder.rootFolderId);
      }
    }

    return returnValue;
  }

  Future<void> deleteOnLocal(String localRootPath, int rootFolderId) async {
    final List<NextcloudSyncFile> deleteList = [];

    // Query for files to delete locally
    var sqlString = '''
    SELECT *
    FROM syncTable
    WHERE (existsRemote = FALSE) AND (synced = TRUE);
    ''';

    logger.i('Preparing deletions for local folder: $localRootPath');

    createNextcloudFileListFromQuery(
      sqlString: sqlString,
      dbConnection: db,
      nextCloudFiles: deleteList,
      remoteBase: remoteUrl,
      localBase: localRootPath,
    );

    final deleteSql =
        '''
    DELETE FROM syncTable
    WHERE path = ? AND rootFolderId = $rootFolderId
    ''';
    await db.transaction((txn) async {
      for (final file in deleteList) {
        final deletedFile = File(file.localPath);

        // Try to delete the file, or if it doesn't exist, treat as deleted
        if (deletedFile.existsSync()) {
          try {
            deletedFile.deleteSync();
          } catch (e) {
            logger.e('Error deleting file ${file.localPath}: $e');
          }
        }
        if (!deletedFile.existsSync()) {
          logger.i('local file ${file.localPath} deleted');
          final relPath = p.relative(deletedFile.path, from: localRootPath);
          await txn.rawDelete(deleteSql, [relPath]);
        }
      }
    });
  }

  void finish(int rootFolderId) {
    db.execute('''
      UPDATE syncTable
      SET synced = TRUE
      WHERE existsRemote = TRUE AND
            existsLocal = TRUE AND
            localLastModified = remoteLastModified AND
            synced = FALSE AND
            rootFolderId = $rootFolderId;
    ''');

    db.execute('''
      UPDATE syncTable
      SET localLastModifiedPrev = localLastModified,
          remoteLastModifiedPrev = remoteLastModified
      WHERE rootFolderId = $rootFolderId;
    ''');
  }

  Future<void> close() async {
    await db.close();
  }
}
