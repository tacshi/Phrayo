import 'package:flutter/material.dart';

import 'common.dart';

/// A card of settings rows with an optional header above and footer below.
class SettingsGroup extends StatelessWidget {
  final String? title, footer;
  final List<Widget> children;
  final double dividerIndent;
  const SettingsGroup({
    super.key,
    this.title,
    this.footer,
    this.dividerIndent = 16,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                title!,
                style: theme.textTheme.labelLarge?.copyWith(color: muted),
              ),
            ),
          Card(
            margin: EdgeInsets.zero,
            clipBehavior: Clip.antiAlias,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (index, child) in children.indexed) ...[
                  if (index > 0) Divider(height: 1, indent: dividerIndent),
                  child,
                ],
              ],
            ),
          ),
          if (footer != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                footer!,
                style: theme.textTheme.bodySmall?.copyWith(color: muted),
              ),
            ),
        ],
      ),
    );
  }
}

/// Leading icon in a tinted rounded square, shared by rows that need one.
class SettingsIcon extends StatelessWidget {
  final IconData icon;
  final bool destructive;
  const SettingsIcon(this.icon, {super.key, this.destructive = false});
  static const width = 30.0;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: width,
      height: width,
      decoration: BoxDecoration(
        color: destructive ? colors.errorContainer : colors.secondaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(
        icon,
        size: 18,
        color: destructive
            ? colors.onErrorContainer
            : colors.onSecondaryContainer,
      ),
    );
  }
}

/// One settings row. A tappable row shows a chevron unless it has a custom
/// [trailing], is [destructive], or is a choice ([selected] is not null).
class SettingsTile extends StatelessWidget {
  final IconData? icon;
  final String title;
  final String? subtitle, value;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool destructive, enabled;
  final bool? selected;
  const SettingsTile({
    super.key,
    this.icon,
    required this.title,
    this.subtitle,
    this.value,
    this.trailing,
    this.onTap,
    this.destructive = false,
    this.enabled = true,
    this.selected,
  });

  /// Indent that lines a divider up with the title of a row that has an icon.
  static const iconIndent = 16 + SettingsIcon.width + 12;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final muted = colors.onSurfaceVariant;
    final tap = enabled ? onTap : null;
    return MergeSemantics(
      child: Semantics(
        button: tap != null,
        selected: selected,
        child: InkWell(
          onTap: tap,
          child: Opacity(
            opacity: enabled ? 1 : 0.5,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 52),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: LayoutBuilder(
                  builder: (context, constraints) => Row(
                    children: [
                      if (icon != null) ...[
                        SettingsIcon(icon!, destructive: destructive),
                        const SizedBox(width: 12),
                      ],
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              style: theme.textTheme.bodyLarge?.copyWith(
                                color: destructive ? colors.error : null,
                              ),
                            ),
                            if (subtitle != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Text(
                                  subtitle!,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: muted,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      // The value only takes the width it needs, up to 45% of
                      // the row, so short titles never wrap beside short values.
                      if (value != null) ...[
                        const SizedBox(width: 12),
                        ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: constraints.maxWidth * 0.45,
                          ),
                          child: Text(
                            value!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.end,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: muted,
                            ),
                          ),
                        ),
                      ],
                      if (trailing != null) ...[
                        const SizedBox(width: 8),
                        trailing!,
                      ] else if (selected == true) ...[
                        const SizedBox(width: 8),
                        Icon(Icons.check, color: colors.primary),
                      ] else if (onTap != null &&
                          selected == null &&
                          !destructive) ...[
                        const SizedBox(width: 4),
                        Icon(Icons.chevron_right, color: muted),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Full-screen list of options with a check on the current one. Pops with the
/// picked value.
class SettingsChoicePage<T> extends StatelessWidget {
  final String title;
  final List<(T, String)> options;
  final T selected;
  const SettingsChoicePage({
    super.key,
    required this.title,
    required this.options,
    required this.selected,
  });

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(title)),
    body: PageBody(
      children: [
        SettingsGroup(
          children: [
            for (final (value, label) in options)
              SettingsTile(
                title: label,
                selected: value == selected,
                onTap: () => Navigator.pop(context, value),
              ),
          ],
        ),
      ],
    ),
  );
}

/// Pushes a settings sub-page over the tab bar, like other detail pages.
Future<T?> pushSettingsPage<T>(BuildContext context, Widget page) =>
    Navigator.of(
      context,
      rootNavigator: true,
    ).push<T>(MaterialPageRoute<T>(builder: (_) => page));
