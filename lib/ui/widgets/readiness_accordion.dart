import 'dart:ui';
import 'package:flutter/material.dart';
import '../../state/models/radio_status_state.dart';

class ReadinessAccordion extends StatefulWidget {
  final RadioStatusState radioState;
  final VoidCallback onToggleBluetooth;
  final VoidCallback onToggleWifi;
  final VoidCallback onToggleLocation;

  const ReadinessAccordion({
    super.key,
    required this.radioState,
    required this.onToggleBluetooth,
    required this.onToggleWifi,
    required this.onToggleLocation,
  });

  @override
  State<ReadinessAccordion> createState() => _ReadinessAccordionState();
}

class _ReadinessAccordionState extends State<ReadinessAccordion> {
  bool _isExpanded = false;

  @override
  Widget build(BuildContext context) {
    final isAllReady = widget.radioState.isReady;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.08),
          width: 1,
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Column(
            children: [
              InkWell(
                onTap: () {
                  setState(() {
                    _isExpanded = !_isExpanded;
                  });
                },
                borderRadius: BorderRadius.circular(16),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        isAllReady ? Icons.check_circle : Icons.error_outline,
                        color: isAllReady
                            ? const Color(0xFF00E676)
                            : const Color(0xFFFF5252),
                        size: 18,
                      ),
                      const SizedBox(width: 10),
                      Text(
                        'Connection readiness',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.8),
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        isAllReady ? 'Fully Ready' : 'Action Needed',
                        style: TextStyle(
                          color: isAllReady
                              ? const Color(0xFF00E676)
                              : const Color(0xFFFF5252),
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Icon(
                        _isExpanded
                            ? Icons.keyboard_arrow_up
                            : Icons.keyboard_arrow_down,
                        color: Colors.white54,
                        size: 20,
                      ),
                    ],
                  ),
                ),
              ),
              if (_isExpanded) ...[
                const Divider(color: Colors.white10, height: 1),
                Padding(
                  padding: const EdgeInsets.all(14.0),
                  child: Column(
                    children: [
                      _buildDiagnosticRow(
                        label: 'Bluetooth Transport',
                        status: widget.radioState.bluetoothStatus,
                        onTap: widget.onToggleBluetooth,
                      ),
                      const SizedBox(height: 10),
                      _buildDiagnosticRow(
                        label: 'Wi-Fi High-Speed Link',
                        status: widget.radioState.wifiStatus,
                        onTap: widget.onToggleWifi,
                      ),
                      const SizedBox(height: 10),
                      _buildDiagnosticRow(
                        label: 'Location Service (GPS)',
                        status: widget.radioState.locationStatus,
                        onTap: widget.onToggleLocation,
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDiagnosticRow({
    required String label,
    required RadioCapabilityStatus status,
    required VoidCallback onTap,
  }) {
    final bool isOk = status == RadioCapabilityStatus.ready;
    final String statusText = status == RadioCapabilityStatus.ready
        ? '✓ Ready'
        : status == RadioCapabilityStatus.permissionRequired
            ? 'GRANT PERMISSION'
            : status == RadioCapabilityStatus.disabled
                ? 'TURN ON'
                : 'Unsupported';

    final Color color = isOk
        ? const Color(0xFF00E676)
        : status == RadioCapabilityStatus.permissionRequired
            ? const Color(0xFF29B6F6)
            : const Color(0xFFFF5252);

    return InkWell(
      onTap: onTap,
      child: Row(
        children: [
          Text(
            label,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 12,
            ),
          ),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: color.withValues(alpha: 0.4)),
            ),
            child: Text(
              statusText,
              style: TextStyle(
                color: color,
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
