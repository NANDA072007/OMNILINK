import 'package:flutter/material.dart';
import '../../core/diagnostics/metrics_service.dart';

class PeerLinkQualityBadge extends StatelessWidget {
  final PeerLinkMetrics metrics;

  const PeerLinkQualityBadge({
    super.key,
    required this.metrics,
  });

  Color _getBadgeColor(LinkQualityGrade grade) {
    switch (grade) {
      case LinkQualityGrade.excellent:
        return const Color(0xFF00E676); // Green
      case LinkQualityGrade.good:
        return Colors.tealAccent;
      case LinkQualityGrade.fair:
        return Colors.amber;
      case LinkQualityGrade.poor:
        return Colors.redAccent;
      case LinkQualityGrade.unknown:
        return Colors.grey;
    }
  }

  IconData _getBadgeIcon(LinkQualityGrade grade) {
    switch (grade) {
      case LinkQualityGrade.excellent:
        return Icons.wifi_rounded;
      case LinkQualityGrade.good:
        return Icons.network_wifi_rounded;
      case LinkQualityGrade.fair:
        return Icons.network_wifi_3_bar_rounded;
      case LinkQualityGrade.poor:
        return Icons.network_wifi_1_bar_rounded;
      case LinkQualityGrade.unknown:
        return Icons.wifi_off_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    final grade = metrics.qualityGrade;
    final color = _getBadgeColor(grade);
    final icon = _getBadgeIcon(grade);

    final successPct = (metrics.successRate * 100).toStringAsFixed(0);
    final latMs = metrics.averageLatencyMs.toStringAsFixed(0);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withAlpha(30),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withAlpha(120), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(
            '${grade.name.toUpperCase()} • $successPct% • ${latMs}ms',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}
