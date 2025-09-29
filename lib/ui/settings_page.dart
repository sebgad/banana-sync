import 'package:banana_sync/dav/credentials.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _credentials = CredentialsStorage();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _baseUrlController = TextEditingController();

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
                _usernameController.text = keyValue[1];
                break;
              case 'password':
                _passwordController.text = keyValue[1];
                break;
              case 'server':
                _baseUrlController.text = keyValue[1];
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
    final username = await _credentials.getUsername();
    final password = await _credentials.getPassword();
    final baseUrl = await _credentials.getBaseUrl();
    setState(() {
      _usernameController.text = username;
      _passwordController.text = password;
      _baseUrlController.text = baseUrl;
    });
  }

  Future<void> _saveCredentials() async {
    await _credentials.setUsername(_usernameController.text);
    await _credentials.setPassword(_passwordController.text);
    await _credentials.setBaseUrl(_baseUrlController.text);
  }

  @override
  void dispose() {
    _saveCredentials();
    _usernameController.dispose();
    _passwordController.dispose();
    _baseUrlController.dispose();
    super.dispose();
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
                  controller: _usernameController,
                  decoration: const InputDecoration(labelText: 'Username'),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 8,
                ),
                child: TextField(
                  controller: _passwordController,
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
                  controller: _baseUrlController,
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
              // Removed Save Credentials button; credentials are now saved automatically on page close.
            ],
          ),
        ),
      ),
    );
  }
}
