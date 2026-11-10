import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/segmentation/models/payload_transfer.dart';
import '../../core/segmentation/transfer_manager.dart';
import '../../state/providers/transfer_providers.dart';

class TransferProgressBar extends ConsumerWidget {
  final TransferProgress progress;
  final String peerId;

  const TransferProgressBar({
    super.key,
    required this.progress,
    required this.peerId,
  });

  IconData _getFileIcon(String mimeType) {
    if (mimeType.startsWith('image/')) return Icons.image_rounded;
    if (mimeType.startsWith('audio/')) return Icons.audiotrack_rounded;
    if (mimeType.startsWith('video/')) return Icons.movie_rounded;
    if (mimeType.contains('pdf')) return Icons.picture_as_pdf_rounded;
    return Icons.insert_drive_file_rounded;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pct = (progress.percentComplete * 100).toStringAsFixed(0);
    final isDone = progress.state == TransferState.completed;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDone ? const Color(0xFF00E676) : const Color(0xFF333333),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(_getFileIcon(progress.mimeType), color: const Color(0xFF00E676), size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  progress.fileName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close_rounded, size: 18, color: Colors.redAccent),
                tooltip: 'Cancel Transfer',
                onPressed: () {
                  ref.read(activeTransfersProvider.notifier).cancelTransfer(progress.payloadId, peerId);
                },
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: progress.percentComplete,
              backgroundColor: Colors.black,
              valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF00E676)),
              minHeight: 6,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '${progress.receivedChunks} / ${progress.totalChunks} chunks ($pct%)',
                style: const TextStyle(fontSize: 10, color: Colors.grey),
              ),
              Text(
                progress.state.name.toUpperCase(),
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  color: isDone ? const Color(0xFF00E676) : Colors.amber,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
