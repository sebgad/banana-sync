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
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter Demo',
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
  late NextcloudDAV nextcloudDavClient;
  late final FlutterSecureStorage storage = const FlutterSecureStorage();

  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _baseUrlController = TextEditingController();
  final TextEditingController _localPathController = TextEditingController();
  bool _isSyncing = false;

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    _baseUrlController.dispose();
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
    final String localPath = await storage.read(key: 'localPath') ?? 'na';

    setState(() {
      nextcloudDavClient = NextcloudDAV(
        baseUrl: baseUrl,
        username: username,
        password: password,
        localPath: localPath,
        databasePath: File(databasePath),
      );
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
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Text(widget.title),
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
                    localPathController: _localPathController,
                  ),
                ),
              );
            },
          ),
        ],
      ),
      body: Center(
        child: SingleChildScrollView(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              const SizedBox(height: 24),
              _isSyncing
                  ? const CircularProgressIndicator()
                  : ElevatedButton(
                      onPressed: _syncNextcloud,
                      child: const Text('Sync Nextcloud'),
                    ),
            ],
          ),
        ),
      ),
    );
  }
}
