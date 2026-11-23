import 'package:flutter/material.dart';
import '../services/app_session_service.dart';
import 'package:intl/intl.dart';
import '../shared/widgets/empty_state_widget.dart';
import '../shared/widgets/error_state_widget.dart';
import '../shared/widgets/loading_state_widget.dart';

class UsageAnalyticsScreen extends StatefulWidget {
  const UsageAnalyticsScreen({super.key});

  @override
  State<UsageAnalyticsScreen> createState() => _UsageAnalyticsScreenState();
}

class _UsageAnalyticsScreenState extends State<UsageAnalyticsScreen> {
  late Future<List<Map<String, dynamic>>> _sessionsFuture;

  @override
  void initState() {
    super.initState();
    _sessionsFuture = _loadSessions();
  }

  Future<List<Map<String, dynamic>>> _loadSessions() =>
      AppSessionService.instance.getRecentSessions(50);

  Future<void> _retry() async {
    setState(() => _sessionsFuture = _loadSessions());
    try {
      await _sessionsFuture;
    } catch (_) {
      // FutureBuilder renders the failure and offers this retry action again.
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Detailed Analytics'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            tooltip: 'Refresh activity',
            onPressed: _retry,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: SafeArea(
        child: FutureBuilder<List<Map<String, dynamic>>>(
          future: _sessionsFuture,
          builder: (context, snapshot) {
            if (!snapshot.hasData) {
              if (snapshot.hasError) {
                return ErrorStateWidget(
                  error: snapshot.error!,
                  onRetry: _retry,
                );
              }
              return const LoadingStateWidget(message: 'Loading activity…');
            }

            final sessions = snapshot.data!;
            if (sessions.isEmpty) {
              return const EmptyStateWidget(
                icon: Icons.history_rounded,
                title: 'No session data yet',
                description: 'Your recent app activity will appear here.',
              );
            }

            return ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: sessions.length,
              itemBuilder: (context, index) {
                final session = sessions[index];
                final startTime = DateTime.parse(session['start_time']);
                final duration = session['duration_seconds'] as int;

                return Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainer,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Theme.of(
                            context,
                          ).colorScheme.primary.withValues(alpha: 0.1),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.bolt,
                          color: Theme.of(context).colorScheme.primary,
                          size: 20,
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              DateFormat('EEEE, MMM d').format(startTime),
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 14,
                                decoration: TextDecoration.none,
                              ),
                            ),
                            Text(
                              DateFormat('h:mm a').format(startTime),
                              style: TextStyle(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                                fontSize: 12,
                                decoration: TextDecoration.none,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            _formatDuration(duration),
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 15,
                              decoration: TextDecoration.none,
                            ),
                          ),
                          Text(
                            'Duration',
                            style: TextStyle(
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                              fontSize: 10,
                              decoration: TextDecoration.none,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }

  String _formatDuration(int seconds) {
    if (seconds < 60) return '${seconds}s';
    return '${(seconds / 60).floor()}m ${seconds % 60}s';
  }
}
