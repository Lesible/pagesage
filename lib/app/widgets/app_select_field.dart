import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_tokens.dart';

final class AppSelectOption<T> {
  const AppSelectOption({
    required this.value,
    required this.label,
    this.description,
    this.enabled = true,
  });

  final T value;
  final String label;
  final String? description;
  final bool enabled;
}

final class AppSelectField<T> extends StatefulWidget {
  const AppSelectField({
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
    this.hint = '请选择',
    this.helperText,
    this.loading = false,
    this.compact = false,
    super.key,
  });

  final String label;
  final T? value;
  final List<AppSelectOption<T>> options;
  final ValueChanged<T>? onChanged;
  final String hint;
  final String? helperText;
  final bool loading;
  final bool compact;

  @override
  State<AppSelectField<T>> createState() => _AppSelectFieldState<T>();
}

final class _AppSelectFieldState<T> extends State<AppSelectField<T>> {
  final _menu = MenuController();
  final _anchorFocus = FocusNode();
  final _selectedFocus = FocusNode();
  bool _open = false;
  bool _hovered = false;

  bool get _enabled =>
      widget.onChanged != null &&
      widget.options.any((option) => option.enabled) &&
      !widget.loading;

  void _toggle() {
    if (!_enabled) return;
    if (_menu.isOpen) {
      _menu.close();
    } else {
      _menu.open();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _menu.isOpen) _selectedFocus.requestFocus();
      });
    }
  }

  @override
  void didUpdateWidget(covariant AppSelectField<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_enabled && _menu.isOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_enabled && _menu.isOpen) _menu.close();
      });
    }
  }

  @override
  void dispose() {
    _anchorFocus.dispose();
    _selectedFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final selectedIndex = widget.options.indexWhere(
      (option) => option.value == widget.value,
    );
    final selected = selectedIndex < 0 ? null : widget.options[selectedIndex];
    return Tooltip(
      message: widget.compact ? widget.label : '',
      child: ScrollbarTheme(
        data: ScrollbarTheme.of(context).copyWith(
          thickness: const WidgetStatePropertyAll(3),
          radius: const Radius.circular(AppRadius.full),
          thumbColor: WidgetStatePropertyAll(
            colors.onSurface.withValues(alpha: 0.25),
          ),
          crossAxisMargin: 1,
          mainAxisMargin: 4,
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final screen = MediaQuery.sizeOf(context);
            final scale = MediaQuery.textScalerOf(context).scale(1);
            final available = math.min(
              constraints.maxWidth.isFinite
                  ? constraints.maxWidth
                  : screen.width,
              screen.width - AppSpacing.x8,
            );
            final menuWidth = math.min(
              widget.compact
                  ? math.min(
                      screen.width - AppSpacing.x8,
                      math.max(220.0, available),
                    )
                  : available,
              math.min(400.0, 304 * scale),
            );
            final focusIndex =
                selectedIndex >= 0 && widget.options[selectedIndex].enabled
                ? selectedIndex
                : widget.options.indexWhere((option) => option.enabled);
            return MenuAnchor(
              controller: _menu,
              childFocusNode: _anchorFocus,
              alignmentOffset: const Offset(0, AppSpacing.x2),
              consumeOutsideTap: true,
              onOpen: () => setState(() => _open = true),
              onClose: () => setState(() => _open = false),
              style: MenuStyle(
                backgroundColor: WidgetStatePropertyAll(colors.surface),
                surfaceTintColor: const WidgetStatePropertyAll(
                  Colors.transparent,
                ),
                shadowColor: WidgetStatePropertyAll(
                  colors.shadow.withValues(alpha: 0.16),
                ),
                elevation: const WidgetStatePropertyAll(3),
                padding: const WidgetStatePropertyAll(EdgeInsets.all(6)),
                minimumSize: WidgetStatePropertyAll(Size(menuWidth, 0)),
                maximumSize: WidgetStatePropertyAll(
                  Size(menuWidth, math.min(360.0, screen.height * 0.6)),
                ),
                shape: WidgetStatePropertyAll(
                  RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadius.lg),
                    side: BorderSide(color: colors.appBorder),
                  ),
                ),
              ),
              menuChildren: [
                for (var index = 0; index < widget.options.length; index++)
                  _option(
                    widget.options[index],
                    selected: index == selectedIndex,
                    focusNode: index == focusIndex ? _selectedFocus : null,
                    width: menuWidth - 44,
                  ),
              ],
              builder: (context, controller, child) => CallbackShortcuts(
                bindings: {
                  const SingleActivator(LogicalKeyboardKey.arrowDown): _toggle,
                  const SingleActivator(LogicalKeyboardKey.arrowUp): _toggle,
                },
                child: Semantics(
                  button: true,
                  label: widget.compact ? widget.label : null,
                  enabled: _enabled,
                  expanded: _open,
                  child: MouseRegion(
                    cursor: _enabled
                        ? SystemMouseCursors.click
                        : SystemMouseCursors.basic,
                    onEnter: (_) => setState(() => _hovered = true),
                    onExit: (_) => setState(() => _hovered = false),
                    child: InkWell(
                      focusNode: _anchorFocus,
                      onFocusChange: (_) => setState(() {}),
                      onTap: _enabled ? _toggle : null,
                      borderRadius: BorderRadius.circular(AppRadius.md),
                      child: widget.compact
                          ? Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 7,
                              ),
                              constraints: const BoxConstraints(minHeight: 40),
                              decoration: BoxDecoration(
                                color: _open || _hovered
                                    ? colors.surfaceContainerHighest
                                    : colors.surfaceContainerLow,
                                borderRadius: BorderRadius.circular(
                                  AppRadius.md,
                                ),
                                border: Border.all(
                                  color: _anchorFocus.hasFocus
                                      ? colors.primary
                                      : colors.appBorder,
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Flexible(
                                    child: Text(
                                      selected?.label ?? widget.hint,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.labelLarge
                                          ?.copyWith(
                                            color: _enabled
                                                ? colors.onSurface
                                                : colors.textSecondary,
                                          ),
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  if (widget.loading)
                                    const SizedBox.square(
                                      dimension: 14,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  else
                                    Icon(
                                      _open
                                          ? Icons.expand_less
                                          : Icons.expand_more,
                                      size: 16,
                                    ),
                                ],
                              ),
                            )
                          : InputDecorator(
                              isFocused: _anchorFocus.hasFocus || _open,
                              isHovering: _hovered && _enabled,
                              isEmpty: selected == null,
                              decoration: InputDecoration(
                                labelText: widget.label,
                                helperText: widget.helperText,
                                helperMaxLines: 3,
                                enabled: _enabled,
                                floatingLabelBehavior:
                                    FloatingLabelBehavior.always,
                                suffixIcon: widget.loading
                                    ? const Padding(
                                        padding: EdgeInsets.all(AppSpacing.x4),
                                        child: SizedBox.square(
                                          dimension: 16,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        ),
                                      )
                                    : Icon(
                                        _open
                                            ? Icons.keyboard_arrow_up_rounded
                                            : Icons.keyboard_arrow_down_rounded,
                                        size: 20,
                                      ),
                              ),
                              child: Text(
                                selected?.label ?? widget.hint,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodyLarge?.copyWith(
                                  color: selected == null || !_enabled
                                      ? colors.textSecondary
                                      : colors.onSurface,
                                ),
                              ),
                            ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _option(
    AppSelectOption<T> option, {
    required bool selected,
    required FocusNode? focusNode,
    required double width,
  }) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Semantics(
        selected: selected,
        child: MenuItemButton(
          focusNode: focusNode,
          onPressed: !option.enabled
              ? null
              : () {
                  if (_enabled) widget.onChanged?.call(option.value);
                },
          style: ButtonStyle(
            minimumSize: const WidgetStatePropertyAll(Size(0, 44)),
            padding: const WidgetStatePropertyAll(
              EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            ),
            shape: WidgetStatePropertyAll(
              RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
            ),
            backgroundColor: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.focused)) {
                return colors.primary.withValues(alpha: 0.1);
              }
              if (states.contains(WidgetState.hovered)) {
                return colors.surfaceSubtle;
              }
              return selected ? colors.secondaryContainer : Colors.transparent;
            }),
            foregroundColor: WidgetStateProperty.resolveWith(
              (states) => states.contains(WidgetState.disabled)
                  ? colors.onSurface.withValues(alpha: .38)
                  : colors.onSurface,
            ),
            side: WidgetStateProperty.resolveWith(
              (states) => BorderSide(
                color: states.contains(WidgetState.focused)
                    ? colors.primary.withValues(alpha: 0.5)
                    : Colors.transparent,
              ),
            ),
          ),
          child: SizedBox(
            width: width,
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        option.label,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: selected
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                      if (option.description case final description?) ...[
                        const SizedBox(height: AppSpacing.x1),
                        Text(
                          description,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colors.textSecondary,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: AppSpacing.x3),
                SizedBox.square(
                  dimension: 18,
                  child: selected
                      ? Icon(
                          Icons.check_rounded,
                          size: 18,
                          color: colors.primary,
                        )
                      : null,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
