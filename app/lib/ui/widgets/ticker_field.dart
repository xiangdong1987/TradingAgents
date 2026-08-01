// app/lib/ui/widgets/ticker_field.dart
/// Ticker input with offline autocomplete (symbol / English name / 中文别名).
/// Selecting a suggestion fills the bound controller with the SYMBOL; free
/// typing still works — callers keep uppercasing raw input on submit.
library;

import 'package:flutter/material.dart';

import '../../data/symbol_search.dart';
import 'pnl.dart' show pnlColor;

class TickerField extends StatefulWidget {
  const TickerField({
    super.key,
    required this.controller,
    this.fieldKey,
    this.label = '代码或名称（如 AAPL / 苹果）',
    this.onSubmitted,
  });

  final TextEditingController controller;
  final Key? fieldKey;
  final String label;
  final VoidCallback? onSubmitted;

  @override
  State<TickerField> createState() => _TickerFieldState();
}

class _TickerFieldState extends State<TickerField> {
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
    return RawAutocomplete<SymbolEntry>(
      textEditingController: widget.controller,
      focusNode: _focus,
      optionsBuilder: (value) =>
          SymbolIndex.instance?.search(value.text) ?? const <SymbolEntry>[],
      displayStringForOption: (e) => e.symbol,
      onSelected: (e) => widget.controller.text = e.symbol,
      fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
        return TextField(
          key: widget.fieldKey,
          controller: controller,
          focusNode: focusNode,
          decoration: InputDecoration(labelText: widget.label),
          textCapitalization: TextCapitalization.characters,
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
