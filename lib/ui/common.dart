import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:dio/dio.dart';

import 'strings.dart';
import '../core/models.dart';

String errorKey(Object error) {
  if (error is DioException) {
    final code = error.response?.statusCode;
    if (code == 401 || code == 403 || code == 402) return 'auth_error';
    if (code == 429) return 'rate_limit';
    return 'network_error';
  }
  final text = error is PlatformException
      ? '${error.code} ${error.message}'
      : error.toString();
  for (final key in words.keys) {
    if (key.length > 5 && text.contains(key)) return key;
  }
  return 'error';
}

/// Shows a short message, replacing any message still on screen so quick
/// successive actions never queue up stale notices.
///
/// A message with an action, such as Undo, stays a little longer and then
/// times out, except for screen reader users, who keep it until they act or
/// dismiss it.
void notice(BuildContext context, String key, {SnackBarAction? action}) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(tr(context, key)),
        action: action,
        persist: action != null && MediaQuery.accessibleNavigationOf(context),
        duration: Duration(seconds: action == null ? 4 : 6),
      ),
    );
}

Future<void> action(BuildContext context, Future<void> Function() run) async {
  try {
    await run();
  } catch (e) {
    if (e is DioException && CancelToken.isCancel(e)) return;
    if (context.mounted) notice(context, errorKey(e));
  }
}

/// Asks before a destructive action. The confirming button is coloured as
/// destructive so it is never mistaken for the safe choice.
Future<bool> confirm(BuildContext context, String key) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(tr(context, key)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(tr(context, 'cancel')),
          ),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr(context, 'delete')),
          ),
        ],
      ),
    ) ??
    false;
String durationText(double seconds) {
  final d = Duration(seconds: seconds.floor());
  return '${d.inHours > 0 ? '${d.inHours}:' : ''}${d.inMinutes.remainder(60).toString().padLeft(2, '0')}:${d.inSeconds.remainder(60).toString().padLeft(2, '0')}';
}

/// Whether the reader uses a text size large enough that side-by-side
/// controls should stack instead.
bool largeText(BuildContext context) =>
    MediaQuery.textScalerOf(context).scale(14) > 19;

/// Digits that keep their width, so running timers do not jitter.
const tabularFigures = [FontFeature.tabularFigures()];

/// "Today", "Yesterday", a weekday within the last week, or a date, followed
/// by the time of day.
String relativeDateTime(BuildContext context, DateTime value) {
  final local = value.toLocal();
  final now = DateTime.now();
  final days = DateUtils.dateOnly(now)
      .difference(DateUtils.dateOnly(local))
      .inDays;
  final localizations = MaterialLocalizations.of(context);
  // A time never breaks between its digits and its AM/PM marker.
  final time = localizations
      .formatTimeOfDay(
        TimeOfDay.fromDateTime(local),
        alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
      )
      .replaceAll(' ', '\u00a0');
  final day = switch (days) {
    0 => tr(context, 'day_today'),
    1 => tr(context, 'day_yesterday'),
    _ => localizations.formatMediumDate(local),
  };
  return '$day · $time';
}

/// When a future review falls, phrased to complete "Next review …".
String reviewWhen(BuildContext context, DateTime due) {
  final days = DateUtils.dateOnly(due.toLocal())
      .difference(DateUtils.dateOnly(DateTime.now()))
      .inDays;
  if (days <= 0) return tr(context, 'later_today');
  if (days == 1) return tr(context, 'due_tomorrow');
  return tr(context, 'in_days').replaceAll('{count}', '$days');
}

/// The colour of raised surfaces such as cards and input fields.
Color surfaceCard(BuildContext context) =>
    Theme.of(context).cardTheme.color ??
    Theme.of(context).colorScheme.surfaceContainerLow;

class PageBody extends StatelessWidget {
  final List<Widget> children;
  final double width;
  const PageBody({super.key, required this.children, this.width = 680});
  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: BoxConstraints(maxWidth: width),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 40),
        children: children,
      ),
    ),
  );
}

class SproutLogo extends StatelessWidget {
  final double size;
  const SproutLogo({super.key, this.size = 48});
  @override
  Widget build(BuildContext context) => Image.asset(
    'Phrayo.png',
    width: size,
    height: size,
    fit: BoxFit.contain,
    excludeFromSemantics: true,
  );
}

class SectionLabel extends StatelessWidget {
  final String label;
  const SectionLabel(this.label, {super.key});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 24, bottom: 12),
    child: Text(label, style: Theme.of(context).textTheme.titleMedium),
  );
}

/// A small muted heading above a block of content, such as "Your
/// expression" above a translation.
class EyebrowLabel extends StatelessWidget {
  final String text;
  final Color? color;
  const EyebrowLabel(this.text, {super.key, this.color});
  @override
  Widget build(BuildContext context) => Text(
    text,
    style: Theme.of(context).textTheme.labelLarge?.copyWith(
      color: color ?? Theme.of(context).colorScheme.onSurfaceVariant,
      letterSpacing: 0.2,
    ),
  );
}

/// A card that groups related content, styled by the theme's card.
class Panel extends StatelessWidget {
  final Widget child;
  final Color? color;
  final EdgeInsetsGeometry padding;
  const Panel({
    super.key,
    required this.child,
    this.color,
    this.padding = const EdgeInsets.all(16),
  });
  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    color: color,
    // Each control inside keeps its own accessibility node.
    semanticContainer: false,
    child: Padding(
      padding: padding,
      child: SizedBox(width: double.infinity, child: child),
    ),
  );
}

/// A calm placeholder for a page or section with nothing to show yet: what
/// belongs here, and the one action that fills it.
class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;
  final bool compact;
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
    this.compact = false,
  });
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: compact ? 24 : 48, horizontal: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ExcludeSemantics(
            child: Container(
              width: compact ? 56 : 72,
              height: compact ? 56 : 72,
              decoration: BoxDecoration(
                color: colors.primary.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: compact ? 26 : 32, color: colors.primary),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            title,
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          if (message != null) ...[
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Text(
                message!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
            ),
          ],
          if (action != null) ...[const SizedBox(height: 20), action!],
        ],
      ),
    );
  }
}

/// The red dot that marks live capture. Its halo follows the input level,
/// so it moves with the speaker's voice instead of on a timer.
class LevelDot extends StatelessWidget {
  final double level;
  final bool live;
  const LevelDot({super.key, this.level = 0, this.live = true});
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final color = live ? colors.error : colors.onSurfaceVariant;
    return AnimatedContainer(
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 150),
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: live ? 0.3 : 0),
            spreadRadius: live ? 2 + level.clamp(0, 1) * 5 : 0,
          ),
        ],
      ),
    );
  }
}

class TranslationStylePicker extends StatelessWidget {
  const TranslationStylePicker({
    super.key,
    required this.value,
    required this.settings,
    required this.onChanged,
  });
  final TranslationStyle value;
  final AppSettings settings;
  final ValueChanged<TranslationStyle>? onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final outline = OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(color: colors.outlineVariant),
    );
    return DropdownButtonFormField<TranslationStyle>(
      key: ValueKey(
        'translation-style-${value.name}-${settings.usesTextModel}',
      ),
      initialValue: settings.usesTextModel ? value : TranslationStyle.standard,
      isExpanded: true,
      borderRadius: BorderRadius.circular(12),
      icon: const Icon(Icons.expand_more_rounded),
      decoration: InputDecoration(
        labelText: tr(context, 'translation_style'),
        isDense: true,
        filled: false,
        border: outline,
        enabledBorder: outline,
        disabledBorder: outline,
        focusedBorder: outline.copyWith(
          borderSide: BorderSide(color: colors.primary, width: 1.5),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 12,
        ),
      ),
      items: [
        for (final style in TranslationStyle.values)
          DropdownMenuItem(
            value: style,
            child: Text(
              tr(context, 'style_${style.name}'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      onChanged: settings.usesTextModel && onChanged != null
          ? (style) {
              if (style != null) onChanged!(style);
            }
          : null,
    );
  }
}
