import 'package:flutter/material.dart';
import '../services/app_session_service.dart';
import 'package:intl/intl.dart';
import '../shared/widgets/empty_state_widget.dart';
import '../shared/widgets/error_state_widget.dart';
import '../shared/widgets/loading_state_widget.dart';

class UsageAnalyticsScreen extends StatelessWidget {
  const UsageAnalyticsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Detailed Analytics'),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: SafeArea(
        child: FutureBuilder<List<Map<String, dynamic>>>(
          future: AppSessionService.instance.getRecentSessions(50),
          builder: (context, snapshot) {
            if (!snapshot.hasData) {
              if (snapshot.hasError) {
                return ErrorStateWidget(error: snapshot.error!);
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
                          const Text(
                            'Duration',
                            style: TextStyle(
                              color: Colors.white24,
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
