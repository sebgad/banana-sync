import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:banana_sync/dav/nextcloud_dav.dart';
import 'package:banana_sync/ui/settings_page.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:banana_sync/ui/add_folder.dart';

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
  Future<void> _deleteRootPath(int rootFolderId) async {
    await nextcloudDavClient.deleteRootPathById(rootFolderId);
    await _loadRootPaths();
  }

  late NextcloudDAV nextcloudDavClient;
  late final FlutterSecureStorage storage = const FlutterSecureStorage();

  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _baseUrlController = TextEditingController();
  List<String> _availableRemotePaths = [];

  bool _isSyncing = false;
  List<RootPath> _rootPaths = [];
  bool _isInitialized = false;
  final TextEditingController _localRootPathController =
      TextEditingController();

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    _baseUrlController.dispose();
    _localRootPathController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _initNextcloudDavClient();
  }

  Future<void> _initNextcloudDavClient() async {
    final databasePath = await getDatabasePath();
    final String username = await storage.read(key: 'username') ?? 'na';
    final String password = await storage.read(key: 'password') ?? 'na';
    final String baseUrl = await storage.read(key: 'baseUrl') ?? 'na';

    setState(() {
      nextcloudDavClient = NextcloudDAV(
        baseUrl: baseUrl,
        username: username,
        password: password,
        databasePath: File(databasePath),
      );
    });
    await nextcloudDavClient.initDb();
    await _loadRootPaths();
    setState(() {
      _isInitialized = true;
    });
  }

  Future<void> _loadRootPaths() async {
    final paths = await nextcloudDavClient.getRootPaths();
    setState(() {
      _rootPaths = paths;
    });
    final remoteFileList = await nextcloudDavClient.getRemoteFileList();
    setState(() {
      _availableRemotePaths = remoteFileList
          .where((file) => file.isFolder)
          .map((file) => file.relativePath)
          .toList();
    });
  }

  Future<void> _syncNextcloud() async {
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
              'assets/logo.jpeg',
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
              final result = await Navigator.of(context)
                  .push<Map<String, dynamic>>(
                    MaterialPageRoute(
                      builder: (context) => AddFolderPage(
                        availableRemotePaths: _availableRemotePaths,
                      ),
                    ),
                  );
              if (result != null) {
                // Use result['remote'], result['local'], result['picturesOnly'] as needed
                await nextcloudDavClient.addRootPath(
                  result['remote'] as String,
                  result['local'] as String,
                  result['picturesOnly'] as bool? ?? false,
                );
                await _loadRootPaths();
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (context) => SettingsPage(
                    storage: storage,
                    usernameController: _usernameController,
                    passwordController: _passwordController,
                    baseUrlController: _baseUrlController,
                  ),
                ),
              );
              nextcloudDavClient.setLogin(
                _usernameController.text,
                _passwordController.text,
                _baseUrlController.text,
              );
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
                        await _deleteRootPath(root.rootFolderId);
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
                  onPressed: _syncNextcloud,
                  child: const Text('Sync Nextcloud'),
                ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}
