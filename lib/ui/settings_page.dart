import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

class SettingsPage extends StatefulWidget {
  final FlutterSecureStorage storage;
  final TextEditingController usernameController;
  final TextEditingController passwordController;
  final TextEditingController baseUrlController;

  const SettingsPage({
    super.key,
    required this.storage,
    required this.usernameController,
    required this.passwordController,
    required this.baseUrlController,
  });

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  void _handleQrResult(String qr) {
    // Example: nc://login/user:testuser&password:p1234&server:https://nextcloud.com
    try {
      final data = Uri.parse(qr);
      if (data.scheme == 'nc') {
        List<String> fields = data.path.substring(1).split("&");

        for (String field in fields) {
          List<String> keyValue = field.split(":");
          if (keyValue.length == 2) {
            switch (keyValue[0]) {
              case 'user':
                widget.usernameController.text = keyValue[1];
                break;
              case 'password':
                widget.passwordController.text = keyValue[1];
                break;
              case 'server':
                widget.baseUrlController.text = keyValue[1];
                break;
            }
          }
        }
      }
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Invalid QR code: $e')));
    }
  }

  Future<void> _scanQrCode() async {
    await showDialog(
      context: context,
      builder: (context) {
        return Dialog(
          child: SizedBox(
            width: 300,
            height: 400,
            child: Stack(
              children: [
                MobileScanner(
                  onDetect: (capture) {
                    final barcode = capture.barcodes.first;
                    if (barcode.rawValue != null) {
                      Navigator.of(context).pop();
                      _handleQrResult(barcode.rawValue!);
                    }
                  },
                ),
                Positioned(
                  top: 8,
                  right: 8,
                  child: IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  void initState() {
    super.initState();
    _loadCredentials();
  }

  Future<void> _loadCredentials() async {
    final username = await widget.storage.read(key: 'username') ?? '';
    final password = await widget.storage.read(key: 'password') ?? '';
    final baseUrl = await widget.storage.read(key: 'baseUrl') ?? '';

    setState(() {
      widget.usernameController.text = username;
      widget.passwordController.text = password;
      widget.baseUrlController.text = baseUrl;
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
                child: ElevatedButton(
                  onPressed: _scanQrCode,
                  child: const Text('Scan QR Code'),
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
