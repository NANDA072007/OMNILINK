import 'package:flutter/material.dart';
import '../../core/crypto/safety_number_generator.dart';
import '../../core/identity/trust_store.dart';

class SafetyNumberDialog extends StatefulWidget {
  final String peerName;
  final String localNodeId;
  final String remoteNodeId;
  final VoidCallback? onStateChanged;

  const SafetyNumberDialog({
    super.key,
    required this.peerName,
    required this.localNodeId,
    required this.remoteNodeId,
    this.onStateChanged,
  });

  @override
  State<SafetyNumberDialog> createState() => _SafetyNumberDialogState();
}

class _SafetyNumberDialogState extends State<SafetyNumberDialog> {
  late String _safetyNumber;
  late String _fingerprint;
  TrustRecord? _trustRecord;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    _safetyNumber = SafetyNumberGenerator.generateSafetyNumber(
      localPublicKeyHex: widget.localNodeId,
      remotePublicKeyHex: widget.remoteNodeId,
    );
    _fingerprint = SafetyNumberGenerator.computeFingerprint(widget.remoteNodeId);

    final record = await TrustStore.instance.getTrustRecord(widget.remoteNodeId, _fingerprint);
    if (mounted) {
      setState(() {
        _trustRecord = record;
        _isLoading = false;
      });
    }
  }

  Future<void> _verifyManual() async {
    await TrustStore.instance.verifyContact(widget.remoteNodeId, _fingerprint, viaQr: false);
    await _loadData();
    widget.onStateChanged?.call();
  }

  Future<void> _revoke() async {
    await TrustStore.instance.revokeContact(widget.remoteNodeId, _fingerprint);
    await _loadData();
    widget.onStateChanged?.call();
  }

  @override
  Widget build(BuildContext context) {
    final state = _trustRecord?.trustState ?? TrustState.unverified;

    return AlertDialog(
      backgroundColor: const Color(0xFF1E1E1E),
      title: Row(
        children: [
          Icon(
            state.isVerified
                ? Icons.verified_user_rounded
                : (state == TrustState.keyChangedSinceVerification
                    ? Icons.warning_amber_rounded
                    : Icons.shield_outlined),
            color: state.isVerified
                ? const Color(0xFF00E676)
                : (state == TrustState.keyChangedSinceVerification
                    ? Colors.orangeAccent
                    : Colors.grey),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Safety Number with ${widget.peerName}',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
      content: _isLoading
          ? const SizedBox(
              height: 100,
              child: Center(child: CircularProgressIndicator(color: Color(0xFF00E676))),
            )
          : SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (state == TrustState.keyChangedSinceVerification)
                    Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.orangeAccent.withAlpha(40),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.orangeAccent),
                      ),
                      child: const Text(
                        'WARNING: Safety number or public key changed since last verification! This could indicate a key reset or a potential MITM interception.',
                        style: TextStyle(fontSize: 12, color: Colors.orangeAccent),
                      ),
                    ),
                  const Text(
                    'Compare this 60-digit safety number out-of-band with your contact to verify key authenticity:',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.black,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFF333333)),
                    ),
                    child: Text(
                      _safetyNumber,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 14,
                        letterSpacing: 1.5,
                        color: Color(0xFF00E676),
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Key Fingerprint: $_fingerprint',
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 11, color: Colors.grey),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      const Text('Status: ', style: TextStyle(fontSize: 12, color: Colors.grey)),
                      Text(
                        state.name.toUpperCase(),
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: state.isVerified ? const Color(0xFF00E676) : Colors.amber,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
      actions: [
        if (state.isVerified)
          TextButton.icon(
            onPressed: _revoke,
            icon: const Icon(Icons.close_rounded, color: Colors.redAccent),
            label: const Text('Revoke Verification', style: TextStyle(color: Colors.redAccent)),
          )
        else
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00E676),
              foregroundColor: Colors.black,
            ),
            onPressed: _verifyManual,
            icon: const Icon(Icons.check_circle_rounded),
            label: const Text('Mark as Verified'),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close', style: TextStyle(color: Colors.white70)),
        ),
      ],
    );
  }
}
