import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:banana_sync/nextcloud_dav.dart';
import 'package:banana_sync/ui/settings_page.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

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
          seedColor: const Color.fromARGB(255, 211, 208, 12),
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
  bool _isSyncing = false;
  List<RootPath> _rootPaths = [];
  final TextEditingController _remoteRootPathController =
      TextEditingController();
  final TextEditingController _localRootPathController =
      TextEditingController();

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    _baseUrlController.dispose();
    _remoteRootPathController.dispose();
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
    await _loadRootPaths();
  }

  Future<void> _loadRootPaths() async {
    final paths = await nextcloudDavClient.getRootPaths();
    setState(() {
      _rootPaths = paths;
    });
  }

  Future<void> _addRootPath() async {
    final remote = _remoteRootPathController.text.trim();
    final local = _localRootPathController.text.trim();
    if (remote.isEmpty || local.isEmpty) return;
    await nextcloudDavClient.addRootPath(remote, local);
    _remoteRootPathController.clear();
    _localRootPathController.clear();
    await _loadRootPaths();
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
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Row(
          children: [
            Image.asset(
              'assets/logo.png',
              width: 48,
              height: 48,
              fit: BoxFit.contain,
            ),
            const SizedBox(width: 12),
            Text(widget.title),
          ],
        ),
        actions: [
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
            },
          ),
        ],
      ),
      body: Column(
        children: [
          const SizedBox(height: 24),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Folder list:',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: _rootPaths.length,
              itemBuilder: (context, index) {
                final root = _rootPaths[index];
                return ListTile(
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
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _remoteRootPathController,
                    decoration: const InputDecoration(
                      labelText: 'Remote Root Path',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _localRootPathController,
                    decoration: const InputDecoration(
                      labelText: 'Local Root Path',
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.add),
                  tooltip: 'Add Root Folder',
                  onPressed: _addRootPath,
                ),
              ],
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
