import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:mime/mime.dart';
import '../../core/database/database_service.dart';
import '../../core/models/message.dart';
import '../../core/models/packet_envelope.dart';
import '../../core/models/peer_device.dart';
import '../../core/protocol/chunk_payload_models.dart';
import '../../core/protocol/packet_types.dart';
import '../../core/providers.dart';
import '../../core/segmentation/models/payload_transfer.dart';
import '../../core/segmentation/payload_segmenter.dart';
import '../../state/providers/transfer_providers.dart';
import '../../transport_bridge/android_transport_adapter.dart';
import '../widgets/qr_verification_sheet.dart';
import '../widgets/safety_number_dialog.dart';
import '../widgets/transfer_progress_bar.dart';

class ChatScreen extends ConsumerStatefulWidget {
  final String peerId;
  final String? peerName;

  const ChatScreen({
    super.key,
    required this.peerId,
    this.peerName,
  });

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final Uuid _uuid = const Uuid();
  StreamSubscription<PacketEnvelope>? _envelopeSubscription;

  String? _cachedRemoteStaticX25519Key;

  @override
  void initState() {
    super.initState();
    _subscribeToIncomingEnvelopes();
    _sendInitialPing();
    _loadPeerInfo();
  }

  Future<void> _loadPeerInfo() async {
    try {
      final peerRepo = ref.read(peerRepositoryProvider);
      final resolvedNodeId = _resolveRemoteNodeId();
      final peer = await peerRepo.getPeerByNodeId(resolvedNodeId);
      if (peer?.staticX25519PublicKeyHex != null && mounted) {
        setState(() {
          _cachedRemoteStaticX25519Key = peer!.staticX25519PublicKeyHex;
        });
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _envelopeSubscription?.cancel();
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// Sends application-level PING on chat open to test bidirectional channel.
  void _sendInitialPing() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Chat session established
    });
  }

  bool _isSending = false;

  /// Resolves the remote peer's 64-character cryptographic nodeId from peerListProvider.
  String _resolveRemoteNodeId() {
    final activePeers = ref.read(peerListProvider);
    for (final p in activePeers) {
      if (p.peerId == widget.peerId && p.nodeId != null && p.nodeId!.isNotEmpty) {
        // Auto-migrate transient peerId entries to permanent nodeId in SQLite
        ref.read(messageRepositoryProvider).migrateConversationId(widget.peerId, p.nodeId!);
        return p.nodeId!;
      }
      if (p.nodeId == widget.peerId) {
        return p.nodeId!;
      }
    }
    return widget.peerId;
  }

  /// Resolves the native transport peerId (endpoint ID) for radio operations.
  String _resolveTransportPeerId() {
    final activePeers = ref.read(peerListProvider);
    for (final p in activePeers) {
      if (p.nodeId == widget.peerId || p.peerId == widget.peerId) {
        return p.peerId;
      }
    }
    return widget.peerId;
  }

  /// Resolves the remote peer's verified static X25519 encryption key from peerListProvider or database cache.
  String? _resolveRemoteStaticX25519PublicKey() {
    final activePeers = ref.read(peerListProvider);
    final resolvedNodeId = _resolveRemoteNodeId();
    for (final p in activePeers) {
      if ((p.peerId == widget.peerId || p.nodeId == widget.peerId || p.nodeId == resolvedNodeId) &&
          p.staticX25519PublicKeyHex != null &&
          p.staticX25519PublicKeyHex!.isNotEmpty) {
        return p.staticX25519PublicKeyHex;
      }
    }
    return _cachedRemoteStaticX25519Key;
  }

  /// Listens to local inbound stream from the central RouterEngine.
  void _subscribeToIncomingEnvelopes() {
    final router = ref.read(routerEngineProvider);
    _envelopeSubscription = router.localInboundStream.listen(_handleIncomingEnvelope);
  }

  /// Processes pre-validated incoming envelopes routed specifically to this local device.
  Future<void> _handleIncomingEnvelope(PacketEnvelope envelope) async {
    final resolvedRemoteNodeId = _resolveRemoteNodeId();

    final isMatchingPeer = envelope.senderId == resolvedRemoteNodeId ||
        envelope.recipientId == resolvedRemoteNodeId ||
        envelope.senderId == widget.peerId ||
        envelope.senderId.startsWith(widget.peerId) ||
        widget.peerId.startsWith(envelope.senderId);

    if (!isMatchingPeer) return;

    if (mounted) {
      ref.read(conversationMessagesProvider(resolvedRemoteNodeId).notifier).loadMessages();
      ref.read(conversationMessagesProvider(widget.peerId).notifier).loadMessages();
      _scrollToBottom();
    }
  }

  Future<void> _sendMessage() async {
    if (_isSending) return;
    _isSending = true;

    try {
      final t0 = DateTime.now().millisecondsSinceEpoch;
      final text = _textController.text.trim();
      if (text.isEmpty) return;

      final identityState = ref.read(identityProvider);
      final masterKeyPair = identityState.masterKeyPair;
      final myNodeId = identityState.nodeId;

      if (masterKeyPair == null || myNodeId == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Identity keypair not ready yet.')),
        );
        return;
      }

      final daemon = ref.read(outboxDaemonProvider);
      final messageId = _uuid.v4();
      final messageRepo = ref.read(messageRepositoryProvider);

      final resolvedRemoteNodeId = _resolveRemoteNodeId();

    final connectedPeers = ref.read(peerListProvider)
        .where((p) => p.connectionStatus == PeerConnectionStatus.connected)
        .toList();

    final isDirectlyConnected = connectedPeers.any(
      (p) => p.nodeId == resolvedRemoteNodeId || p.peerId == widget.peerId || p.nodeId == widget.peerId,
    );

    final initialState = isDirectlyConnected ? MessageState.sending : MessageState.queued;

    debugPrint('OMNILINK_SEND: User tapped send for $resolvedRemoteNodeId');

    // 1. INSTANT LOCAL SAVE & UI REFRESH (< 20ms execution)
    final draftMessage = Message(
      messageId: messageId,
      conversationId: resolvedRemoteNodeId,
      senderNodeId: myNodeId,
      recipientNodeId: resolvedRemoteNodeId,
      plaintextBody: text,
      state: initialState,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );

    await messageRepo.saveMessage(draftMessage);
    _textController.clear();
    ref.read(conversationMessagesProvider(resolvedRemoteNodeId).notifier).loadMessages();
    ref.read(conversationMessagesProvider(widget.peerId).notifier).loadMessages();
    _scrollToBottom();

    debugPrint('OMNILINK_UI: [t=$t0] Instant UI send complete for messageId=$messageId');

    // 2. ASYNCHRONOUS BACKGROUND ENCRYPTION & EPIDEMIC OUTBOX SYNC (Non-blocking)
    unawaited(() async {
      try {
        final packetService = ref.read(packetServiceProvider);
        final resolvedRemoteNodeId = _resolveRemoteNodeId();
        final staticKeyPair = identityState.staticX25519KeyPair;
        final recipientStaticX25519Hex = _resolveRemoteStaticX25519PublicKey();

        if (recipientStaticX25519Hex == null) {
          // Trigger route advertisement to request remote key bundle over active transport
          final transportPeerId = _resolveTransportPeerId();
          if (transportPeerId.isNotEmpty) {
            ref.read(routerEngineProvider).routeProtocol.sendRouteAdvertisement(transportPeerId);
          }
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Exchanging security keys with peer... Message queued.'),
              ),
            );
          }
          return;
        }

        final envelope = await packetService.createEncryptedMessageEnvelope(
          senderNodeId: myNodeId,
          senderKeyPair: masterKeyPair,
          senderStaticX25519KeyPair: staticKeyPair!,
          recipientNodeId: resolvedRemoteNodeId,
          recipientStaticX25519PublicKeyHex: recipientStaticX25519Hex,
          plaintextBody: text,
          packetId: messageId,
        );

        // Pass envelope to central RouterEngine for 5-layer route selection & transmission
        final routerEngine = ref.read(routerEngineProvider);
        await routerEngine.sendMessage(envelope);
        unawaited(routerEngine.outboxDaemon.flushAll());

        // Refresh UI state after fast flush attempt
        await Future.delayed(const Duration(milliseconds: 300));
        if (mounted) {
          ref.read(conversationMessagesProvider(resolvedRemoteNodeId).notifier).loadMessages();
          ref.read(conversationMessagesProvider(widget.peerId).notifier).loadMessages();
        }

        final adapter = ref.read(transportAdapterProvider);
        final usageMap = (adapter is AndroidTransportAdapter)
            ? await adapter.getBluetoothUsageState()
            : null;

        final isAudioConnected = usageMap?['audioDeviceConnected'] == true;
        final isWifiEnabled = usageMap?['wifiEnabled'] == true;

        final envelopeJson = jsonEncode(envelope.toMap());
        final packetSizeBytes = utf8.encode(envelopeJson).length;

        if (isAudioConnected && !isWifiEnabled && packetSizeBytes >= 1024) {
          debugPrint('OMNILINK_TRANSPORT: message queued due to degraded Bluetooth');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'Large messages will be sent when a faster route is available.',
                ),
              ),
            );
          }
          return;
        }

        debugPrint('OMNILINK_TRANSPORT: message queued because no active route');

        // Trigger background Anti-Entropy Summary Vector Exchange across active radio links
        await daemon.triggerAntiEntropySync();

        if (isAudioConnected && !isWifiEnabled && packetSizeBytes < 1024) {
          unawaited(
            daemon.scheduleDegradedRetry(attemptSend: () async {
              await daemon.triggerAntiEntropySync();
              final isConnected = await adapter.isConnected(widget.peerId);
              return isConnected;
            }),
          );
        }
      } catch (e) {
        debugPrint('OMNILINK_UI: Exception during background outbox queueing: $e');
      }
    }());
    } finally {
      _isSending = false;
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Widget _buildStateIcon(MessageState state) {
    switch (state) {
      case MessageState.draft:
      case MessageState.encrypted:
      case MessageState.searchingForPeer:
        return const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.travel_explore, size: 12, color: Colors.orangeAccent),
            SizedBox(width: 4),
            Text('Searching for route...', style: TextStyle(fontSize: 11, color: Colors.orangeAccent)),
          ],
        );
      case MessageState.queued:
        return const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.schedule, size: 12, color: Colors.amber),
            SizedBox(width: 4),
            Text('Queued in outbox...', style: TextStyle(fontSize: 11, color: Colors.amber)),
          ],
        );
      case MessageState.sending:
        return const Text('✓ Transmitting...', style: TextStyle(fontSize: 11, color: Colors.grey));
      case MessageState.delivered:
        return const Text('✓✓ Delivered to node', style: TextStyle(fontSize: 11, color: Colors.white70));
      case MessageState.receiptReceived:
        return const Text('✓✓ Delivered & Acknowledged', style: TextStyle(fontSize: 11, color: Color(0xFF00E676)));
      case MessageState.failed:
        return const Text('❌ Expired / Failed', style: TextStyle(fontSize: 11, color: Colors.redAccent));
      default:
        return const SizedBox.shrink();
    }
  }

  @override
  Widget build(BuildContext context) {
    final identityState = ref.watch(identityProvider);
    final effectiveId = _resolveRemoteNodeId();
    final messages = ref.watch(conversationMessagesProvider(effectiveId));

    final myNodeId = identityState.nodeId;
    final titleName = widget.peerName ?? widget.peerId;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(titleName),
            Text(
              'Peer ID: ${widget.peerId}',
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.shield_outlined, color: Color(0xFF00E676)),
            tooltip: 'Safety Number & Identity Verification',
            onPressed: () {
              final myNodeId = identityState.nodeId;
              if (myNodeId != null) {
                showDialog(
                  context: context,
                  builder: (_) => SafetyNumberDialog(
                    peerName: titleName,
                    localNodeId: myNodeId,
                    remoteNodeId: effectiveId,
                    onStateChanged: () => setState(() {}),
                  ),
                );
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.qr_code_scanner_rounded, color: Color(0xFF00E676)),
            tooltip: 'QR Code Verification',
            onPressed: () {
              final myNodeId = identityState.nodeId;
              if (myNodeId != null) {
                showModalBottomSheet(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) => QrVerificationSheet(
                    peerName: titleName,
                    localNodeId: myNodeId,
                    remoteNodeId: effectiveId,
                    onStateChanged: () => setState(() {}),
                  ),
                );
              }
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: messages.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.lock_outline_rounded,
                          size: 48,
                          color: Colors.grey.shade700,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'End-to-End Encrypted Channel with $titleName',
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: Colors.white70,
                          ),
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          'ChaCha20-Poly1305 • Blind Flooding Mesh Relay • Store-and-Forward',
                          style: TextStyle(fontSize: 11, color: Colors.grey),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.all(16),
                    itemCount: messages.length,
                    itemBuilder: (context, index) {
                      final msg = messages[index];
                      final isMe = msg.senderNodeId == myNodeId;

                      return Align(
                        alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
                        child: Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            color: isMe
                                ? const Color(0xFF00E676).withAlpha(45)
                                : const Color(0xFF2C2C2C),
                            borderRadius: BorderRadius.only(
                              topLeft: const Radius.circular(16),
                              topRight: const Radius.circular(16),
                              bottomLeft: isMe
                                  ? const Radius.circular(16)
                                  : const Radius.circular(4),
                              bottomRight: isMe
                                  ? const Radius.circular(4)
                                  : const Radius.circular(16),
                            ),
                            border: isMe
                                ? Border.all(
                                    color: const Color(0xFF00E676).withAlpha(100),
                                    width: 0.8,
                                  )
                                : null,
                          ),
                          constraints: BoxConstraints(
                            maxWidth: MediaQuery.of(context).size.width * 0.75,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Flexible(
                                child: Text(
                                  msg.plaintextBody ?? '[Encrypted Payload]',
                                  style: const TextStyle(fontSize: 15),
                                ),
                              ),
                              if (isMe) ...[
                                const SizedBox(width: 8),
                                _buildStateIcon(msg.state),
                              ],
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
          Consumer(
            builder: (context, ref, child) {
              final activeTransfers = ref.watch(activeTransfersProvider);
              if (activeTransfers.isEmpty) return const SizedBox.shrink();

              return Column(
                children: activeTransfers.values
                    .map((p) => TransferProgressBar(progress: p, peerId: widget.peerId))
                    .toList(),
              );
            },
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            color: const Color(0xFF161616),
            child: SafeArea(
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.attach_file_rounded, color: Color(0xFF00E676)),
                    tooltip: 'Send Media / File',
                    onPressed: _pickAndSendFile,
                  ),
                  Expanded(
                    child: TextField(
                      controller: _textController,
                      decoration: InputDecoration(
                        hintText: 'Type encrypted message...',
                        hintStyle: const TextStyle(color: Colors.grey),
                        filled: true,
                        fillColor: const Color(0xFF242424),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: BorderSide.none,
                        ),
                      ),
                      onSubmitted: (_) => _sendMessage(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    style: IconButton.styleFrom(
                      backgroundColor: const Color(0xFF00E676),
                      foregroundColor: Colors.black,
                    ),
                    onPressed: _sendMessage,
                    icon: const Icon(Icons.send_rounded),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickAndSendFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: false,
        type: FileType.any,
      );

      if (result == null || result.files.isEmpty || result.files.first.path == null) {
        return;
      }

      final filePath = result.files.first.path!;
      final file = File(filePath);
      if (!await file.exists()) return;

      final fileName = result.files.first.name;
      final fileSize = await file.length();
      final mimeType = lookupMimeType(filePath) ?? 'application/octet-stream';

      final segmenter = PayloadSegmenter();
      final finalSha256 = await segmenter.calculateFinalSha256(filePath);

      final payloadId = 'pld_${DateTime.now().millisecondsSinceEpoch}_${_uuid.v4().substring(0, 8)}';
      final totalChunks = (fileSize / PayloadSegmenter.defaultMaxChunkSize).ceil();
      final myNodeId = ref.read(identityProvider).nodeId ?? '';
      final remoteNodeId = _resolveRemoteNodeId();

      final offerPayload = TransferOfferPayload(
        payloadId: payloadId,
        fileName: fileName,
        mimeType: mimeType,
        totalSize: fileSize,
        totalChunks: totalChunks,
        finalSha256: finalSha256,
      );

      final offerEnvelopeJson = jsonEncode({
        'packet_id': 'off_$payloadId',
        'sender_id': myNodeId,
        'recipient_id': remoteNodeId,
        'message_type': PacketTypeNames.transferOffer,
        'encrypted_payload': offerPayload.toJson(),
      });

      final transferRecord = PayloadTransfer(
        payloadId: payloadId,
        direction: TransferDirection.outgoing,
        senderNodeId: myNodeId,
        recipientNodeId: remoteNodeId,
        fileName: fileName,
        payloadType: mimeType.split('/').first,
        mimeType: mimeType,
        totalSize: fileSize,
        totalChunks: totalChunks,
        receivedChunks: 0,
        finalSha256: finalSha256,
        transferState: TransferState.pending,
        localFilePath: filePath,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      final db = DatabaseService.instance;
      await db.insert('payload_transfers', transferRecord.toMap());

      final router = ref.read(routerEngineProvider);
      final sendQueueManager = router.sendQueueManager;
      await sendQueueManager.enqueueAndSend(
        packetId: 'off_$payloadId',
        peerId: widget.peerId,
        payloadBytes: Uint8List.fromList(utf8.encode(offerEnvelopeJson)),
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Transfer offer sent for $fileName ($totalChunks chunks)'),
            backgroundColor: const Color(0xFF00E676),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('File selection failed: $e'), backgroundColor: Colors.redAccent),
        );
      }
    }
  }
}
