import 'dart:math';

/// Class representing an individual encounter connection event between two mesh nodes.
class EncounterEvent {
  final String nodeId;
  final String peerId;
  final DateTime timestamp;
  final String eventType; // 'connected' or 'disconnected'
  final int? rssi;

  const EncounterEvent({
    required this.nodeId,
    required this.peerId,
    required this.timestamp,
    required this.eventType,
    this.rssi,
  });

  Map<String, dynamic> toMap() {
    return {
      'node_id': nodeId,
      'peer_id': peerId,
      'timestamp': timestamp.millisecondsSinceEpoch,
      'event_type': eventType,
      'rssi': rssi,
    };
  }

  factory EncounterEvent.fromMap(Map<String, dynamic> map) {
    return EncounterEvent(
      nodeId: map['node_id'] as String,
      peerId: map['peer_id'] as String,
      timestamp: DateTime.fromMillisecondsSinceEpoch(
        (map['timestamp'] as num).toInt(),
      ),
      eventType: map['event_type'] as String,
      rssi: (map['rssi'] as num?)?.toInt(),
    );
  }
}

/// PRoPHET Delay-Tolerant Network (DTN) Encounter Record tracking delivery predictability.
class EncounterRecord {
  final String nodeId;
  final String peerId;
  final double predictability;
  final int encounterCount;
  final DateTime lastEncounter;
  final DateTime firstEncounter;
  final double avgDurationSeconds;

  const EncounterRecord({
    required this.nodeId,
    required this.peerId,
    this.predictability = 0.75,
    this.encounterCount = 1,
    required this.lastEncounter,
    required this.firstEncounter,
    this.avgDurationSeconds = 0.0,
  });

  /// PRoPHET Delivery Predictability update upon a new encounter.
  /// Formula: P_new = P_old + (1 - P_old) * P_encounter (P_encounter = 0.75)
  EncounterRecord updatePredictability({
    DateTime? now,
    double pEncounter = 0.75,
  }) {
    final currentTime = now ?? DateTime.now();
    final decayed = applyDecay(now: currentTime);

    final double newP =
        decayed.predictability + (1.0 - decayed.predictability) * pEncounter;
    final int newCount = decayed.encounterCount + 1;

    return decayed.copyWith(
      predictability: newP.clamp(0.0, 1.0),
      encounterCount: newCount,
      lastEncounter: currentTime,
    );
  }

  /// PRoPHET Time-based Aging Decay of Delivery Predictability.
  /// Formula: P_decay = P_old * gamma^k (gamma = 0.98, k = hours since last encounter)
  EncounterRecord applyDecay({DateTime? now, double gamma = 0.98}) {
    final currentTime = now ?? DateTime.now();
    final double hours =
        currentTime.difference(lastEncounter).inSeconds / 3600.0;

    if (hours <= 0) return this;

    final double decayedP = predictability * pow(gamma, hours);
    return copyWith(
      predictability: decayedP.clamp(0.0, 1.0),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'node_id': nodeId,
      'peer_id': peerId,
      'predictability': predictability,
      'encounter_count': encounterCount,
      'last_encounter': lastEncounter.millisecondsSinceEpoch,
      'first_encounter': firstEncounter.millisecondsSinceEpoch,
      'avg_duration_seconds': avgDurationSeconds,
    };
  }

  factory EncounterRecord.fromMap(Map<String, dynamic> map) {
    return EncounterRecord(
      nodeId: map['node_id'] as String,
      peerId: map['peer_id'] as String,
      predictability: (map['predictability'] as num?)?.toDouble() ?? 0.75,
      encounterCount: (map['encounter_count'] as num?)?.toInt() ?? 1,
      lastEncounter: DateTime.fromMillisecondsSinceEpoch(
        (map['last_encounter'] as num).toInt(),
      ),
      firstEncounter: DateTime.fromMillisecondsSinceEpoch(
        (map['first_encounter'] as num).toInt(),
      ),
      avgDurationSeconds:
          (map['avg_duration_seconds'] as num?)?.toDouble() ?? 0.0,
    );
  }

  EncounterRecord copyWith({
    String? nodeId,
    String? peerId,
    double? predictability,
    int? encounterCount,
    DateTime? lastEncounter,
    DateTime? firstEncounter,
    double? avgDurationSeconds,
  }) {
    return EncounterRecord(
      nodeId: nodeId ?? this.nodeId,
      peerId: peerId ?? this.peerId,
      predictability: predictability ?? this.predictability,
      encounterCount: encounterCount ?? this.encounterCount,
      lastEncounter: lastEncounter ?? this.lastEncounter,
      firstEncounter: firstEncounter ?? this.firstEncounter,
      avgDurationSeconds: avgDurationSeconds ?? this.avgDurationSeconds,
    );
  }
}
