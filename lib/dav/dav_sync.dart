import 'dart:io';

import 'package:banana_sync/dav/misc.dart';
import 'package:logger/web.dart';
import 'package:xml/xml.dart';

class NextcloudDavProp {
  /// The full remote URL to the file or folder on Nextcloud.
  final String remoteUrl;

  /// The path relative to the root folder (decoded from remoteUrl).
  final String relativePath;

  /// The display name of the file or folder (from WebDAV response).
  final String displayName;

  /// True if this object is a folder (WebDAV collection), false if a file.
  final bool isFolder;

  /// The file size in bytes (0 for folders).
  final int contentLength;

  /// Last modified time in milliseconds since epoch (UTC).
  final int remoteLastModified;

  /// The content type of the file (e.g., "text/plain").
  final String contentType;

  /// Creates a NextcloudDavProp representing a file or folder from WebDAV.
  const NextcloudDavProp({
    required this.remoteUrl,
    required this.relativePath,
    required this.remoteLastModified,
    required this.displayName,
    required this.isFolder,
    required this.contentLength,
    required this.contentType,
  });

  /// Returns a readable string representation for debugging.
  @override
  String toString() {
    return 'NextcloudDavProp(remoteUrl: $remoteUrl, relativePath: $relativePath, remoteLastModified: $remoteLastModified, displayName: $displayName, isFolder: $isFolder, contentLength: $contentLength)';
  }
}

/// Handles parsing and storing the results of a Nextcloud WebDAV PROPFIND response.
class NextcloudDavPropFindResponse {
  /// List of parsed file/folder properties from the WebDAV response.
  final List<NextcloudDavProp> davObjects = [];

  final logger = Logger();

  /// Returns the XML body for a standard WebDAV PROPFIND request.
  String getPropfindXmlRequestBody() {
    return _propfindXmlBody;
  }

  /// The XML body sent to Nextcloud for PROPFIND requests.
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

  /// Returns the list of parsed file/folder objects.
  List<NextcloudDavProp> getDavObjects() {
    return davObjects;
  }

  /// Parses the XML response from a Nextcloud WebDAV PROPFIND request.
  ///
  /// [responseBody] is the XML string returned by the server.
  /// Populates [davObjects] with parsed file/folder properties.
  Future<void> deserialize(String responseBody) async {
    final document = XmlDocument.parse(responseBody);
    final responses = document.findAllElements('d:response');

    try {
      for (final response in responses) {
        // Extract the <d:href> element (full remote URL)
        final hrefElement = response.findElements('d:href').firstOrNull;

        // Extract the <d:getlastmodified> element (last modified date)
        final lastModifiedElement = response
            .findElements("d:propstat")
            .firstOrNull
            ?.findElements("d:prop")
            .firstOrNull
            ?.findElements("d:getlastmodified")
            .firstOrNull;

        // Extract the <d:displayname> element (file/folder name)
        final displayName = response
            .findElements("d:propstat")
            .firstOrNull
            ?.findElements("d:prop")
            .firstOrNull
            ?.findElements("d:displayname")
            .firstOrNull;

        // Extract the <d:getcontentlength> element (file size)
        final contentLength = response
            .findElements("d:propstat")
            .firstOrNull
            ?.findElements("d:prop")
            .firstOrNull
            ?.findElements("d:getcontentlength")
            .firstOrNull
            ?.innerText;

        // Extract the <d:getcontentlength> element (file size)
        final contentType = response
            .findElements("d:propstat")
            .firstOrNull
            ?.findElements("d:prop")
            .firstOrNull
            ?.findElements("d:getcontenttype")
            .firstOrNull
            ?.innerText;

        // Check if <d:resourcetype> contains <d:collection> (is folder)
        final isCollection = response
            .findElements("d:propstat")
            .firstOrNull
            ?.findElements("d:prop")
            .firstOrNull
            ?.findElements("d:resourcetype")
            .firstOrNull
            ?.findElements("d:collection")
            .isNotEmpty;

        // Only add objects with valid href and lastModified
        if (hrefElement != null || lastModifiedElement != null) {
          final href = hrefElement?.innerText;
          final lastModified = lastModifiedElement?.innerText;

          if (href == null || lastModified == null) {
            logger.w(
              'Warning: Missing <d:href> or <d:getlastmodified> in response',
            );
            continue;
          }

          // Parse last modified date to milliseconds since epoch
          final dateTime = HttpDate.parse(lastModified);

          // Create and add the parsed object
          final object = NextcloudDavProp(
            remoteUrl: href,
            relativePath: remoteToBasePath(href),
            remoteLastModified: dateTime.millisecondsSinceEpoch,
            displayName: displayName?.innerText ?? '',
            isFolder: isCollection ?? false,
            contentLength: int.parse(contentLength ?? '0'),
            contentType: contentType ?? '',
          );

          davObjects.add(object);
        }
      }
    } catch (e) {
      logger.e('Error parsing XML: $e');
    }
  }
}
