import 'package:flutter/material.dart';

final class ModelPickerButton extends StatelessWidget {
  const ModelPickerButton({
    required this.models,
    required this.onSelected,
    super.key,
  });

  final List<String> models;
  final ValueChanged<String>? onSelected;

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
    onPressed: onSelected == null
        ? null
        : () async {
            final model = await showDialog<String>(
              context: context,
              builder: (context) => _ModelPicker(models: models),
            );
            if (context.mounted && model != null) onSelected?.call(model);
          },
    icon: const Icon(Icons.list_alt_outlined, size: 18),
    label: const Text('选择模型'),
  );
}

final class _ModelPicker extends StatefulWidget {
  const _ModelPicker({required this.models});

  final List<String> models;

  @override
  State<_ModelPicker> createState() => _ModelPickerState();
}

final class _ModelPickerState extends State<_ModelPicker> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final models = widget.models
        .where((model) => model.toLowerCase().contains(_query.toLowerCase()))
        .toList();
    return AlertDialog(
      title: const Text('选择模型'),
      content: SizedBox(
        width: 520,
        height: 420,
        child: Column(
          children: [
            TextField(
              autofocus: true,
              decoration: const InputDecoration(
                labelText: '搜索模型',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: (value) => setState(() => _query = value),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: models.isEmpty
                  ? const Center(child: Text('没有匹配的模型'))
                  : ListView.builder(
                      itemCount: models.length,
                      itemBuilder: (context, index) => ListTile(
                        title: Text(models[index]),
                        onTap: () => Navigator.of(context).pop(models[index]),
                      ),
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
      ],
    );
  }
}
