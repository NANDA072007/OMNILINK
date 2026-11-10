import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../state/models/discovery_state.dart';

class RadarWidget extends StatefulWidget {
  final DiscoveryStatus status;
  final List<DiscoveredPeer> peers;
  final String? connectedPeerName;
  final int? rttMs;

  const RadarWidget({
    super.key,
    required this.status,
    required this.peers,
    this.connectedPeerName,
    this.rttMs,
  });

  @override
  State<RadarWidget> createState() => _RadarWidgetState();
}

class _RadarWidgetState extends State<RadarWidget>
    with TickerProviderStateMixin {
  late AnimationController _sweepController;
  late AnimationController _pulseController;
  late AnimationController _waveController;

  @override
  void initState() {
    super.initState();
    _sweepController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    );

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);

    _waveController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );

    if (widget.status == DiscoveryStatus.discovering ||
        widget.status == DiscoveryStatus.peerFound) {
      _sweepController.repeat();
    }
  }

  @override
  void didUpdateWidget(RadarWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.status == DiscoveryStatus.discovering ||
        widget.status == DiscoveryStatus.peerFound) {
      if (!_sweepController.isAnimating) {
        _sweepController.repeat();
      }
    } else {
      if (_sweepController.isAnimating) {
        _sweepController.stop();
      }
    }

    if (widget.status == DiscoveryStatus.connecting) {
      _waveController.repeat();
    } else {
      if (_waveController.isAnimating) {
        _waveController.stop();
      }
    }
  }

  @override
  void dispose() {
    _sweepController.dispose();
    _pulseController.dispose();
    _waveController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([
        _sweepController,
        _pulseController,
        _waveController,
      ]),
      builder: (context, child) {
        return CustomPaint(
          size: const Size(280, 280),
          painter: RadarPainter(
            sweepAngle: _sweepController.value * 2 * math.pi,
            pulseFactor: _pulseController.value,
            waveFactor: _waveController.value,
            status: widget.status,
            peers: widget.peers,
            connectedPeerName: widget.connectedPeerName,
            rttMs: widget.rttMs,
          ),
        );
      },
    );
  }
}

class RadarPainter extends CustomPainter {
  final double sweepAngle;
  final double pulseFactor;
  final double waveFactor;
  final DiscoveryStatus status;
  final List<DiscoveredPeer> peers;
  final String? connectedPeerName;
  final int? rttMs;

  RadarPainter({
    required this.sweepAngle,
    required this.pulseFactor,
    required this.waveFactor,
    required this.status,
    required this.peers,
    this.connectedPeerName,
    this.rttMs,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxRadius = size.width / 2 - 12;

    // 1. Outer & Inner Concentric Grid Rings
    final ringPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.08)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;

    for (int i = 1; i <= 4; i++) {
      final radius = maxRadius * (i / 4);
      canvas.drawCircle(center, radius, ringPaint);
    }

    // 2. Crosshair Axes
    final axisPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.04)
      ..strokeWidth = 1.0;

    canvas.drawLine(
      Offset(center.dx - maxRadius, center.dy),
      Offset(center.dx + maxRadius, center.dy),
      axisPaint,
    );
    canvas.drawLine(
      Offset(center.dx, center.dy - maxRadius),
      Offset(center.dx, center.dy + maxRadius),
      axisPaint,
    );

    // 3. Rotating Radar Sweep Shader
    if (status == DiscoveryStatus.discovering ||
        status == DiscoveryStatus.peerFound ||
        status == DiscoveryStatus.startingDiscovery) {
      final sweepRect = Rect.fromCircle(center: center, radius: maxRadius);
      final sweepGradient = SweepGradient(
        center: Alignment.center,
        startAngle: 0.0,
        endAngle: math.pi / 2,
        colors: [
          const Color(0xFF00E676).withValues(alpha: 0.0),
          const Color(0xFF00E676).withValues(alpha: 0.25),
        ],
        stops: const [0.0, 1.0],
        transform: GradientRotation(sweepAngle),
      );

      final sweepPaint = Paint()
        ..shader = sweepGradient.createShader(sweepRect)
        ..style = PaintingStyle.fill;

      canvas.drawCircle(center, maxRadius, sweepPaint);
    }

    // 4. Discovered Peer Nodes Positioned Radially
    const nodeRadius = 8.0;
    for (int i = 0; i < peers.length; i++) {
      final angle = (i * (2 * math.pi / math.max(peers.length, 1))) - math.pi / 4;
      final dist = maxRadius * 0.65;
      final peerOffset = Offset(
        center.dx + dist * math.cos(angle),
        center.dy + dist * math.sin(angle),
      );

      // Connection Line to Center
      final linePaint = Paint()
        ..color = const Color(0xFF00E676).withValues(alpha: 0.3)
        ..strokeWidth = 1.5;

      canvas.drawLine(center, peerOffset, linePaint);

      // Peer Node Dot
      final peerDotPaint = Paint()
        ..color = const Color(0xFF00E676)
        ..style = PaintingStyle.fill;

      canvas.drawCircle(peerOffset, nodeRadius, peerDotPaint);

      // Peer Pulse Glow Ring
      final peerGlowPaint = Paint()
        ..color = const Color(0xFF00E676).withValues(alpha: 0.2 * pulseFactor)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0;

      canvas.drawCircle(peerOffset, nodeRadius + 6 * pulseFactor, peerGlowPaint);
    }

    // 5. Connecting Traveling Wave Animation
    if (status == DiscoveryStatus.connecting && peers.isNotEmpty) {
      const angle = -math.pi / 4;
      final dist = maxRadius * 0.65;
      final peerOffset = Offset(
        center.dx + dist * math.cos(angle),
        center.dy + dist * math.sin(angle),
      );

      final waveOffset = Offset(
        center.dx + (peerOffset.dx - center.dx) * waveFactor,
        center.dy + (peerOffset.dy - center.dy) * waveFactor,
      );

      final wavePaint = Paint()
        ..color = const Color(0xFF29B6F6)
        ..style = PaintingStyle.fill;

      canvas.drawCircle(waveOffset, 5.0, wavePaint);
    }

    // 6. Center OMNILINK Core Node (Breathing Pulse)
    final centerCoreColor = status == DiscoveryStatus.connected
        ? const Color(0xFF00E676)
        : status == DiscoveryStatus.connecting
            ? const Color(0xFF29B6F6)
            : status == DiscoveryStatus.discovering
                ? const Color(0xFF00E676)
                : Colors.white70;

    final pulseRadius = 14.0 + (pulseFactor * 4.0);
    final coreGlowPaint = Paint()
      ..color = centerCoreColor.withValues(alpha: 0.25 * pulseFactor)
      ..style = PaintingStyle.fill;

    canvas.drawCircle(center, pulseRadius + 8, coreGlowPaint);

    final corePaint = Paint()
      ..color = centerCoreColor
      ..style = PaintingStyle.fill;

    canvas.drawCircle(center, 12, corePaint);

    final innerDotPaint = Paint()
      ..color = const Color(0xFF0D0E15)
      ..style = PaintingStyle.fill;

    canvas.drawCircle(center, 4, innerDotPaint);
  }

  @override
  bool shouldRepaint(covariant RadarPainter oldDelegate) {
    return oldDelegate.sweepAngle != sweepAngle ||
        oldDelegate.pulseFactor != pulseFactor ||
        oldDelegate.waveFactor != waveFactor ||
        oldDelegate.status != status ||
        oldDelegate.peers.length != peers.length ||
        oldDelegate.rttMs != rttMs;
  }
}
