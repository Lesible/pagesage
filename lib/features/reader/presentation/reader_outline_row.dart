import 'package:flutter/material.dart';

void scrollOutlineToIndex(ScrollController controller, int index) {
  if (index < 0) return;
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!controller.hasClients) return;
    final target = (index * 52.0 - 96).clamp(
      controller.position.minScrollExtent,
      controller.position.maxScrollExtent,
    );
    if ((controller.offset - target).abs() >= 52) controller.jumpTo(target);
  });
}

final class ReaderOutlineRow extends StatelessWidget {
  const ReaderOutlineRow({
    required this.title,
    required this.level,
    required this.selected,
    this.expanded = false,
    this.onToggle,
    this.onTap,
    this.pageLabel,
    super.key,
  });

  final String title;
  final int level;
  final bool selected;
  final bool expanded;
  final VoidCallback? onToggle;
  final VoidCallback? onTap;
  final String? pageLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Material(
        color: selected
            ? colors.primary.withValues(alpha: .09)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        child: ListTile(
          dense: true,
          selected: selected,
          contentPadding: EdgeInsets.only(
            left: 2 + level.clamp(0, 8) * 18.0,
            right: 10,
          ),
          horizontalTitleGap: 2,
          minLeadingWidth: 32,
          minVerticalPadding: 8,
          leading: SizedBox.square(
            dimension: 32,
            child: onToggle != null
                ? IconButton(
                    tooltip: expanded ? '折叠' : '展开',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    icon: Icon(
                      expanded ? Icons.expand_more : Icons.chevron_right,
                      size: 18,
                    ),
                    onPressed: onToggle,
                  )
                : selected
                ? Icon(Icons.circle, size: 5, color: colors.primary)
                : null,
          ),
          title: Text(
            title,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontSize: level == 0 ? 14 : 13,
              height: 1.45,
              fontWeight: selected || level == 0
                  ? FontWeight.w600
                  : FontWeight.w400,
              color: selected ? colors.primary : colors.onSurface,
            ),
          ),
          trailing: pageLabel == null
              ? null
              : Text(
                  pageLabel!,
                  semanticsLabel: '第 $pageLabel 页',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
          onTap: onTap,
        ),
      ),
    );
  }
}
