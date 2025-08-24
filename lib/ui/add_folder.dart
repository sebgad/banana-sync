import 'package:flutter/material.dart';
import 'package:file_selector/file_selector.dart';

class AddFolderPage extends StatefulWidget {
  final List<String> availableRemotePaths;
  const AddFolderPage({super.key, required this.availableRemotePaths});
  @override
  State<AddFolderPage> createState() => _AddFolderPageState();
}

class _AddFolderPageState extends State<AddFolderPage> {
  String? _selectedRemotePath;
  final TextEditingController _localRootPathController =
      TextEditingController();
  bool _picturesOnly = false; // <-- Add this

  @override
  void dispose() {
    _localRootPathController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add Sync Folder'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Remote folder picker
          Row(
            children: [
              Expanded(
                child: Text(
                  _selectedRemotePath ?? 'No remote folder selected',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.folder_open),
                tooltip: 'Pick Remote Folder',
                onPressed: () async {
                  final selected = await showDialog<String>(
                    context: context,
                    builder: (context) {
                      return AlertDialog(
                        title: const Text('Select Remote Folder'),
                        content: SizedBox(
                          width: 300,
                          height: 400,
                          child: ListView.builder(
                            itemCount: widget.availableRemotePaths.length,
                            itemBuilder: (context, index) {
                              final path = widget.availableRemotePaths[index];
                              return ListTile(
                                title: Text(path),
                                onTap: () {
                                  Navigator.of(context).pop(path);
                                },
                              );
                            },
                          ),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.of(context).pop(),
                            child: const Text('Cancel'),
                          ),
                        ],
                      );
                    },
                  );
                  if (selected != null) {
                    setState(() {
                      _selectedRemotePath = selected;
                    });
                  }
                },
              ),
            ],
          ),
          const SizedBox(height: 16),
          // Local folder picker
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _localRootPathController,
                  decoration: const InputDecoration(
                    labelText: 'Local Root Path',
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.folder_open),
                tooltip: 'Pick Local Folder',
                onPressed: () async {
                  final String? selectedDirectory = await getDirectoryPath();
                  if (selectedDirectory != null) {
                    setState(() {
                      _localRootPathController.text = selectedDirectory;
                    });
                  }
                },
              ),
            ],
          ),
          const SizedBox(height: 16),
          // Pictures only checkbox
          CheckboxListTile(
            title: const Text('Sync only pictures'),
            value: _picturesOnly,
            onChanged: (value) {
              setState(() {
                _picturesOnly = value ?? false;
              });
            },
            controlAffinity: ListTileControlAffinity.leading,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () {
            if (_selectedRemotePath != null &&
                _localRootPathController.text.trim().isNotEmpty) {
              Navigator.of(context).pop({
                'remote': _selectedRemotePath,
                'local': _localRootPathController.text.trim(),
                'picturesOnly': _picturesOnly, // <-- Return the checkbox value
              });
            }
          },
          child: const Text('Add'),
        ),
      ],
    );
  }
}
