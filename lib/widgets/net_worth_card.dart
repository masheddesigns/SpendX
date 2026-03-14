import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/database_helper.dart';
import '../screens/net_worth_screen.dart';
import '../utils/app_format.dart';
import '../services/settings_service.dart';
import 'animated_widgets.dart';
import 'package:intl/intl.dart';

class NetWorthCard extends StatefulWidget {
  const NetWorthCard({super.key});

  @override
  State<NetWorthCard> createState() => _NetWorthCardState();
}

class _NetWorthCardState extends State<NetWorthCard> {
  double _netWorth = 0.0;
  bool _hide = true;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadNetWorth();
  }

  @override
  void didUpdateWidget(covariant NetWorthCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    _loadNetWorth();
  }

  Future<void> _loadNetWorth() async {
    final accounts = await DatabaseHelper.instance.getAllBankAccounts();
    final cards = await DatabaseHelper.instance.getAllCreditCards();
    final lendings = await DatabaseHelper.instance.getAllLendings(settledFilter: false);

    final assets = accounts.where((a) => a.isAsset).fold(0.0, (s, a) => s + a.balance);
    final liabilities = cards.fold(0.0, (s, c) => s + c.outstanding) +
        lendings.where((l) => l.type == 'borrowed').fold(0.0, (s, l) => s + (l.originalAmount - l.paidAmount));
    
    if (mounted) {
      setState(() {
        _netWorth = assets - liabilities;
        _loading = false;
      });
      // Update last updated timestamp
      SettingsService.instance.setNetWorthLastUpdated(DateTime.now());
    }
  }


  @override
  Widget build(BuildContext context) {
    if (_loading) return const SizedBox.shrink();

    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: () async {
        await Navigator.push(context, MaterialPageRoute(builder: (_) => const NetWorthScreen()));
        _loadNetWorth();
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 24),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: cs.surfaceContainer,
          border: Border.all(color: cs.outline.withValues(alpha: 0.3), width: 1),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: cs.primary.withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.pie_chart, color: cs.primary, size: 28),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Total Net Worth', style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      _hide
                      ? Text('****', style: TextStyle(color: _netWorth < 0 ? cs.error : cs.onSurface, fontSize: 22, fontWeight: FontWeight.w600))
                      : CountUpText(
                          value: _netWorth,
                          prefix: AppFormat.currencySymbol,
                          decimalPlaces: 2,
                          style: TextStyle(
                            color: _netWorth < 0 ? cs.error : cs.onSurface,
                            fontSize: 22,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      const SizedBox(width: 12),
                      GestureDetector(
                        onTap: () {
                          HapticFeedback.lightImpact();
                          setState(() => _hide = !_hide);
                        },
                        child: Icon(_hide ? Icons.visibility_off : Icons.visibility, color: cs.onSurfaceVariant, size: 20),
                      ),
                    ],
                  ),
                  if (!_loading && SettingsService.instance.netWorthLastUpdated != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          'Last updated: ${DateFormat('dd MMM, hh:mm a').format(SettingsService.instance.netWorthLastUpdated!)}',
                          style: TextStyle(color: cs.onSurfaceVariant.withValues(alpha: 0.6), fontSize: 10),
                        ),
                      ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: cs.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}
