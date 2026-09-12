import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dio/dio.dart';

import '../core/models.dart';
import '../core/providers.dart';
import 'strings.dart';
import 'common.dart';

class LibraryPage extends ConsumerStatefulWidget {
  const LibraryPage({super.key});
  @override
  ConsumerState<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends ConsumerState<LibraryPage> {
  final search = TextEditingController();
  String query = '';
  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final collection = ref.watch(expressionsProvider);
    final all = collection.asData?.value ?? [];
    final filtered = all
        .where(
          (p) => '${p.source} ${p.target}'.toLowerCase().contains(
            query.toLowerCase(),
          ),
        )
        .toList();
    final due = all.where((e) => !e.due.isAfter(DateTime.now())).toList();
    return PageBody(
      children: [
        TextField(
          key: const ValueKey('library-search'),
          controller: search,
          decoration: InputDecoration(
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 14,
            ),
            suffixIcon: query.isEmpty
                ? null
                : IconButton(
                    tooltip: tr(context, 'clear_search'),
                    onPressed: () {
                      search.clear();
                      setState(() => query = '');
                    },
                    icon: const Icon(Icons.close_rounded),
                  ),
            hintText: tr(context, 'search'),
            prefixIcon: const Icon(Icons.search_rounded),
          ),
          onChanged: (s) => setState(() => query = s),
        ),
        if (due.isNotEmpty && query.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    tr(
                      context,
                      'review_due_count',
                    ).replaceAll('{count}', '${due.length}'),
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                Flexible(
                  child: TextButton(
                    onPressed: () =>
                        Navigator.of(context, rootNavigator: true).push(
                          MaterialPageRoute<void>(
                            builder: (_) => PracticePage(
                              expression: due.first,
                              queue: due.skip(1).toList(),
                            ),
                          ),
                        ),
                    child: Text(tr(context, 'start_review')),
                  ),
                ),
              ],
            ),
          ),
        if (collection.isLoading)
          const Padding(
            padding: EdgeInsets.all(32),
            child: Center(child: CircularProgressIndicator()),
          ),
        if (collection.hasError)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 32),
            child: Column(
              children: [
                Text(tr(context, errorKey(collection.error!))),
                TextButton(
                  onPressed: () => ref.invalidate(expressionsProvider),
                  child: Text(tr(context, 'retry')),
                ),
              ],
            ),
          ),
        if (!collection.isLoading && !collection.hasError && filtered.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 48),
            child: Text(
              tr(context, all.isEmpty ? 'empty_library' : 'no_search_results'),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ...filtered.map(
          (p) => Column(
            children: [
              InkWell(
                onTap: () => Navigator.of(context, rootNavigator: true).push(
                  MaterialPageRoute<void>(
                    builder: (_) => PracticePage(expression: p),
                  ),
                ),
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              p.target,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(
                                    fontWeight: FontWeight.w600,
                                    height: 1.5,
                                  ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              p.source,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(
                                    height: 1.5,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                  ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      PopupMenuButton<String>(
                        tooltip: tr(context, 'more'),
                        onSelected: (key) => action(context, () async {
                          if (key == 'delete') {
                            await ref
                                .read(databaseProvider)
                                .removeExpression(p.id);
                          } else if (key == 'share') {
                            await ref
                                .read(nativeProvider)
                                .api
                                .share('${p.source}\n${p.target}', null);
                          } else {
                            await editExpression(context, ref, p);
                          }
                        }),
                        itemBuilder: (_) => ['edit', 'share', 'delete']
                            .map(
                              (key) => PopupMenuItem(
                                value: key,
                                child: Text(tr(context, key)),
                              ),
                            )
                            .toList(),
                      ),
                    ],
                  ),
                ),
              ),
              const Divider(height: 1),
            ],
          ),
        ),
      ],
    );
  }
}

Future<void> editExpression(
  BuildContext context,
  WidgetRef ref,
  Expression p,
) async {
  final source = TextEditingController(text: p.source),
      target = TextEditingController(text: p.target);
  final save = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(tr(context, 'edit')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: source,
              minLines: 2,
              maxLines: 5,
              decoration: InputDecoration(labelText: tr(context, 'original')),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: target,
              minLines: 2,
              maxLines: 5,
              decoration: InputDecoration(
                labelText: tr(context, 'translation'),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(tr(context, 'cancel')),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(tr(context, 'save')),
        ),
      ],
    ),
  );
  if (save == true &&
      source.text.trim().isNotEmpty &&
      target.text.trim().isNotEmpty) {
    await ref.read(databaseProvider).replaceIfCurrent(p.id, p.revision, {
      ...p.toJson(),
      'source': source.text.trim(),
      'target': target.text.trim(),
      'revision': p.revision + 1,
    });
  }
  source.dispose();
  target.dispose();
}

class PracticePage extends ConsumerStatefulWidget {
  final Expression expression;
  final List<Expression> queue;
  const PracticePage({
    super.key,
    required this.expression,
    this.queue = const [],
  });
  @override
  ConsumerState<PracticePage> createState() => _PracticePageState();
}

class _PracticePageState extends ConsumerState<PracticePage> {
  late Expression expression;
  late List<Expression> queue;
  bool revealed = false, busy = false, recording = false;
  String answer = '', feedback = '';
  String? attemptPath, attemptId;
  CancelToken? cancel;
  @override
  void initState() {
    super.initState();
    expression = widget.expression;
    queue = [...widget.queue];
  }

  @override
  void dispose() {
    cancel?.cancel();
    super.dispose();
  }

  Future<void> toggle() async {
    if (busy) return;
    setState(() => busy = true);
    await action(context, () async {
      final native = ref.read(nativeProvider);
      if (recording) {
        final result = await native.api.stop();
        if (mounted) {
          setState(() {
            answer = result.transcript;
            attemptPath = result.path;
            recording = false;
            revealed = true;
          });
        }
      } else {
        final settings = ref.read(settingsProvider);
        final s = await native.api.start(
          'practice',
          expression.targetLanguage,
          expression.targetLanguage,
          settings.localOnly,
          settings.sttProvider.name,
          settings.transcriptionTerms,
        );
        attemptId = s.id;
        if (mounted) {
          setState(() {
            recording = true;
            answer = '';
            feedback = '';
          });
        }
      }
    });
    if (mounted) setState(() => busy = false);
  }

  Future<void> evaluate() async {
    setState(() => busy = true);
    cancel = CancelToken();
    await action(context, () async {
      await for (final result
          in ref
              .read(textProcessorProvider)
              .rewrite(
                'Compare the attempt with the intended meaning. Briefly explain omissions and wording in ${expression.sourceLanguage}. Do not score pronunciation. Accept equivalent valid expressions.',
                'Intention: ${expression.source}\nReference: ${expression.target}\nAttempt: $answer',
                ref.read(settingsProvider),
                cancel: cancel,
              )) {
        if (mounted) setState(() => feedback = result);
      }
    });
    if (mounted) setState(() => busy = false);
  }

  Future<void> review(bool known) async {
    if (busy || recording) return;
    setState(() => busy = true);
    await action(context, () async {
      final db = ref.read(databaseProvider);
      final original = await db.get(expression.id);
      if (original == null) {
        final updated = expression.reviewed(known, DateTime.now());
        await db.put(updated.id, 'expression', updated.toJson());
      } else {
        final current = Expression.fromJson(original);
        final updated = current.reviewed(known, DateTime.now());
        await db.replaceIfCurrent(current.id, current.revision, {
          ...updated.toJson(),
          'revision': current.revision + 1,
        });
      }
      final practiceId = 'practice:${DateTime.now().microsecondsSinceEpoch}';
      await db.put(practiceId, 'practice', {
        'id': practiceId,
        'expressionId': expression.id,
        'known': known,
        'answer': answer,
        'created': DateTime.now().toIso8601String(),
      });
      if (!mounted) return;
      if (queue.isEmpty) {
        notice(context, 'reviewed');
        Navigator.pop(context);
      } else {
        setState(() {
          expression = queue.removeAt(0);
          revealed = false;
          answer = '';
          feedback = '';
          attemptPath = null;
        });
      }
    });
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(sessionProvider, (_, next) {
      next.whenData((s) {
        if (s.id != attemptId) return;
        if (['saved', 'interrupted'].contains(s.state) && mounted) {
          setState(() {
            recording = false;
            busy = false;
            answer = s.transcript;
            attemptPath = s.path;
            revealed = true;
          });
        }
      });
    });
    final colors = Theme.of(context).colorScheme;
    return PopScope(
      canPop: !recording,
      child: Scaffold(
        appBar: AppBar(title: Text(tr(context, 'practice'))),
        body: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: PageBody(
                  children: [
                    Text(
                      tr(context, 'prompt'),
                      style: Theme.of(context).textTheme.labelLarge
                          ?.copyWith(color: colors.onSurfaceVariant),
                    ),
                    const SizedBox(height: 12),
                    SelectableText(
                      expression.source,
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(height: 1.45),
                    ),
                    if (revealed) ...[
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 24),
                        child: Divider(height: 1),
                      ),
                      Text(
                        tr(context, 'reference_expression'),
                        style: Theme.of(context).textTheme.labelLarge
                            ?.copyWith(color: colors.onSurfaceVariant),
                      ),
                      const SizedBox(height: 12),
                      SelectableText(
                        expression.target,
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(height: 1.5),
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          IconButton(
                            tooltip: tr(context, 'listen'),
                            onPressed: recording || busy
                                ? null
                                : () => action(
                                    context,
                                    () => ref
                                        .read(nativeProvider)
                                        .api
                                        .speak(
                                          expression.target,
                                          expression.targetLanguage,
                                        ),
                                  ),
                            icon: const Icon(Icons.volume_up_rounded),
                          ),
                          if (expression.audioPath != null)
                            TextButton.icon(
                              onPressed: recording || busy
                                  ? null
                                  : () => action(
                                      context,
                                      () => ref
                                          .read(nativeProvider)
                                          .api
                                          .play(
                                            expression.audioPath!,
                                            expression.audioStart ?? 0,
                                            expression.audioEnd,
                                          ),
                                    ),
                              icon: const Icon(Icons.hearing_rounded),
                              label: Text(tr(context, 'source_audio')),
                            ),
                        ],
                      ),
                      if (answer.isNotEmpty) ...[
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 20),
                          child: Divider(height: 1),
                        ),
                        Text(
                          tr(context, 'your_answer'),
                          style: Theme.of(context).textTheme.labelLarge
                              ?.copyWith(color: colors.onSurfaceVariant),
                        ),
                        const SizedBox(height: 12),
                        SelectableText(
                          answer,
                          style: Theme.of(context).textTheme.bodyLarge
                              ?.copyWith(fontSize: 18, height: 1.6),
                        ),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            if (attemptPath != null)
                              TextButton.icon(
                                onPressed: recording || busy
                                    ? null
                                    : () => action(
                                        context,
                                        () => ref
                                            .read(nativeProvider)
                                            .api
                                            .play(attemptPath!, 0, null),
                                      ),
                                icon: const Icon(Icons.play_arrow_rounded),
                                label: Text(tr(context, 'compare')),
                              ),
                            TextButton(
                              onPressed: busy || recording ? null : evaluate,
                              child: Text(tr(context, 'feedback')),
                            ),
                          ],
                        ),
                      ],
                    ],
                    if (busy)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 16),
                        child: LinearProgressIndicator(),
                      ),
                    if (feedback.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        child: SelectableText(
                          feedback,
                          style: Theme.of(context).textTheme.bodyLarge
                              ?.copyWith(height: 1.6),
                        ),
                      ),
                  ],
                ),
              ),
              Container(
                key: const ValueKey('practice-controls'),
                width: double.infinity,
                decoration: BoxDecoration(
                  border: Border(top: BorderSide(color: colors.outlineVariant)),
                ),
                child: Align(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 680),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (recording || !revealed) ...[
                            SizedBox(
                              width: double.infinity,
                              child: FilledButton.icon(
                                onPressed: busy ? null : toggle,
                                icon: Icon(
                                  recording
                                      ? Icons.stop_rounded
                                      : Icons.mic_rounded,
                                ),
                                label: Text(
                                  tr(
                                    context,
                                    recording
                                        ? 'stop'
                                        : busy
                                        ? 'processing'
                                        : 'answer_by_speaking',
                                  ),
                                ),
                              ),
                            ),
                            if (!recording)
                              TextButton(
                                onPressed: busy
                                    ? null
                                    : () => setState(() => revealed = true),
                                child: Text(tr(context, 'reveal')),
                              ),
                          ] else ...[
                            TextButton.icon(
                              onPressed: busy ? null : toggle,
                              icon: const Icon(Icons.mic_rounded),
                              label: Text(tr(context, 'try_speaking_again')),
                            ),
                            const SizedBox(height: 8),
                            IntrinsicHeight(
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Expanded(
                                    child: OutlinedButton(
                                      onPressed: busy
                                          ? null
                                          : () => review(false),
                                      child: Text(
                                        tr(context, 'again'),
                                        textAlign: TextAlign.center,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: FilledButton(
                                      onPressed: busy
                                          ? null
                                          : () => review(true),
                                      child: Text(
                                        tr(context, 'known'),
                                        textAlign: TextAlign.center,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
