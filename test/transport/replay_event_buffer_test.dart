import 'dart:collection';
import 'package:flutter_test/flutter_test.dart';

class TestNativeEventBuffer {
  static const int maxBufferSize = 512;
  int _sequenceCounter = 0;
  int _droppedCount = 0;

  final Queue<Map<String, dynamic>> _buffer = DoubleLinkedQueue<Map<String, dynamic>>();

  int get sequenceCounter => _sequenceCounter;
  int get droppedCount => _droppedCount;
  int get bufferedCount => _buffer.length;

  Map<String, dynamic> createEvent(String type, Map<String, dynamic> payload) {
    _sequenceCounter++;
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final eventId = 'evt_${timestamp}_$_sequenceCounter';

    final event = <String, dynamic>{
      'eventId': eventId,
      'sequenceNumber': _sequenceCounter,
      'timestamp': timestamp,
      'type': type,
      ...payload,
    };

    if (_buffer.length >= maxBufferSize) {
      _buffer.removeFirst(); // Drop oldest event
      _droppedCount++;
    }
    _buffer.add(event);
    return event;
  }

  List<Map<String, dynamic>> drainBufferOnReattach() {
    final replayed = _buffer.toList();
    _buffer.clear();
    return replayed;
  }
}

class TestDartEventAdapter {
  int lastProcessedSequenceNumber = 0;
  final List<Map<String, dynamic>> processedEvents = [];
  int droppedDuplicateCount = 0;

  void handleEvent(Map<String, dynamic> map) {
    final seq = (map['sequenceNumber'] as num?)?.toInt();
    if (seq != null) {
      if (seq <= lastProcessedSequenceNumber) {
        droppedDuplicateCount++;
        return;
      }
      lastProcessedSequenceNumber = seq;
    }
    processedEvents.add(map);
  }
}

void main() {
  group('Replay-Safe EventChannel Event Buffering & Deduplication Tests', () {
    late TestNativeEventBuffer nativeBuffer;
    late TestDartEventAdapter dartAdapter;

    setUp(() {
      nativeBuffer = TestNativeEventBuffer();
      dartAdapter = TestDartEventAdapter();
    });

    test('Events emitted before Dart listener is active are queued in sequence order', () {
      nativeBuffer.createEvent('rfcommConnected', {'peerId': 'peer_101'});
      nativeBuffer.createEvent('incomingPacket', {'peerId': 'peer_101', 'bytes': [1, 2, 3]});
      nativeBuffer.createEvent('rfcommDisconnected', {'peerId': 'peer_101'});

      expect(nativeBuffer.bufferedCount, equals(3));
      expect(nativeBuffer.sequenceCounter, equals(3));

      // Simulate Dart listener reattachment
      final replayed = nativeBuffer.drainBufferOnReattach();
      expect(replayed.length, equals(3));

      for (final evt in replayed) {
        dartAdapter.handleEvent(evt);
      }

      expect(dartAdapter.processedEvents.length, equals(3));
      expect(dartAdapter.lastProcessedSequenceNumber, equals(3));
      expect(dartAdapter.processedEvents[0]['type'], equals('rfcommConnected'));
      expect(dartAdapter.processedEvents[1]['type'], equals('incomingPacket'));
      expect(dartAdapter.processedEvents[2]['type'], equals('rfcommDisconnected'));
    });

    test('Buffer caps at 512 events and drops oldest on overflow', () {
      // Emit 600 events into buffer without active sink
      for (int i = 1; i <= 600; i++) {
        nativeBuffer.createEvent('testEvent', {'index': i});
      }

      expect(nativeBuffer.sequenceCounter, equals(600));
      expect(nativeBuffer.bufferedCount, equals(512));
      expect(nativeBuffer.droppedCount, equals(88));

      final replayed = nativeBuffer.drainBufferOnReattach();
      expect(replayed.length, equals(512));
      // First replayed event should be index 89 (1 to 88 dropped)
      expect(replayed.first['index'], equals(89));
      expect(replayed.last['index'], equals(600));
    });

    test('Dart adapter deduplicates replayed events with sequence <= lastProcessedSequence', () {
      final evt1 = nativeBuffer.createEvent('rfcommConnected', {'peerId': 'peer_A'});
      final evt2 = nativeBuffer.createEvent('incomingPacket', {'peerId': 'peer_A'});

      dartAdapter.handleEvent(evt1);
      dartAdapter.handleEvent(evt2);
      expect(dartAdapter.lastProcessedSequenceNumber, equals(2));

      // Simulate replaying duplicate evt1 and evt2
      dartAdapter.handleEvent(evt1);
      dartAdapter.handleEvent(evt2);

      expect(dartAdapter.droppedDuplicateCount, equals(2));
      expect(dartAdapter.processedEvents.length, equals(2));
    });

    test('Sequence numbers increase monotonically without gaps', () {
      final events = <Map<String, dynamic>>[];
      for (int i = 0; i < 50; i++) {
        events.add(nativeBuffer.createEvent('seqTest', {'i': i}));
      }

      for (int i = 0; i < events.length; i++) {
        expect(events[i]['sequenceNumber'], equals(i + 1));
      }
    });
  });
}
