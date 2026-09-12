import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/model/constants.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/core/router/bottom_sheets/bottom_sheets_notifier.dart';
import 'package:hiddify/features/auto_group/notifier/auto_group_notifier.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Home-screen card mirroring [ProfileTile]'s shape: same radius, margin and surface colour.
class AutoGroupCard extends HookConsumerWidget {
  const AutoGroupCard({super.key, this.margin = const EdgeInsets.symmetric(horizontal: 16, vertical: 8)});

  final EdgeInsets margin;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final theme = Theme.of(context);
    final enabled = ref.watch(Preferences.autoGroupEnabled);
    final members = ref.watch(autoGroupMembersProvider).valueOrNull ?? const [];
    final lastBuild = ref.watch(autoGroupNotifierProvider);

    return Card(
      margin: margin,
      elevation: enabled ? 0 : 1,
      color: theme.colorScheme.surfaceContainer,
      shape: RoundedRectangleBorder(
        side: enabled ? BorderSide(color: theme.colorScheme.outline) : BorderSide.none,
        borderRadius: ProfileTileConst.cardBorderRadius,
      ),
      child: InkWell(
        borderRadius: ProfileTileConst.cardBorderRadius,
        onTap: () => ref.read(bottomSheetsNotifierProvider.notifier).showProfilesOverview(),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Icon(Icons.alt_route_rounded, color: theme.colorScheme.primary),
              const Gap(12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(t.pages.home.autoGroup.title, style: theme.textTheme.titleMedium),
                    const Gap(2),
                    Text(
                      enabled ? t.pages.home.autoGroup.enabled : t.pages.home.autoGroup.disabled,
                      style: theme.textTheme.bodySmall,
                    ),
                    const Gap(2),
                    Text(
                      [
                        t.pages.home.autoGroup.subscriptions(count: members.length),
                        if (lastBuild != null) t.pages.home.autoGroup.servers(count: lastBuild.serverCount),
                        if (lastBuild != null && lastBuild.warnings.isNotEmpty)
                          t.pages.home.autoGroup.warnings(count: lastBuild.warnings.length),
                      ].join('  ·  '),
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                    if (lastBuild != null && lastBuild.warnings.isNotEmpty) ...[
                      const Gap(4),
                      Text(
                        lastBuild.warnings.first,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
                      ),
                    ],
                  ],
                ),
              ),
              Semantics(
                label: t.pages.home.autoGroup.semanticSwitch,
                child: Switch.adaptive(
                  value: enabled,
                  onChanged: (value) => ref.read(autoGroupNotifierProvider.notifier).setEnabled(value),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
