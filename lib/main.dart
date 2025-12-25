import 'dart:io';

import 'package:banana_sync/dav/credentials.dart';
import 'package:flutter/material.dart';
import 'package:banana_sync/dav/nextcloud_dav.dart';
import 'package:banana_sync/ui/settings_page.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:banana_sync/ui/add_folder.dart';
import 'package:permission_handler/permission_handler.dart';

Future<String> getDatabasePath() async {
  final dir = await getApplicationDocumentsDirectory();
  return p.join(dir.path, 'nextcloud-dav-sync.db');
}

Future<void> main() async {
  runApp(const BananaSyncApp());
}

class BananaSyncApp extends StatelessWidget {
  const BananaSyncApp({super.key});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Banana Sync',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color.fromARGB(255, 220, 240, 251),
        ),
      ),
      home: const MyHomePage(title: 'Banana Sync'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  late NextcloudDAV nextcloudDavClient;

  bool _isSyncing = false;
  List<RootPath> _rootPaths = [];
  bool _isInitialized = false;
  final CredentialsStorage _credentialsStorage = CredentialsStorage();

  /// Deletes a root sync folder by its ID and reloads the list of root paths.
  ///
  /// [rootFolderId] is the unique identifier of the root folder to delete.
  Future<void> _deleteRootPath(int rootFolderId) async {
    await nextcloudDavClient.deleteRootPathById(rootFolderId);
    await _loadRootPaths();
  }

  /// Initializes the state of the home page widget.
  ///
  /// This method is called once when the widget is inserted into the widget tree.
  /// It initializes the NextcloudDAV client and loads credentials/database state.
  @override
  void initState() {
    super.initState();
    _initNextcloudDavClient();
  }

  Future<void> _initNextcloudDavClient() async {
    final databasePath = await getDatabasePath();

    setState(() {
      nextcloudDavClient = NextcloudDAV(databasePath: File(databasePath));
    });
    await nextcloudDavClient.initDb();
    if (!await _credentialsStorage.hasCredentials()) {
      // If no credentials are stored, skip initialization
      setState(() {
        _isInitialized = true;
      });
      return;
    }

    final username = await _credentialsStorage.getUsername();
    final password = await _credentialsStorage.getPassword();
    final baseUrl = await _credentialsStorage.getBaseUrl();

    nextcloudDavClient.setLogin(username, password, baseUrl);
    await _loadRootPaths();
    setState(() {
      _isInitialized = true;
    });
  }

  Future<List<String>> _loadRemotePaths() async {
    final remoteFolderList = await nextcloudDavClient.getRemoteFileList();
    final List<String> remoteFilteredFolderList = remoteFolderList
        .where((file) => file.isFolder)
        .map((file) => file.relativePath)
        .toList();
    return remoteFilteredFolderList;
  }

  Future<void> _loadRootPaths() async {
    final paths = await nextcloudDavClient.getRootPaths();
    setState(() {
      _rootPaths = paths;
    });
  }

  Future<void> _syncNextcloud() async {
    // Check and request appropriate permissions based on Android version
    PermissionStatus status = await Permission.photos.status;

    // If not granted, request it
    if (!status.isGranted) {
      status = await Permission.photos.request();
    }

    // If still not granted, show error with option to open settings
    if (!status.isGranted) {
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Permission Required'),
          content: const Text(
            'Please grant "Fotos und Videos" permission to sync files. This allows reading and managing your photos.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                openAppSettings();
                Navigator.of(context).pop();
              },
              child: const Text('Open Settings'),
            ),
          ],
        ),
      );
      return;
    }

    setState(() {
      _isSyncing = true;
    });
    await nextcloudDavClient.sync();
    setState(() {
      _isSyncing = false;
    });
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Nextcloud sync finished!')));
  }

  @override
  Widget build(BuildContext context) {
    if (!_isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 108,
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Row(
          children: [
            Image.asset(
              'assets/logo.png',
              width: 96,
              height: 96,
              fit: BoxFit.contain,
            ),
            const SizedBox(width: 12),
            Text(widget.title),
          ],
        ),
        actions: [
          // Add button for AddFolderPage
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'Add Sync Folder',
            onPressed: () async {
              if (!await _credentialsStorage.hasCredentials()) {
                // Show dialog informing the user to set credentials first
                showDialog(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('No Credentials Set'),
                    content: const Text(
                      'Please set your Nextcloud credentials in the settings before adding a sync folder.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('OK'),
                      ),
                    ],
                  ),
                );
                return;
              }
              final remotePaths = await _loadRemotePaths();
              final result = await Navigator.of(context)
                  .push<Map<String, dynamic>>(
                    MaterialPageRoute(
                      builder: (context) =>
                          AddFolderPage(availableRemotePaths: remotePaths),
                    ),
                  );
              if (result != null) {
                // Use result['remote'], result['local'], result['picturesOnly'] as needed
                List<String> allowedFileExtensions;

                if (result['picturesOnly'] == true) {
                  allowedFileExtensions = [
                    '.jpg',
                    '.jpeg',
                    '.png',
                    '.gif',
                    '.bmp',
                    '.webp',
                    '.mp4',
                    '.mov',
                    '.avi',
                    '.mkv',
                    '.flv',
                    '.wmv',
                    '.heic',
                    '.heif',
                    '.tiff',
                  ];
                } else {
                  allowedFileExtensions = ['.*'];
                }

                await nextcloudDavClient.addRootPath(
                  result['remote'] as String,
                  result['local'] as String,
                  allowedFileExtensions,
                );
                await _loadRootPaths();
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: () async {
              Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (context) => SettingsPage()));
              nextcloudDavClient.setLogin(
                await _credentialsStorage.getUsername(),
                await _credentialsStorage.getPassword(),
                await _credentialsStorage.getBaseUrl(),
              );

              if (!await _credentialsStorage.hasCredentials()) {
                return;
              }
            },
          ),
        ],
      ),
      body: Column(
        children: [
          const SizedBox(height: 24),
          Expanded(
            child: ListView.builder(
              itemCount: _rootPaths.length,
              itemBuilder: (context, index) {
                final root = _rootPaths[index];
                return Card(
                  margin: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  child: ListTile(
                    leading: const Icon(Icons.folder),
                    title: Text('Remote: ${root.remoteRootPath}'),
                    subtitle: Text('Local: ${root.localRootPath}'),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete, color: Colors.red),
                      tooltip: 'Delete this sync folder',
                      onPressed: () async {
                        showDialog(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: const Text('Confirm Deletion'),
                            content: Text(
                              'Are you sure you want to delete this sync folder?\n\nRemote: ${root.remoteRootPath}\nLocal: ${root.localRootPath}',
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.of(context).pop(),
                                child: const Text('Cancel'),
                              ),
                              TextButton(
                                onPressed: () async {
                                  Navigator.of(context).pop();
                                  await _deleteRootPath(root.rootFolderId);
                                },
                                child: const Text(
                                  'Delete',
                                  style: TextStyle(color: Colors.red),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 8),
          _isSyncing
              ? const CircularProgressIndicator()
              : ElevatedButton(
                  onPressed: () async {
                    if (!await _credentialsStorage.hasCredentials()) {
                      // Show dialog informing the user to set credentials first
                      showDialog(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: const Text('No Credentials Set'),
                          content: const Text(
                            'Please set your Nextcloud credentials in the settings before syncing.',
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.of(context).pop(),
                              child: const Text('OK'),
                            ),
                          ],
                        ),
                      );
                      return;
                    }
                    _syncNextcloud();
                  },
                  child: const Text(
                    'Sync Nextcloud',
                    style: TextStyle(fontSize: 18),
                  ),
                ),
          const SizedBox(height: 50),
        ],
      ),
    );
  }
}
