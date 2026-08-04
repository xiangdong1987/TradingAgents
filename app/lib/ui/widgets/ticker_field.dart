// app/lib/ui/widgets/ticker_field.dart
/// Ticker input with offline autocomplete (symbol / English name / 中文别名).
/// Selecting a suggestion fills the bound controller with the SYMBOL; free
/// typing still works — callers keep uppercasing raw input on submit.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/symbol_search.dart';
import '../../providers.dart';
import 'pnl.dart' show pnlColor;

class TickerField extends ConsumerStatefulWidget {
  const TickerField({
    super.key,
    required this.controller,
    this.fieldKey,
    this.label,
    this.onSubmitted,
    this.onChanged,
  });

  final TextEditingController controller;
  final Key? fieldKey;

  /// 覆盖输入框 label；不传时用 l10n 的通用提示（代码或名称）。
  final String? label;
  final VoidCallback? onSubmitted;

  /// 输入或选中候选后回调（当前文本）。调用方据此联动其他字段（如按标的算税率）。
  final ValueChanged<String>? onChanged;

  @override
  ConsumerState<TickerField> createState() => _TickerFieldState();
}

class _TickerFieldState extends ConsumerState<TickerField> {
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    // Fire-and-forget: index may be pre-seeded (tests) or load from assets.
    SymbolIndex.load().catchError((_) => SymbolIndex(const []));
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final label = widget.label ?? ref.watch(l10nProvider).tickerFieldHint;
    return RawAutocomplete<SymbolEntry>(
      textEditingController: widget.controller,
      focusNode: _focus,
      optionsBuilder: (value) =>
          SymbolIndex.instance?.search(value.text) ?? const <SymbolEntry>[],
      displayStringForOption: (e) => e.symbol,
      onSelected: (e) {
        widget.controller.text = e.symbol;
        widget.onChanged?.call(e.symbol);
      },
      fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
        return TextField(
          key: widget.fieldKey,
          controller: controller,
          focusNode: focusNode,
          decoration: InputDecoration(labelText: label),
          textCapitalization: TextCapitalization.characters,
          onChanged: widget.onChanged,
          onSubmitted: (_) {
            onFieldSubmitted();
            widget.onSubmitted?.call();
          },
        );
      },
      optionsViewBuilder: (context, onSelected, options) {
        return Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 6,
            borderRadius: BorderRadius.circular(8),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 240, maxWidth: 320),
              child: ListView.builder(
                padding: EdgeInsets.zero,
                shrinkWrap: true,
                itemCount: options.length,
                itemBuilder: (context, i) {
                  final e = options.elementAt(i);
                  return ListTile(
                    dense: true,
                    onTap: () => onSelected(e),
                    title: Row(
                      children: [
                        Text(e.symbol,
                            style: TextStyle(
                                fontWeight: FontWeight.w800,
                                color: pnlColor(1))),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            e.alias.isEmpty ? e.name : '${e.alias} · ${e.name}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 12,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }
}
