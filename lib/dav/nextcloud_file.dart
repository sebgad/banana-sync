class NextcloudSyncFile {
  final String remoteUrl;
  final int remoteLastModified;
  final String localPath;
  final int localLastModified;
  final int captured;

  const NextcloudSyncFile({
    required this.remoteUrl,
    required this.remoteLastModified,
    required this.localPath,
    required this.localLastModified,
    required this.captured,
  });

  @override
  String toString() {
    return 'NextcloudSyncFile(remoteUrl: $remoteUrl, remoteLastModified: $remoteLastModified, localPath: $localPath, localLastModified: $localLastModified, captured: $captured)';
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NextcloudSyncFile &&
          runtimeType == other.runtimeType &&
          remoteUrl == other.remoteUrl &&
          remoteLastModified == other.remoteLastModified &&
          localPath == other.localPath &&
          localLastModified == other.localLastModified &&
          captured == other.captured;

  @override
  int get hashCode =>
      remoteUrl.hashCode ^
      remoteLastModified.hashCode ^
      localPath.hashCode ^
      localLastModified.hashCode ^
      captured.hashCode;
}
