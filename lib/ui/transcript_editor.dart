import 'package:flutter/material.dart';

import '../core/models.dart';
import 'common.dart';
import 'strings.dart';

class TranscriptEditor extends StatefulWidget {
  final Recording recording;
  final Future<void> Function(List<String>) onSave;
  const TranscriptEditor({
    super.key,
    required this.recording,
    required this.onSave,
  });

  @override
  State<TranscriptEditor> createState() => _TranscriptEditorState();
}

class _TranscriptEditorState extends State<TranscriptEditor> {
  late final inputs = widget.recording.segments
      .map((segment) => TextEditingController(text: segment.text))
      .toList();
  bool saving = false;
  String? error;

  @override
  void dispose() {
    for (final input in inputs) {
      input.dispose();
    }
    super.dispose();
  }

  Future<void> save() async {
    if (saving) return;
    if (inputs.any((input) => input.text.trim().isEmpty)) {
      setState(() => error = 'transcript_empty_passage');
      return;
    }
    setState(() {
      saving = true;
      error = null;
    });
    try {
      await widget.onSave(inputs.map((input) => input.text).toList());
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          saving = false;
          error = errorKey(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !saving,
    child: Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: tr(context, 'cancel'),
          onPressed: saving ? null : () => Navigator.pop(context),
          icon: const Icon(Icons.close),
        ),
        title: Text(
          tr(context, 'edit_transcript'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          TextButton(
            key: const ValueKey('save-transcript'),
            onPressed: saving ? null : save,
            child: Text(tr(context, 'save')),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Column(
              children: [
                if (saving) const LinearProgressIndicator(),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
                    child: Semantics(
                      liveRegion: true,
                      child: Text(
                        tr(context, error!),
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  ),
                Expanded(
                  child: ListView.separated(
                    padding: const EdgeInsets.all(24),
                    itemCount: inputs.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 24),
                    itemBuilder: (context, index) {
                      final segment = widget.recording.segments[index];
                      return TextField(
                        key: ValueKey('edit-passage-${segment.id}'),
                        controller: inputs[index],
                        enabled: !saving,
                        minLines: 2,
                        maxLines: null,
                        decoration: InputDecoration(
                          labelText:
                              '${durationText(segment.start)}${segment.speaker == null ? '' : ' · ${tr(context, 'speaker')} ${segment.speaker}'}',
                          alignLabelWithHint: true,
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
