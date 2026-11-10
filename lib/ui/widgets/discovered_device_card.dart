import 'dart:ui';
import 'package:flutter/material.dart';
import '../../state/models/discovery_state.dart';

class DiscoveredDeviceCard extends StatelessWidget {
  final DiscoveredPeer peer;
  final bool isConnecting;
  final bool isConnected;
  final VoidCallback onConnect;

  final VoidCallback? onOpenChat;

  const DiscoveredDeviceCard({
    super.key,
    required this.peer,
    this.isConnecting = false,
    this.isConnected = false,
    required this.onConnect,
    this.onOpenChat,
  });

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0.0, end: 1.0),
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOutCubic,
      builder: (context, value, child) {
        return Transform.scale(
          scale: 0.95 + (0.05 * value),
          child: Opacity(
            opacity: value,
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: isConnected
                      ? const Color(0xFF00E676).withValues(alpha: 0.6)
                      : isConnecting
                          ? const Color(0xFF29B6F6).withValues(alpha: 0.6)
                          : Colors.white.withValues(alpha: 0.12),
                  width: 1.5,
                ),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Colors.white.withValues(alpha: 0.08),
                    Colors.white.withValues(alpha: 0.02),
                  ],
                ),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Row(
                      children: [
                        Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: isConnected
                                ? const Color(0xFF00E676).withValues(alpha: 0.2)
                                : const Color(0xFF29B6F6).withValues(alpha: 0.2),
                          ),
                          child: Icon(
                            Icons.cell_tower,
                            color: isConnected
                                ? const Color(0xFF00E676)
                                : const Color(0xFF29B6F6),
                            size: 22,
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                peer.deviceName,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 15,
                                  letterSpacing: 0.5,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Row(
                                children: [
                                  Container(
                                    width: 6,
                                    height: 6,
                                    decoration: const BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: Color(0xFF00E676),
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  const Text(
                                    'Nearby · Strong signal',
                                    style: TextStyle(
                                      color: Colors.white60,
                                      fontSize: 11,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        ElevatedButton(
                          onPressed: isConnected
                              ? onOpenChat
                              : (isConnecting ? null : onConnect),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: isConnected
                                ? const Color(0xFF00E676)
                                : const Color(0xFF29B6F6),
                            foregroundColor: Colors.black,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 10,
                            ),
                          ),
                          child: Text(
                            isConnected
                                ? 'OPEN CHAT'
                                : isConnecting
                                    ? 'CONNECTING'
                                    : 'CONNECT',
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                              letterSpacing: 0.8,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
