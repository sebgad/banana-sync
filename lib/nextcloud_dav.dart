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

class NextcloudDAV {
  final String baseUrl;
  final String username;
  final String password;
  final String localPath;
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
    required this.localPath,
    required this.databasePath,
  }) : remoteUrl = '$baseUrl/remote.php/dav/files/$username',
       authHeader = 'Basic ${base64Encode(utf8.encode('$username:$password'))}',
       db = _initDb(databasePath);

  static Database _initDb(File databasePath) {
    print('Opening database at ${databasePath.path}');
    final db = sqlite3.open(databasePath.path);
    return db;
  }

  void begin() {
    db.execute('''
      CREATE TABLE IF NOT EXISTS syncTable (
        path TEXT PRIMARY KEY,
        remoteLastModified INTEGER,
        remoteLastModifiedPrev INTEGER,
        existsRemote BOOLEAN DEFAULT FALSE,
        localLastModified INTEGER,
        localLastModifiedPrev INTEGER,
        existsLocal BOOLEAN DEFAULT FALSE,
        synced BOOLEAN DEFAULT FALSE,
        captured INTEGER
      )
    ''');

    db.execute('''
      UPDATE syncTable
      SET existsRemote = FALSE, existsLocal = FALSE
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

  Future<void> updateRemoteFileList() async {
    requestOnGoing = true;
    final stopwatch = Stopwatch()..start();

    final client = http.Client();
    try {
      final request = http.Request('PROPFIND', Uri.parse(remoteUrl))
        ..headers.addAll({
          'Depth': '10',
          'Authorization': authHeader,
          'Content-Type': 'application/xml',
        })
        ..body = _propfindXmlBody;

      final streamedResponse = await client.send(request);
      final body = await streamedResponse.stream.bytesToString();

      if (streamedResponse.statusCode >= 200 &&
          streamedResponse.statusCode < 300) {
        await deserializePropFindReq(body);
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

  Future<void> deserializePropFindReq(String xmlBody) async {
    final document = XmlDocument.parse(xmlBody);
    final responses = document.findAllElements('d:response');

    final stmt = db.prepare('''
      INSERT INTO syncTable (path, remoteLastModified, existsRemote, captured)
      VALUES (?, ?, ?, ?)
      ON CONFLICT(path) DO UPDATE SET
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

  Future<void> updateLocalFileList() async {
    final stmt = db.prepare('''
      INSERT INTO syncTable (path, localLastModified, existsLocal, captured)
      VALUES (?, ?, ?, ?)
      ON CONFLICT(path) DO UPDATE SET
          localLastModified = excluded.localLastModified,
          existsLocal = TRUE,
          captured = excluded.captured;
    ''');

    final dir = Directory(localPath);
    final allFiles = dir.listSync(recursive: true).whereType<File>().toList();

    db.execute('BEGIN');
    try {
      for (final file in allFiles) {
        final relPath = p.relative(file.path, from: localPath);
        final modTime =
            file.lastModifiedSync().millisecondsSinceEpoch /
            1000 *
            1000; // Round to seconds

        stmt.execute([relPath, modTime, 1, captured]);
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

  Future<void> resolveConflicts() async {
    // 1. Query for conflicting files
    final List<NextcloudFile> fileList = [];

    final sqlString = '''
      SELECT *
      FROM syncTable
      WHERE
        (localLastModifiedPrev != localLastModified) AND
        (remoteLastModifiedPrev != remoteLastModified) AND
        (remoteLastModifiedPrev != 0) AND
        (localLastModifiedPrev != 0) AND
        (existsRemote = TRUE) AND
        (existsLocal = TRUE)
    ''';

    final result = db.select(sqlString);
    for (final row in result) {
      final nextcloudFile = NextcloudFile(
        remoteUrl: remoteUrl,
        remoteLastModified: row['remoteLastModified'] as int,
        localPath: p.join(localPath, row['path'] as String),
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
    INSERT INTO syncTable (path, localLastModified, existsLocal, captured)
    VALUES (?, ?, ?, ?)
    ON CONFLICT(path) DO UPDATE SET
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
          final relPath = p.relative(newFile.path, from: localPath);
          final modTime =
              newFile.lastModifiedSync().millisecondsSinceEpoch ~/ 1000 * 1000;
          insertStmt.execute([relPath, modTime, 1, captured]);
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

  Future<void> download() async {
    final List<NextcloudFile> downloadList = [];
    final pool = Pool(10); // Limit concurrent downloads

    // Load files from server which are not on client and have never been synced
    var sqlString = '''
    SELECT *
    FROM syncTable
    WHERE (existsLocal = FALSE) AND (synced = FALSE);
    ''';

    createNextcloudFileListFromQuery(
      sqlString: sqlString,
      dbConnection: db,
      nextCloudFiles: downloadList,
      remoteBase: remoteUrl,
      localBase: localPath,
    );

    // Load files from server which are newer and have already been synced
    sqlString = '''
    SELECT *
    FROM syncTable
    WHERE (remoteLastModified > localLastModified) AND (synced = TRUE);
    ''';

    createNextcloudFileListFromQuery(
      sqlString: sqlString,
      dbConnection: db,
      nextCloudFiles: downloadList,
      remoteBase: remoteUrl,
      localBase: localPath,
    );

    final updateSql = '''
    UPDATE syncTable
    SET existsLocal = TRUE,
        localLastModified = ?,
        synced = TRUE
    WHERE path = ?
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
        final relPath = p.relative(file.path, from: localPath);
        stmt.execute([lastModifiedTime, relPath]);
      }
    } catch (e) {
      print('Error downloading $fileUri: $e');
    } finally {
      client.close();
    }
  }

  Future<void> upload() async {
    final List<NextcloudFile> uploadList = [];
    final pool = Pool(10); // Limit to 10 concurrent uploads

    // Files not on server and never synced
    var sqlString = '''
    SELECT *
    FROM syncTable
    WHERE (existsRemote = FALSE) AND (synced = FALSE);
    ''';

    createNextcloudFileListFromQuery(
      sqlString: sqlString,
      dbConnection: db,
      nextCloudFiles: uploadList,
      remoteBase: remoteUrl,
      localBase: localPath,
    );

    // Files newer locally and already synced
    sqlString = '''
    SELECT *
    FROM syncTable
    WHERE (remoteLastModified < localLastModified) AND (synced = TRUE);
    ''';

    createNextcloudFileListFromQuery(
      sqlString: sqlString,
      dbConnection: db,
      nextCloudFiles: uploadList,
      remoteBase: remoteUrl,
      localBase: localPath,
    );

    final updateSql = '''
      UPDATE syncTable
      SET existsRemote = TRUE,
          remoteLastModified = ?,
          synced = TRUE
      WHERE path = ?
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
  ) async {
    final client = http.Client();

    try {
      print('start uploading $remoteFileUrl...');

      final modTime =
          (localFile.lastModifiedSync().millisecondsSinceEpoch ~/ 1000);
      final relPath = p.relative(localFile.path, from: localPath);

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

  Future<void> deleteOnRemote() async {
    final List<NextcloudFile> deleteList = [];
    final pool = Pool(10); // Limit to 10 concurrent deletions (optional)

    // Query for files to delete on remote
    final sqlString = '''
    SELECT * FROM syncTable
    WHERE
      (existsRemote = TRUE) AND
      (existsLocal = FALSE) AND
      (synced = TRUE)
  ''';

    createNextcloudFileListFromQuery(
      sqlString: sqlString,
      dbConnection: db,
      nextCloudFiles: deleteList,
      remoteBase: remoteUrl,
      localBase: localPath,
    );

    final deleteSql = '''
    DELETE FROM syncTable
    WHERE path = ?
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
    final bool returnValue = true;
    captured = DateTime.now().millisecondsSinceEpoch;
    begin();
    await updateRemoteFileList();
    await updateLocalFileList();
    await resolveConflicts();
    await download();
    await upload();
    await deleteOnRemote();
    await deleteOnLocal();
    finish();

    return returnValue;
  }

  Future<void> deleteOnLocal() async {
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
      localBase: localPath,
    );

    final deleteSql = '''
    DELETE FROM syncTable
    WHERE path = ?
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
          final relPath = p.relative(deletedFile.path, from: localPath);
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

  void finish() {
    db.execute('''
      UPDATE syncTable
      SET synced = TRUE
      WHERE existsRemote = TRUE AND
            existsLocal = TRUE AND
            localLastModified = remoteLastModified AND
            synced = FALSE
    ''');

    db.execute('''
      UPDATE syncTable
      SET localLastModifiedPrev = localLastModified,
          remoteLastModifiedPrev = remoteLastModified
    ''');
  }

  void close() {
    db.dispose();
  }
}
