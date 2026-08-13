import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/models/message.dart';
import '../../core/models/packet_envelope.dart';
import '../../core/providers.dart';

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
  }

  @override
  void dispose() {
    _envelopeSubscription?.cancel();
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// Listens to local inbound stream from the global MeshRouter.
  void _subscribeToIncomingEnvelopes() {
    final router = ref.read(meshRouterProvider);
    _envelopeSubscription = router.localInboundStream.listen(_handleIncomingEnvelope);
  }

  /// Processes pre-validated incoming envelopes routed specifically to this local device.
  Future<void> _handleIncomingEnvelope(PacketEnvelope envelope) async {
    // Filter packets by sender ID to match this conversation thread
    final isMatchingPeer = envelope.senderId == widget.peerId ||
        envelope.senderId.startsWith(widget.peerId);
    if (!isMatchingPeer) return;

    try {
      final cryptoService = ref.read(cryptoServiceProvider);

      if (envelope.messageType == 'MESSAGE_PAYLOAD') {
        // Derive symmetric key for payload decryption
        final keySeed = await cryptoService.sha256Hex(
          Uint8List.fromList(
            utf8.encode('${envelope.senderId}:${envelope.recipientId}'),
          ),
        );
        final secretKey = SecretKey(utf8.encode(keySeed.substring(0, 32)));

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
        final messageRepo = ref.read(messageRepositoryProvider);
        await messageRepo.saveMessage(receivedMessage);

        // 2. Trigger reactive update for this conversation thread
        if (mounted) {
          ref.read(conversationMessagesProvider(widget.peerId).notifier).loadMessages();
          _scrollToBottom();
        }
      }
    } catch (e) {
      // Decryption failed cleanly
    }
  }

  Future<void> _sendMessage() async {
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

    final messageId = _uuid.v4();
    final messageRepo = ref.read(messageRepositoryProvider);
    final outboxRepo = ref.read(outboxRepositoryProvider);

    // 1. Create Message record with state MessageState.sending
    final sendingMessage = Message(
      messageId: messageId,
      conversationId: widget.peerId,
      senderNodeId: myNodeId,
      recipientNodeId: widget.peerId,
      plaintextBody: text,
      state: MessageState.sending,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );

    // 2. Save message to SQLite database BEFORE transmitting
    await messageRepo.saveMessage(sendingMessage);
    _textController.clear();
    ref.read(conversationMessagesProvider(widget.peerId).notifier).loadMessages();
    _scrollToBottom();

    try {
      final cryptoService = ref.read(cryptoServiceProvider);
      final packetService = ref.read(packetServiceProvider);

      // Derive symmetric secret key for payload encryption
      final keySeed = await cryptoService.sha256Hex(
        Uint8List.fromList(utf8.encode('$myNodeId:${widget.peerId}')),
      );
      final secretKey = SecretKey(utf8.encode(keySeed.substring(0, 32)));

      // Encrypt text payload with ChaCha20-Poly1305
      final encryptedPayloadBase64 = await cryptoService.encryptPayload(
        plaintext: Uint8List.fromList(utf8.encode(text)),
        secretKey: secretKey,
      );

      // Create signed Protocol v0.1 PacketEnvelope
      final envelope = await packetService.createEnvelope(
        senderNodeId: myNodeId,
        recipientNodeId: widget.peerId,
        messageType: 'MESSAGE_PAYLOAD',
        encryptedPayloadBase64: encryptedPayloadBase64,
        senderKeyPair: masterKeyPair,
      );

      // Serialize envelope to JSON bytes and send via transport
      final jsonString = envelope.toJson();
      final packetBytes = Uint8List.fromList(utf8.encode(jsonString));

      final adapter = ref.read(transportAdapterProvider);
      final success = await adapter.sendPacket(widget.peerId, packetBytes);

      if (success) {
        // 3a. Update SQLite message state to delivered
        await messageRepo.updateMessageState(messageId, MessageState.delivered);
      } else {
        // 3b. Update SQLite message state to failed and save to outbox queue
        await messageRepo.updateMessageState(messageId, MessageState.failed);
        await outboxRepo.saveToOutbox(envelope);
      }
    } catch (e) {
      await messageRepo.updateMessageState(messageId, MessageState.failed);
    }

    if (mounted) {
      ref.read(conversationMessagesProvider(widget.peerId).notifier).loadMessages();
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
      case MessageState.queued:
      case MessageState.encrypted:
      case MessageState.searchingForPeer:
        return const Text('⏳', style: TextStyle(fontSize: 12));
      case MessageState.sending:
        return const Text('✓', style: TextStyle(fontSize: 12, color: Colors.grey));
      case MessageState.delivered:
        return const Text('✓✓', style: TextStyle(fontSize: 12, color: Colors.grey));
      case MessageState.receiptReceived:
        return const Text('✓✓', style: TextStyle(fontSize: 12, color: Color(0xFF00E676)));
      case MessageState.failed:
        return const Text('❌', style: TextStyle(fontSize: 12, color: Colors.red));
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
                          'ChaCha20-Poly1305 • Ed25519 Signatures • Mesh Relay Router',
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
