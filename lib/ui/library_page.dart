import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dio/dio.dart';
import 'package:go_router/go_router.dart';

import '../core/languages.dart';
import '../core/models.dart';
import '../core/providers.dart';
import 'settings_services.dart';
import 'strings.dart';
import 'translation_attribution.dart';
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

  void practise(Expression expression, [List<Expression> queue = const []]) =>
      Navigator.of(context, rootNavigator: true).push(
        MaterialPageRoute<void>(
          builder: (_) => PracticePage(expression: expression, queue: queue),
        ),
      );

  /// Deletes at once and offers Undo, which restores the expression together
  /// with its practice history.
  Future<void> delete(Expression p) async {
    final db = ref.read(databaseProvider);
    final history = (await db.list('practice'))
        .where((row) => row['expressionId'] == p.id)
        .toList();
    await db.removeExpression(p.id);
    if (!mounted) return;
    notice(
      context,
      'expression_deleted',
      action: SnackBarAction(
        label: tr(context, 'undo'),
        onPressed: () async {
          try {
            await db.transaction(() async {
              await db.put(
                p.id,
                'expression',
                p.toJson(),
                revision: p.revision,
              );
              for (final row in history) {
                await db.put(row['id'] as String, 'practice', row);
              }
            });
          } catch (e) {
            if (mounted) notice(context, errorKey(e));
          }
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final collection = ref.watch(expressionsProvider);
    final all = collection.asData?.value ?? [];
    final filtered = all
        .where(
          (p) => '${p.source} ${p.target}'.toLowerCase().contains(
            query.trim().toLowerCase(),
          ),
        )
        .toList();
    final now = DateTime.now();
    final due = all.where((e) => !e.due.isAfter(now)).toList()
      ..sort((a, b) => a.due.compareTo(b.due));
    final nextDue = all.isEmpty
        ? null
        : all.map((e) => e.due).reduce((a, b) => a.isBefore(b) ? a : b);
    final searching = query.trim().isNotEmpty;
    return PageBody(
      children: [
        if (all.isNotEmpty || searching || collection.isLoading)
          TextField(
            key: const ValueKey('library-search'),
            controller: search,
            textInputAction: TextInputAction.search,
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
        if (due.isNotEmpty && !searching)
          Padding(
            padding: const EdgeInsets.only(top: 16, bottom: 8),
            child: Panel(
              key: const ValueKey('review-banner'),
              color: Color.alphaBlend(
                colors.primary.withValues(
                  alpha: theme.brightness == Brightness.dark ? 0.14 : 0.09,
                ),
                surfaceCard(context),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      if (!largeText(context)) ...[
                        ExcludeSemantics(
                          child: Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              color: colors.primary,
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              Icons.event_repeat_rounded,
                              color: colors.onPrimary,
                              size: 22,
                            ),
                          ),
                        ),
                        const SizedBox(width: 14),
                      ],
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              trCount(context, 'review_ready', due.length),
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              tr(context, 'review_ready_hint'),
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  FilledButton.icon(
                    key: const ValueKey('start-review'),
                    onPressed: () => practise(due.first, due.skip(1).toList()),
                    icon: const Icon(Icons.play_arrow_rounded),
                    label: Text(tr(context, 'start_review')),
                  ),
                ],
              ),
            ),
          )
        else if (nextDue != null && !searching)
          Padding(
            padding: const EdgeInsets.only(top: 16, bottom: 4),
            child: Row(
              children: [
                Icon(
                  Icons.check_circle_outline_rounded,
                  size: 18,
                  color: colors.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    tr(
                      context,
                      'caught_up',
                    ).replaceAll('{when}', reviewWhen(context, nextDue)),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
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
          EmptyState(
            icon: Icons.error_outline_rounded,
            title: tr(context, errorKey(collection.error!)),
            action: TextButton(
              onPressed: () => ref.invalidate(expressionsProvider),
              child: Text(tr(context, 'retry')),
            ),
          ),
        if (!collection.isLoading && !collection.hasError && filtered.isEmpty)
          all.isEmpty
              ? EmptyState(
                  icon: Icons.bookmark_add_outlined,
                  title: tr(context, 'empty_library_title'),
                  message: tr(context, 'empty_library'),
                  action: FilledButton.tonalIcon(
                    onPressed: () => GoRouter.of(context).go('/'),
                    icon: const Icon(Icons.mic_rounded),
                    label: Text(tr(context, 'start')),
                  ),
                )
              : EmptyState(
                  compact: true,
                  icon: Icons.search_off_rounded,
                  title: tr(context, 'no_search_results'),
                ),
        if (filtered.isNotEmpty) const SizedBox(height: 8),
        for (final (index, p) in filtered.indexed) ...[
          if (index > 0) const Divider(height: 1),
          _ExpressionRow(
            expression: p,
            due: !p.due.isAfter(now),
            onTap: () => practise(p),
            onSelected: (key) => action(context, () async {
              if (key == 'delete') {
                await delete(p);
              } else if (key == 'share') {
                await ref
                    .read(nativeProvider)
                    .api
                    .share('${p.source}\n${p.target}', null);
              } else {
                await editExpression(context, ref, p);
              }
            }),
          ),
        ],
      ],
    );
  }
}

class _ExpressionRow extends StatelessWidget {
  final Expression expression;
  final bool due;
  final VoidCallback onTap;
  final ValueChanged<String> onSelected;
  const _ExpressionRow({
    required this.expression,
    required this.due,
    required this.onTap,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final p = expression;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
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
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      height: 1.45,
                    ),
                  ),
                  if (p.googleTranslation) const TranslationAttribution(),
                  const SizedBox(height: 6),
                  Text(
                    p.source,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      height: 1.5,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  if (due || p.audioPath != null) ...[
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 12,
                      runSpacing: 4,
                      children: [
                        if (due)
                          _Tag(
                            icon: Icons.event_repeat_rounded,
                            label: tr(context, 'due_tag'),
                            color: colors.primary,
                          ),
                        if (p.audioPath != null)
                          _Tag(
                            icon: Icons.graphic_eq_rounded,
                            label: tr(context, 'has_source_audio'),
                            color: colors.onSurfaceVariant,
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 4),
            PopupMenuButton<String>(
              tooltip: tr(context, 'more'),
              icon: Icon(
                Icons.more_horiz_rounded,
                color: colors.onSurfaceVariant,
              ),
              onSelected: onSelected,
              itemBuilder: (_) => [
                for (final (key, icon) in [
                  ('edit', Icons.edit_outlined),
                  ('share', Icons.ios_share_rounded),
                ])
                  PopupMenuItem(
                    value: key,
                    child: Row(
                      children: [
                        Icon(icon, size: 20),
                        const SizedBox(width: 12),
                        Text(tr(context, key)),
                      ],
                    ),
                  ),
                const PopupMenuDivider(),
                PopupMenuItem(
                  value: 'delete',
                  child: Row(
                    children: [
                      Icon(
                        Icons.delete_outline_rounded,
                        size: 20,
                        color: colors.error,
                      ),
                      const SizedBox(width: 12),
                      Text(
                        tr(context, 'delete'),
                        style: TextStyle(color: colors.error),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  const _Tag({required this.icon, required this.label, required this.color});
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 14, color: color),
      const SizedBox(width: 4),
      Flexible(
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelMedium
              ?.copyWith(color: color),
        ),
      ),
    ],
  );
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
            if (p.googleTranslation) const TranslationAttribution(),
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
      'googleTranslation':
          p.googleTranslation && target.text.trim() == p.target,
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
  late final int total = widget.queue.length + 1;
  bool revealed = false, busy = false, recording = false;
  String answer = '', feedback = '';
  String? attemptPath, attemptId;
  CancelToken? cancel;

  /// 1-based position of the current expression in a review session.
  int get position => total - queue.length;
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
        unawaited(HapticFeedback.selectionClick());
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
        unawaited(HapticFeedback.mediumImpact());
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
    if (!requireTextModel(context, ref)) return;
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
    unawaited(
      known ? HapticFeedback.lightImpact() : HapticFeedback.selectionClick(),
    );
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

  /// The wait before the next review that each answer would schedule, using
  /// the same intervals as [Expression.reviewed].
  String nextReview(bool known) {
    if (!known) return tr(context, 'review_again_tomorrow');
    const days = [1, 3, 7, 14, 30];
    return trCount(
      context,
      'review_next_in_days',
      days[expression.interval.clamp(0, days.length - 1)],
    );
  }

  void play(Future<void> Function() run) => action(context, run);

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
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final native = ref.read(nativeProvider);
    final reviewing = total > 1;
    // A new expression comes back tomorrow either way; the hints only help
    // once the answers lead to different waits.
    final hints = revealed && nextReview(true) != nextReview(false);
    final language =
        languages[expression.targetLanguage] ?? expression.targetLanguage;
    return PopScope(
      canPop: !recording,
      child: Scaffold(
        appBar: AppBar(
          title: Text(tr(context, 'practice')),
          actions: [
            if (reviewing)
              Padding(
                padding: const EdgeInsetsDirectional.only(end: 20),
                child: Center(
                  child: Text(
                    tr(context, 'review_progress')
                        .replaceAll('{index}', '$position')
                        .replaceAll('{total}', '$total'),
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: colors.onSurfaceVariant,
                      fontFeatures: tabularFigures,
                    ),
                  ),
                ),
              ),
          ],
          bottom: reviewing
              ? PreferredSize(
                  preferredSize: const Size.fromHeight(4),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: TweenAnimationBuilder<double>(
                      tween: Tween(end: (position - 1) / total),
                      duration: MediaQuery.disableAnimationsOf(context)
                          ? Duration.zero
                          : const Duration(milliseconds: 300),
                      builder: (_, value, _) =>
                          LinearProgressIndicator(value: value, minHeight: 4),
                    ),
                  ),
                )
              : null,
        ),
        body: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: PageBody(
                  children: [
                    EyebrowLabel(tr(context, 'prompt')),
                    const SizedBox(height: 12),
                    SelectableText(
                      expression.source,
                      style: theme.textTheme.headlineSmall?.copyWith(
                        height: 1.45,
                      ),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        Icon(
                          Icons.record_voice_over_outlined,
                          size: 18,
                          color: colors.primary,
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            trFill(context, 'say_it_in', {
                              'language': language,
                            }),
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: colors.primary,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                    AnimatedSize(
                      duration: MediaQuery.disableAnimationsOf(context)
                          ? Duration.zero
                          : const Duration(milliseconds: 220),
                      curve: Curves.easeOutCubic,
                      alignment: Alignment.topCenter,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (revealed) ...[
                            const SizedBox(height: 24),
                            Panel(
                              color: Color.alphaBlend(
                                colors.primary.withValues(
                                  alpha: theme.brightness == Brightness.dark
                                      ? 0.1
                                      : 0.07,
                                ),
                                surfaceCard(context),
                              ),
                              padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  EyebrowLabel(
                                    tr(context, 'reference_expression'),
                                    color: colors.primary,
                                  ),
                                  const SizedBox(height: 10),
                                  Padding(
                                    padding: const EdgeInsets.only(right: 8),
                                    child: SelectableText(
                                      expression.target,
                                      style: theme.textTheme.headlineSmall
                                          ?.copyWith(
                                            height: 1.4,
                                            fontWeight: FontWeight.w500,
                                          ),
                                    ),
                                  ),
                                  if (expression.googleTranslation)
                                    const TranslationAttribution(),
                                  const SizedBox(height: 4),
                                  Wrap(
                                    spacing: 4,
                                    runSpacing: 4,
                                    crossAxisAlignment:
                                        WrapCrossAlignment.center,
                                    children: [
                                      TextButton.icon(
                                        onPressed: recording || busy
                                            ? null
                                            : () => play(
                                                () => native.api.speak(
                                                  expression.target,
                                                  expression.targetLanguage,
                                                ),
                                              ),
                                        icon: const Icon(
                                          Icons.volume_up_rounded,
                                        ),
                                        label: Text(tr(context, 'listen')),
                                      ),
                                      if (expression.audioPath != null)
                                        TextButton.icon(
                                          onPressed: recording || busy
                                              ? null
                                              : () => play(
                                                  () => native.api.play(
                                                    expression.audioPath!,
                                                    expression.audioStart ?? 0,
                                                    expression.audioEnd,
                                                  ),
                                                ),
                                          icon: const Icon(
                                            Icons.hearing_rounded,
                                          ),
                                          label: Text(
                                            tr(context, 'source_audio'),
                                          ),
                                        ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                            if (answer.isNotEmpty) ...[
                              const SizedBox(height: 12),
                              Panel(
                                padding: const EdgeInsets.fromLTRB(
                                  20,
                                  16,
                                  12,
                                  8,
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    EyebrowLabel(tr(context, 'your_answer')),
                                    const SizedBox(height: 10),
                                    Padding(
                                      padding: const EdgeInsets.only(right: 8),
                                      child: SelectableText(
                                        answer,
                                        style: theme.textTheme.bodyLarge
                                            ?.copyWith(
                                              fontSize: 18,
                                              height: 1.55,
                                            ),
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Wrap(
                                      spacing: 4,
                                      runSpacing: 4,
                                      children: [
                                        if (attemptPath != null)
                                          TextButton.icon(
                                            onPressed: recording || busy
                                                ? null
                                                : () => play(
                                                    () => native.api.play(
                                                      attemptPath!,
                                                      0,
                                                      null,
                                                    ),
                                                  ),
                                            icon: const Icon(
                                              Icons.play_arrow_rounded,
                                            ),
                                            label: Text(tr(context, 'compare')),
                                          ),
                                        TextButton.icon(
                                          onPressed: busy || recording
                                              ? null
                                              : evaluate,
                                          icon: const Icon(
                                            Icons.auto_awesome_outlined,
                                          ),
                                          label: Text(tr(context, 'feedback')),
                                        ),
                                      ],
                                    ),
                                    if (feedback.isNotEmpty) ...[
                                      const Padding(
                                        padding: EdgeInsets.fromLTRB(
                                          0,
                                          8,
                                          8,
                                          12,
                                        ),
                                        child: Divider(height: 1),
                                      ),
                                      EyebrowLabel(
                                        tr(context, 'feedback_title'),
                                      ),
                                      const SizedBox(height: 8),
                                      Padding(
                                        padding: const EdgeInsets.fromLTRB(
                                          0,
                                          0,
                                          8,
                                          12,
                                        ),
                                        child: SelectableText(
                                          feedback,
                                          style: theme.textTheme.bodyLarge
                                              ?.copyWith(height: 1.6),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ],
                          ],
                        ],
                      ),
                    ),
                    if (busy)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 16),
                        child: LinearProgressIndicator(),
                      ),
                  ],
                ),
              ),
              Container(
                key: const ValueKey('practice-controls'),
                width: double.infinity,
                decoration: BoxDecoration(
                  border: Border(top: BorderSide(color: theme.dividerColor)),
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
                                style: recording
                                    ? FilledButton.styleFrom(
                                        backgroundColor: colors.error,
                                        foregroundColor: colors.onError,
                                      )
                                    : null,
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
                              Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: TextButton(
                                  onPressed: busy
                                      ? null
                                      : () => setState(() => revealed = true),
                                  child: Text(tr(context, 'reveal')),
                                ),
                              ),
                          ] else ...[
                            TextButton.icon(
                              onPressed: busy ? null : toggle,
                              icon: const Icon(Icons.mic_rounded),
                              label: Text(tr(context, 'try_speaking_again')),
                            ),
                            const SizedBox(height: 8),
                            Builder(
                              builder: (context) {
                                final again = OutlinedButton(
                                  onPressed: busy ? null : () => review(false),
                                  child: _Assessment(
                                    label: tr(context, 'again'),
                                    detail: hints ? nextReview(false) : null,
                                  ),
                                );
                                final known = FilledButton(
                                  onPressed: busy ? null : () => review(true),
                                  child: _Assessment(
                                    label: tr(context, 'known'),
                                    detail: hints ? nextReview(true) : null,
                                  ),
                                );
                                // Large text stacks the answers so neither
                                // label breaks mid-word.
                                if (largeText(context)) {
                                  return Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      known,
                                      const SizedBox(height: 8),
                                      again,
                                    ],
                                  );
                                }
                                return IntrinsicHeight(
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      Expanded(child: again),
                                      const SizedBox(width: 12),
                                      Expanded(child: known),
                                    ],
                                  ),
                                );
                              },
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

/// A self-assessment answer with the review it schedules beneath it.
class _Assessment extends StatelessWidget {
  final String label;
  final String? detail;
  const _Assessment({required this.label, this.detail});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          textAlign: TextAlign.center,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        if (detail != null) ...[
          const SizedBox(height: 2),
          Opacity(
            opacity: 0.8,
            child: Text(
              detail!,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.labelSmall
                  ?.copyWith(color: DefaultTextStyle.of(context).style.color),
            ),
          ),
        ],
      ],
    ),
  );
}
