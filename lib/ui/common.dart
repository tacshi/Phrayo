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

void notice(BuildContext context, String key) {
  ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(tr(context, key))));
}

Future<void> action(BuildContext context, Future<void> Function() run) async {
  try {
    await run();
  } catch (e) {
    if (e is DioException && CancelToken.isCancel(e)) return;
    if (context.mounted) notice(context, errorKey(e));
  }
}

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
  Widget build(
    BuildContext context,
  ) => DropdownButtonFormField<TranslationStyle>(
    key: ValueKey('translation-style-${value.name}-${settings.usesTextModel}'),
    initialValue: settings.usesTextModel ? value : TranslationStyle.standard,
    isExpanded: true,
    decoration: InputDecoration(
      labelText: tr(context, 'translation_style'),
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    ),
    items: [
      for (final style in TranslationStyle.values)
        DropdownMenuItem(
          value: style,
          child: Text(tr(context, 'style_${style.name}')),
        ),
    ],
    onChanged: settings.usesTextModel && onChanged != null
        ? (style) {
            if (style != null) onChanged!(style);
          }
        : null,
  );
}
