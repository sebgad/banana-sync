import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:banana_sync/misc.dart';
import 'package:banana_sync/nextcloud_file.dart';
import 'package:pool/pool.dart';
import 'package:xml/xml.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

class RootPath {
  final String remoteRootPath;
  final String localRootPath;
  final int rootFolderId;

  RootPath({
    required this.remoteRootPath,
    required this.localRootPath,
    required this.rootFolderId,
  });
}

class NextcloudDAV {
  final String baseUrl;
  final String username;
  final String password;
  final String remoteUrl;
  final File databasePath;

  final Database db;
  final String authHeader;
  bool requestOnGoing = false;
  int captured = 0;

  NextcloudDAV({
    required this.baseUrl,
    required this.username,
    required this.password,
    required this.databasePath,
  }) : remoteUrl = '$baseUrl/remote.php/dav/files/$username',
       authHeader = 'Basic ${base64Encode(utf8.encode('$username:$password'))}',
       db = _initDb(databasePath) {
    createSyncDatabase();
  }

  static Database _initDb(File databasePath) {
    print('Opening database at ${databasePath.path}');
    final db = sqlite3.open(databasePath.path);
    return db;
  }

  Future<void> addRootPath(String remoteRootPath, String localRootPath) async {
    db.execute('''
      INSERT INTO rootFolder (remoteRootPath, localRootPath)
      VALUES ("$remoteRootPath", "$localRootPath")
    ''');
    print('Added root path: $remoteRootPath -> $localRootPath');
  }

  Future<void> deleteRootPathById(int rootFolderId) async {
    // Delete entries from syncTable where rootFolderId matches
    db.execute('DELETE FROM syncTable WHERE rootFolderId = $rootFolderId');
    db.execute('''DELETE FROM rootFolder WHERE id = $rootFolderId''');
  }

  Future<List<RootPath>> getRootPaths() async {
    final result = db.select('SELECT * FROM rootFolder');
    return result.map((row) {
      return RootPath(
        remoteRootPath: row['remoteRootPath'] as String,
        localRootPath: row['localRootPath'] as String,
        rootFolderId: row['id'] as int,
      );
    }).toList();
  }

  void createSyncDatabase() {
    db.execute('''
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

    db.execute('''
      CREATE TABLE IF NOT EXISTS rootFolder (
        id INTEGER PRIMARY KEY,
        remoteRootPath TEXT NOT NULL,
        localRootPath TEXT NOT NULL
      );
    ''');
  }

  void begin(int rootFolderId) {
    db.execute('''
      UPDATE syncTable
      SET existsRemote = FALSE, existsLocal = FALSE
      WHERE rootFolderId = $rootFolderId
    ''');

    captured = DateTime.now().millisecondsSinceEpoch;
  }

  static const String _propfindXmlBody =
      '''<?xml version="1.0" encoding="UTF-8"?>
    <d:propfind xmlns:d="DAV:">
        <d:prop>
            <d:displayname/>
            <d:getcontentlength/>
            <d:getlastmodified/>
            <d:getcontenttype/>
            <d:resourcetype/>
        </d:prop>
    </d:propfind>
  ''';

  Future<void> updateRemoteFileList(
    String remoteRootPath,
    int rootFolderId,
  ) async {
    requestOnGoing = true;
    final stopwatch = Stopwatch()..start();

    final client = http.Client();

    try {
      final url = "$remoteUrl/$remoteRootPath";
      final request = http.Request('PROPFIND', Uri.parse(url))
        ..headers.addAll({
          'Depth': '20',
          'Authorization': authHeader,
          'Content-Type': 'application/xml',
        })
        ..body = _propfindXmlBody;

      final streamedResponse = await client.send(request);
      final body = await streamedResponse.stream.bytesToString();

      if (streamedResponse.statusCode >= 200 &&
          streamedResponse.statusCode < 300) {
        await deserializePropFindReq(body, rootFolderId);
      } else {
        print(
          'Error: ${streamedResponse.statusCode} - ${streamedResponse.reasonPhrase}',
        );
      }
    } catch (e, st) {
      print('Failed to update remote file list: $e\n$st');
    } finally {
      client.close();
      requestOnGoing = false;
      stopwatch.stop();
      print(
        'updateRemoteFileList completed in ${stopwatch.elapsedMilliseconds} ms',
      );
    }
  }

  Future<void> deserializePropFindReq(String xmlBody, int rootFolderId) async {
    final document = XmlDocument.parse(xmlBody);
    final responses = document.findAllElements('d:response');

    final stmt = db.prepare('''
      INSERT INTO syncTable (path, remoteLastModified, existsRemote, captured, rootFolderId)
      VALUES (?, ?, ?, ?, ?)
      ON CONFLICT(rootFolderId, path) DO UPDATE SET
          remoteLastModified = excluded.remoteLastModified,
          existsRemote = TRUE,
          captured = excluded.captured;
    ''');

    db.execute('BEGIN');
    try {
      for (final response in responses) {
        final hrefElement = response.findElements('d:href').firstOrNull;
        final lastModifiedElement = response
            .findElements("d:propstat")
            .firstOrNull
            ?.findElements("d:prop")
            .firstOrNull
            ?.findElements("d:getlastmodified")
            .firstOrNull;

        final contentLength = response
            .findElements("d:propstat")
            .firstOrNull
            ?.findElements("d:prop")
            .firstOrNull
            ?.findElements("d:getcontentlength")
            .firstOrNull
            ?.innerText;

        if (contentLength == null) {
          // Only sync files with content length
          continue;
        }

        if (hrefElement != null || lastModifiedElement != null) {
          final href = hrefElement?.innerText;
          final lastModified = lastModifiedElement?.innerText;

          if (href == null || lastModified == null) {
            print(
              'Warning: Missing <d:href> or <d:getlastmodified> in response',
            );
            continue;
          }

          final dateTime = HttpDate.parse(lastModified);
          stmt.execute([
            remoteToBasePath(href),
            dateTime.millisecondsSinceEpoch,
            1,
            captured,
            rootFolderId,
          ]);
        }
      }
      db.execute('COMMIT');
    } catch (e) {
      db.execute('ROLLBACK');
      print('Error deserializing XML: $e');
    } finally {
      stmt.dispose();
    }
  }

  Future<void> updateLocalFileList(
    String localRootPath,
    int rootFolderId,
  ) async {
    final stmt = db.prepare('''
      INSERT INTO syncTable (path, localLastModified, existsLocal, captured, rootFolderId)
      VALUES (?, ?, ?, ?, ?)
      ON CONFLICT(rootFolderId, path) DO UPDATE SET
          localLastModified = excluded.localLastModified,
          existsLocal = TRUE,
          captured = excluded.captured;
    ''');

    final dir = Directory(localRootPath);
    final allFiles = dir.listSync(recursive: true).whereType<File>().toList();

    db.execute('BEGIN');
    try {
      for (final file in allFiles) {
        final relPath = p.relative(file.path, from: localRootPath);
        final modTime =
            file.lastModifiedSync().millisecondsSinceEpoch /
            1000 *
            1000; // Round to seconds

        stmt.execute([relPath, modTime, 1, captured, rootFolderId]);
      }
      db.execute('COMMIT');
    } catch (e) {
      db.execute('ROLLBACK');
      print('Failed to update local file list: $e');
    } finally {
      stmt.dispose();
    }
  }

  String remoteToBasePath(String href) {
    final uri = Uri.parse(href);
    return Uri.decodeFull(uri.pathSegments.skip(4).join('/'));
  }

  Future<void> resolveConflicts(String localRootPath, int rootFolderId) async {
    // 1. Query for conflicting files
    final List<NextcloudFile> fileList = [];

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

    final result = db.select(sqlString);
    for (final row in result) {
      final nextcloudFile = NextcloudFile(
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

    // 2. Prepare statement for inserting new conflict files
    final insertSql = '''
    INSERT INTO syncTable (path, localLastModified, existsLocal, captured, rootFolderId)
    VALUES (?, ?, ?, ?, ?)
    ON CONFLICT(rootFolderId, path) DO UPDATE SET
      localLastModified = excluded.localLastModified,
      existsLocal = TRUE,
      captured = excluded.captured;
    ''';
    final insertStmt = db.prepare(insertSql);

    db.execute('BEGIN');
    try {
      for (final file in fileList) {
        final localFile = File(file.localPath);
        if (!localFile.existsSync()) continue;

        final now = DateTime.now();
        final formatter = DateFormat('yyyymmdd_HHMMss');
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
          insertStmt.execute([relPath, modTime, 1, captured, rootFolderId]);
        }
      }
      db.execute('COMMIT');
    } catch (e) {
      db.execute('ROLLBACK');
      print('Error during conflict file insert: $e');
    } finally {
      insertStmt.dispose();
    }
  }

  Future<void> download(String localRootPath, int rootFolderId) async {
    final List<NextcloudFile> downloadList = [];
    final pool = Pool(10); // Limit concurrent downloads

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

    final stmt = db.prepare(updateSql);
    db.execute('BEGIN');

    // Download all files concurrently
    await Future.wait(
      downloadList.map((nextcloudFile) async {
        // Acquire a resource from the pool before starting the download
        final resource = await pool.request();
        try {
          await downloadRemoteFileAsync(
            nextcloudFile.remoteUrl,
            nextcloudFile.localPath,
            localRootPath,
            nextcloudFile.remoteLastModified,
            stmt,
          );
        } finally {
          resource.release(); // Always release the resource
        }
      }),
    );
    await pool.close();
    db.execute('COMMIT');
    stmt.dispose();
  }

  Future<void> downloadRemoteFileAsync(
    String fileUri,
    String localFilePath,
    String localRootPath,
    int lastModifiedTime,
    PreparedStatement stmt,
  ) async {
    final client = http.Client();

    try {
      final request = http.Request('GET', Uri.parse(fileUri))
        ..headers.addAll({'Authorization': authHeader});

      final response = await client.send(request);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        print('Failed to download $fileUri: ${response.statusCode}');
        return;
      }

      final file = File(localFilePath);
      await file.parent.create(recursive: true);

      final sink = file.openWrite();
      await response.stream.pipe(sink);
      await sink.close();

      await file.setLastModified(
        DateTime.fromMillisecondsSinceEpoch(lastModifiedTime),
      );
      print('Downloaded $fileUri to $localFilePath');

      if (await file.exists()) {
        final relPath = p.relative(file.path, from: localRootPath);
        stmt.execute([lastModifiedTime, relPath]);
      }
    } catch (e) {
      print('Error downloading $fileUri: $e');
    } finally {
      client.close();
    }
  }

  Future<void> upload(
    String remoteRootPath,
    String localRootPath,
    int rootFolderId,
  ) async {
    final List<NextcloudFile> uploadList = [];
    final pool = Pool(10); // Limit to 10 concurrent uploads

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
    final stmt = db.prepare(updateSql);
    db.execute('BEGIN');

    // Upload all files concurrently
    await Future.wait(
      uploadList.map((nextcloudFile) async {
        final resource = await pool.request();
        try {
          print('uploading file: ${nextcloudFile.localPath}');
          await uploadLocalFileAsync(
            nextcloudFile.remoteUrl,
            File(nextcloudFile.localPath),
            stmt,
            localRootPath,
          );
        } finally {
          resource.release(); // Always release the resource
        }
      }),
    );
    await pool.close();
    db.execute('COMMIT');
    stmt.dispose();
  }

  Future<void> uploadLocalFileAsync(
    String remoteFileUrl,
    File localFile,
    PreparedStatement stmt,
    String localRootPath,
  ) async {
    final client = http.Client();

    try {
      print('start uploading $remoteFileUrl...');

      final modTime =
          (localFile.lastModifiedSync().millisecondsSinceEpoch ~/ 1000);
      final relPath = p.relative(localFile.path, from: localRootPath);

      final request = http.Request('PUT', Uri.parse(remoteFileUrl))
        ..headers.addAll({
          'Authorization': authHeader,
          'Content-Type': 'application/octet-stream',
          'X-OC-MTime': modTime.toString(),
        })
        ..bodyBytes = await localFile.readAsBytes();

      final response = await client.send(request);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        print('Failed to upload ${localFile.path}: ${response.statusCode}');
      } else {
        print('Uploaded ${localFile.path} with mtime $modTime');
        stmt.execute([modTime, relPath]);
      }
    } catch (e) {
      print('Error uploading $remoteFileUrl: $e');
    } finally {
      client.close();
    }
  }

  Future<void> deleteOnRemote(
    String remoteRootPath,
    String localRootPath,
    int rootFolderId,
  ) async {
    final List<NextcloudFile> deleteList = [];
    final pool = Pool(10); // Limit to 10 concurrent deletions (optional)

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

    final stmt = db.prepare(deleteSql);
    db.execute('BEGIN');

    // Delete all files concurrently, but only 10 at a time
    await Future.wait(
      deleteList.map((nextcloudFile) async {
        final resource = await pool.request();
        try {
          await deleteOnRemoteAsync(nextcloudFile.remoteUrl, stmt);
        } finally {
          resource.release();
        }
      }),
    );
    await pool.close();
    db.execute('COMMIT');
    stmt.dispose();
  }

  Future<void> deleteOnRemoteAsync(
    String fileUri,
    PreparedStatement stmt,
  ) async {
    final client = http.Client();

    try {
      final request = http.Request('DELETE', Uri.parse(fileUri))
        ..headers.addAll({'Authorization': authHeader});

      final response = await client.send(request);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        print('Failed to delete $fileUri: ${response.statusCode}');
      } else {
        print('File $fileUri deleted on Remote.');
        final relPath = remoteToBasePath(fileUri);
        stmt.execute([relPath]);
      }
    } catch (e) {
      print('Error deleting $fileUri: $e');
    } finally {
      client.close();
    }
  }

  Future<bool> sync() async {
    bool returnValue = true;
    captured = DateTime.now().millisecondsSinceEpoch;

    // Get all root folders from the database
    final rootFolders = await getRootPaths();

    if (rootFolders.isEmpty) {
      print('No root folders found in the database.');
      returnValue = false;
    } else {
      for (final rootFolder in rootFolders) {
        begin(rootFolder.rootFolderId);
        await updateRemoteFileList(
          rootFolder.remoteRootPath,
          rootFolder.rootFolderId,
        );
        await updateLocalFileList(
          rootFolder.localRootPath,
          rootFolder.rootFolderId,
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
    final List<NextcloudFile> deleteList = [];

    // Query for files to delete locally
    var sqlString = '''
    SELECT *
    FROM syncTable
    WHERE (existsRemote = FALSE) AND (synced = TRUE);
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
    WHERE path = ? AND rootFolderId = $rootFolderId
    ''';
    final stmt = db.prepare(deleteSql);

    db.execute('BEGIN');
    try {
      for (final file in deleteList) {
        final deletedFile = File(file.localPath);

        // Try to delete the file, or if it doesn't exist, treat as deleted
        if (deletedFile.existsSync()) {
          try {
            deletedFile.deleteSync();
          } catch (e) {
            print('Error deleting file ${file.localPath}: $e');
          }
        }
        if (!deletedFile.existsSync()) {
          print('local file ${file.localPath} deleted');
          final relPath = p.relative(deletedFile.path, from: localRootPath);
          stmt.execute([relPath]);
        }
      }
      db.execute('COMMIT');
    } catch (e) {
      print('Error deleting local files: $e');
    } finally {
      stmt.dispose();
    }
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

  void close() {
    db.dispose();
  }
}
