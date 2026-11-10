import 'dart:convert';
import 'package:flutter/material.dart';
import '../../core/crypto/safety_number_generator.dart';
import '../../core/identity/trust_store.dart';

class QrVerificationSheet extends StatefulWidget {
  final String peerName;
  final String localNodeId;
  final String remoteNodeId;
  final VoidCallback? onStateChanged;

  const QrVerificationSheet({
    super.key,
    required this.peerName,
    required this.localNodeId,
    required this.remoteNodeId,
    this.onStateChanged,
  });

  @override
  State<QrVerificationSheet> createState() => _QrVerificationSheetState();
}

class _QrVerificationSheetState extends State<QrVerificationSheet> {
  final TextEditingController _scanInputController = TextEditingController();
  late String _localFingerprint;
  late String _remoteFingerprint;
  String? _scanErrorMessage;

  @override
  void initState() {
    super.initState();
    _localFingerprint = SafetyNumberGenerator.computeFingerprint(widget.localNodeId);
    _remoteFingerprint = SafetyNumberGenerator.computeFingerprint(widget.remoteNodeId);
  }

  @override
  void dispose() {
    _scanInputController.dispose();
    super.dispose();
  }

  Future<void> _validateScannedData(String rawJson) async {
    try {
      final map = jsonDecode(rawJson) as Map<String, dynamic>;
      final scannedNodeId = map['nodeId'] as String?;
      final scannedFingerprint = map['fingerprint'] as String?;

      if (scannedNodeId == null || scannedFingerprint == null) {
        setState(() { _scanErrorMessage = 'Invalid QR Code payload structure.'; });
        return;
      }

      if (scannedNodeId != widget.remoteNodeId) {
        setState(() {
          _scanErrorMessage = 'QR Code Node ID mismatch! Scanned ID does not match contact ID.';
        });
        return;
      }

      if (scannedFingerprint != _remoteFingerprint) {
        setState(() {
          _scanErrorMessage = 'Key Fingerprint mismatch! Contact public key has changed.';
        });
        return;
      }

      // Successful QR verification
      await TrustStore.instance.verifyContact(widget.remoteNodeId, _remoteFingerprint, viaQr: true);
      widget.onStateChanged?.call();
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Successfully verified ${widget.peerName} via QR Code!'),
            backgroundColor: const Color(0xFF00E676),
          ),
        );
      }
    } catch (e) {
      setState(() { _scanErrorMessage = 'Failed to parse QR Code: $e'; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: const BoxDecoration(
        color: Color(0xFF1E1E1E),
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey.shade700,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Verify ${widget.peerName} via QR',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              'Show your identity QR code to your contact, or paste/scan their code below:',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 16),
            // High contrast QR payload box
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFF00E676), width: 2),
              ),
              child: Column(
                children: [
                  const Icon(Icons.qr_code_2_rounded, size: 80, color: Color(0xFF00E676)),
                  const SizedBox(height: 8),
                  Text(
                    'Fingerprint: $_localFingerprint',
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 12, color: Color(0xFF00E676)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _scanInputController,
              decoration: InputDecoration(
                labelText: 'Paste or Scan Peer QR Data JSON',
                labelStyle: const TextStyle(color: Colors.grey),
                border: const OutlineInputBorder(),
                focusedBorder: const OutlineInputBorder(
                  borderSide: BorderSide(color: Color(0xFF00E676)),
                ),
                errorText: _scanErrorMessage,
              ),
            ),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00E676),
                foregroundColor: Colors.black,
                minimumSize: const Size.fromHeight(48),
              ),
              onPressed: () => _validateScannedData(_scanInputController.text.trim()),
              icon: const Icon(Icons.qr_code_scanner_rounded),
              label: const Text('Verify Scanned QR Payload'),
            ),
          ],
        ),
      ),
    );
  }
}
