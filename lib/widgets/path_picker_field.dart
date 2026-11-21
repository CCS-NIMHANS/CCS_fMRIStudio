import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

enum PickerMode { openFile, pickDirectory, saveFile }

class PathPickerField extends StatelessWidget {
  const PathPickerField({
    super.key,
    required this.controller,
    required this.label,
    this.hint,
    this.mode = PickerMode.openFile,
    this.allowedExtensions,
    this.suggestedFileName,
    this.onPicked,
  });

  final TextEditingController controller;
  final String label;
  final String? hint;
  final PickerMode mode;
  final List<String>? allowedExtensions;
  final String? suggestedFileName;
  final void Function(String path)? onPicked;

  Future<void> _browse() async {
    String? selected;
    switch (mode) {
      case PickerMode.pickDirectory:
        selected = await FilePicker.getDirectoryPath(
          dialogTitle: 'Select $label',
        );
      case PickerMode.openFile:
        final res = await FilePicker.pickFiles(
          dialogTitle: 'Select $label',
          type: (allowedExtensions != null && allowedExtensions!.isNotEmpty)
              ? FileType.custom
              : FileType.any,
          allowedExtensions: allowedExtensions,
        );
        selected = res?.files.single.path;
      case PickerMode.saveFile:
        selected = await FilePicker.saveFile(
          dialogTitle: 'Save $label',
          fileName: suggestedFileName ?? 'output.nii',
        );
    }
    if (selected != null && selected.isNotEmpty) {
      controller.text = selected;
      onPicked?.call(selected);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: controller,
            decoration: InputDecoration(
              labelText: label,
              hintText: hint,
              border: const OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: (val) => onPicked?.call(val.trim()),
          ),
        ),
        const SizedBox(width: 8),
        OutlinedButton.icon(
          onPressed: _browse,
          icon: Icon(
            mode == PickerMode.pickDirectory
                ? Icons.folder_open
                : (mode == PickerMode.saveFile
                    ? Icons.save_as
                    : Icons.file_open),
            size: 18,
          ),
          label: const Text('Browse'),
        ),
      ],
    );
  }
}
