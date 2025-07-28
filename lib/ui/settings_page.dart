import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SettingsPage extends StatefulWidget {
  final FlutterSecureStorage storage;
  final TextEditingController usernameController;
  final TextEditingController passwordController;
  final TextEditingController baseUrlController;
  final TextEditingController localPathController;

  const SettingsPage({
    super.key,
    required this.storage,
    required this.usernameController,
    required this.passwordController,
    required this.baseUrlController,
    required this.localPathController,
  });

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  @override
  void initState() {
    super.initState();
    _loadCredentials();
  }

  Future<void> _loadCredentials() async {
    final username = await widget.storage.read(key: 'username') ?? '';
    final password = await widget.storage.read(key: 'password') ?? '';
    final baseUrl = await widget.storage.read(key: 'baseUrl') ?? '';
    final localPath = await widget.storage.read(key: 'localPath') ?? '';

    setState(() {
      widget.usernameController.text = username;
      widget.passwordController.text = password;
      widget.baseUrlController.text = baseUrl;
      widget.localPathController.text = localPath;
    });
  }

  Future<void> _saveCredentials() async {
    await widget.storage.write(
      key: 'username',
      value: widget.usernameController.text,
    );
    await widget.storage.write(
      key: 'password',
      value: widget.passwordController.text,
    );
    await widget.storage.write(
      key: 'baseUrl',
      value: widget.baseUrlController.text,
    );
    await widget.storage.write(
      key: 'localPath',
      value: widget.localPathController.text,
    );
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Credentials saved!')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: Center(
        child: SingleChildScrollView(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 8,
                ),
                child: TextField(
                  controller: widget.usernameController,
                  decoration: const InputDecoration(labelText: 'Username'),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 8,
                ),
                child: TextField(
                  controller: widget.passwordController,
                  decoration: const InputDecoration(labelText: 'Password'),
                  obscureText: true,
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 8,
                ),
                child: TextField(
                  controller: widget.baseUrlController,
                  decoration: const InputDecoration(labelText: 'Base URL'),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 8,
                ),
                child: TextField(
                  controller: widget.localPathController,
                  decoration: const InputDecoration(labelText: 'Local Path'),
                ),
              ),
              ElevatedButton(
                onPressed: _saveCredentials,
                child: const Text('Save Credentials'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
