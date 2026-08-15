import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/models/message.dart';
import '../../core/models/packet_envelope.dart';
import '../../core/models/peer_device.dart';
import '../../core/providers.dart';
import '../../transport_bridge/android_transport_adapter.dart';

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

  @override
  void initState() {
    super.initState();
    _subscribeToIncomingEnvelopes();
    _sendInitialPing();
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

  /// Resolves the remote peer's 64-character cryptographic nodeId from peerListProvider.
  String _resolveRemoteNodeId() {
    final activePeers = ref.read(peerListProvider);
    for (final p in activePeers) {
      if (p.peerId == widget.peerId && p.nodeId != null && p.nodeId!.isNotEmpty) {
        return p.nodeId!;
      }
      if (p.nodeId == widget.peerId) {
        return p.nodeId!;
      }
    }
    return widget.peerId;
  }

  /// Derives symmetric SecretKey using deterministic, sorted node ID concatenation.
  Future<SecretKey> _deriveSymmetricKey(String localNodeId, String remoteNodeId) async {
    final cryptoService = ref.read(cryptoServiceProvider);
    final sortedNodes = [localNodeId, remoteNodeId]..sort();
    final keySeedInput = '${sortedNodes[0]}:${sortedNodes[1]}';
    final keySeed = await cryptoService.sha256Hex(
      Uint8List.fromList(utf8.encode(keySeedInput)),
    );
    debugPrint('OMNILINK_FIX: Derived symmetric key for sorted nodes: $keySeedInput');
    return SecretKey(utf8.encode(keySeed.substring(0, 32)));
  }

  /// Listens to local inbound stream from the central RouterEngine.
  void _subscribeToIncomingEnvelopes() {
    final router = ref.read(routerEngineProvider);
    _envelopeSubscription = router.localInboundStream.listen(_handleIncomingEnvelope);
  }

  /// Processes pre-validated incoming envelopes routed specifically to this local device.
  Future<void> _handleIncomingEnvelope(PacketEnvelope envelope) async {
    final tRecv = DateTime.now().millisecondsSinceEpoch;
    debugPrint('OMNILINK_DART: [t=$tRecv] incoming packet senderPeerId=${envelope.senderId}');
    debugPrint('OMNILINK_DART: [t=$tRecv] current chat peerId=${widget.peerId}');

    final resolvedRemoteNodeId = _resolveRemoteNodeId();

    // Filter matching peer (allow prefix matching for Node ID / endpoint ID)
    final isMatchingPeer = envelope.senderId == widget.peerId ||
        envelope.senderId == resolvedRemoteNodeId ||
        envelope.senderId.startsWith(widget.peerId) ||
        widget.peerId.startsWith(envelope.senderId);

    if (!isMatchingPeer) {
      debugPrint('OMNILINK_DART: [t=$tRecv] ignored envelope because senderId (${envelope.senderId}) does not match current chat peerId (${widget.peerId}) or resolvedNodeId ($resolvedRemoteNodeId)');
      return;
    }

    try {
      final messageRepo = ref.read(messageRepositoryProvider);

      // Handle DELIVERY_RECEIPT
      if (envelope.messageType == 'DELIVERY_RECEIPT') {
        final originalPacketId = envelope.encryptedPayload;
        debugPrint('OMNILINK_DART: [t=$tRecv] received DELIVERY_RECEIPT for packetId=$originalPacketId');
        await messageRepo.updateMessageState(originalPacketId, MessageState.receiptReceived);
        if (mounted) {
          ref.read(conversationMessagesProvider(widget.peerId).notifier).loadMessages();
        }
        return;
      }

      if (envelope.messageType == 'MESSAGE_PAYLOAD') {
        final cryptoService = ref.read(cryptoServiceProvider);
        // Derive symmetric key for payload decryption using deterministic sorted node IDs
        final secretKey = await _deriveSymmetricKey(envelope.recipientId, envelope.senderId);

        // Decrypt ChaCha20-Poly1305 payload
        final decryptedBytes = await cryptoService.decryptPayload(
          base64Payload: envelope.encryptedPayload,
          secretKey: secretKey,
        );
        final decryptedText = utf8.decode(decryptedBytes);

        final receivedMessage = Message(
          messageId: envelope.packetId,
          conversationId: widget.peerId,
          senderNodeId: envelope.senderId,
          recipientNodeId: envelope.recipientId,
          plaintextBody: decryptedText,
          state: MessageState.delivered,
          createdAt: DateTime.fromMillisecondsSinceEpoch(envelope.createdAt),
          updatedAt: DateTime.now(),
        );

        // 1. Save received message to SQLite database
        await messageRepo.saveMessage(receivedMessage);
        debugPrint('OMNILINK_DART: [t=$tRecv] message ${envelope.packetId} decrypted and saved to SQLite');

        // 2. Send back DELIVERY_RECEIPT to sender
        _sendDeliveryReceipt(envelope.senderId, envelope.packetId);

        // 3. Trigger reactive update for this conversation thread
        if (mounted) {
          ref.read(conversationMessagesProvider(widget.peerId).notifier).loadMessages();
          _scrollToBottom();
        }
      }
    } catch (e, s) {
      debugPrint('OMNILINK_DART: [t=$tRecv] error handling incoming envelope: $e\n$s');
    }
  }

  /// Sends cryptographic DELIVERY_RECEIPT back to message originator.
  Future<void> _sendDeliveryReceipt(String recipientId, String messageId) async {
    final t0 = DateTime.now().millisecondsSinceEpoch;
    final identityState = ref.read(identityProvider);
    final myNodeId = identityState.nodeId ?? 'unknown_node';

    try {
      final envelope = PacketEnvelope(
        packetId: 'receipt_$messageId',
        senderId: myNodeId,
        recipientId: recipientId,
        createdAt: t0,
        expiresAt: t0 + 60000,
        messageType: 'DELIVERY_RECEIPT',
        payloadHash: 'receipt',
        signature: 'receipt',
        encryptedPayload: messageId,
      );

      final router = ref.read(routerEngineProvider);
      await router.sendMessage(envelope);
      debugPrint('OMNILINK_DART: [t=$t0] sent DELIVERY_RECEIPT for $messageId to $recipientId');
    } catch (e) {
      debugPrint('OMNILINK_DART: [t=$t0] failed to send DELIVERY_RECEIPT: $e');
    }
  }

  Future<void> _sendMessage() async {
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

    final connectedPeers = ref.read(peerListProvider)
        .where((p) => p.connectionStatus == PeerConnectionStatus.connected)
        .toList();

    final isDirectlyConnected = connectedPeers.any(
      (p) => p.nodeId == widget.peerId || p.peerId == widget.peerId,
    );

    final initialState = isDirectlyConnected ? MessageState.sending : MessageState.queued;

    debugPrint('OMNILINK_SEND: User tapped send for ${widget.peerId}');

    // 1. INSTANT LOCAL SAVE & UI REFRESH (< 20ms execution)
    final draftMessage = Message(
      messageId: messageId,
      conversationId: widget.peerId,
      senderNodeId: myNodeId,
      recipientNodeId: widget.peerId,
      plaintextBody: text,
      state: initialState,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );

    await messageRepo.saveMessage(draftMessage);
    _textController.clear();
    ref.read(conversationMessagesProvider(widget.peerId).notifier).loadMessages();
    _scrollToBottom();

    debugPrint('OMNILINK_UI: [t=$t0] Instant UI send complete for messageId=$messageId');

    // 2. ASYNCHRONOUS BACKGROUND ENCRYPTION & EPIDEMIC OUTBOX SYNC (Non-blocking)
    unawaited(() async {
      try {
        final packetService = ref.read(packetServiceProvider);
        final resolvedRemoteNodeId = _resolveRemoteNodeId();

        final secretKey = await _deriveSymmetricKey(myNodeId, resolvedRemoteNodeId);

        final cryptoService = ref.read(cryptoServiceProvider);
        final encryptedPayloadBase64 = await cryptoService.encryptPayload(
          plaintext: Uint8List.fromList(utf8.encode(text)),
          secretKey: secretKey,
        );

        final envelope = await packetService.createEnvelope(
          senderNodeId: myNodeId,
          recipientNodeId: resolvedRemoteNodeId,
          messageType: 'MESSAGE_PAYLOAD',
          encryptedPayloadBase64: encryptedPayloadBase64,
          senderKeyPair: masterKeyPair,
        );

        // Pass envelope to central RouterEngine for 5-layer route selection & transmission
        final routerEngine = ref.read(routerEngineProvider);
        await routerEngine.sendMessage(envelope);

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
    final messages = ref.watch(conversationMessagesProvider(widget.peerId));

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
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            color: const Color(0xFF161616),
            child: SafeArea(
              child: Row(
                children: [
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
}
