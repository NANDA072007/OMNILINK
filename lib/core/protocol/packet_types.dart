/// Mesh Packet Types for OMNILINK routing engine and segmentation protocol.
enum PacketType {
  messagePayload,
  routingTableSync,
  routeAdvertisement,
  routeRequest,
  routeReply,
  syncHandshake,
  syncSessionStart,
  syncPage,
  syncSessionEnd,
  transferOffer,
  transferAccept,
  transferReject,
  transferAbort,
  chunkPayload,
  chunkAck,
  unknown;

  String toTypeString() {
    switch (this) {
      case PacketType.messagePayload:
        return 'MESSAGE_PAYLOAD';
      case PacketType.routingTableSync:
        return 'ROUTING_TABLE_SYNC';
      case PacketType.routeAdvertisement:
        return 'ROUTE_ADVERTISEMENT';
      case PacketType.routeRequest:
        return 'ROUTE_REQUEST';
      case PacketType.routeReply:
        return 'ROUTE_REPLY';
      case PacketType.syncHandshake:
        return 'SYNC_HANDSHAKE';
      case PacketType.syncSessionStart:
        return 'SYNC_SESSION_START';
      case PacketType.syncPage:
        return 'SYNC_PAGE';
      case PacketType.syncSessionEnd:
        return 'SYNC_SESSION_END';
      case PacketType.transferOffer:
        return 'TRANSFER_OFFER';
      case PacketType.transferAccept:
        return 'TRANSFER_ACCEPT';
      case PacketType.transferReject:
        return 'TRANSFER_REJECT';
      case PacketType.transferAbort:
        return 'TRANSFER_ABORT';
      case PacketType.chunkPayload:
        return 'CHUNK_PAYLOAD';
      case PacketType.chunkAck:
        return 'CHUNK_ACK';
      case PacketType.unknown:
        return 'UNKNOWN';
    }
  }

  static PacketType fromTypeString(String type) {
    switch (type.toUpperCase()) {
      case 'MESSAGE_PAYLOAD':
        return PacketType.messagePayload;
      case 'ROUTING_TABLE_SYNC':
        return PacketType.routingTableSync;
      case 'ROUTE_ADVERTISEMENT':
        return PacketType.routeAdvertisement;
      case 'ROUTE_REQUEST':
        return PacketType.routeRequest;
      case 'ROUTE_REPLY':
        return PacketType.routeReply;
      case 'SYNC_HANDSHAKE':
        return PacketType.syncHandshake;
      case 'SYNC_SESSION_START':
        return PacketType.syncSessionStart;
      case 'SYNC_PAGE':
        return PacketType.syncPage;
      case 'SYNC_SESSION_END':
        return PacketType.syncSessionEnd;
      case 'TRANSFER_OFFER':
        return PacketType.transferOffer;
      case 'TRANSFER_ACCEPT':
        return PacketType.transferAccept;
      case 'TRANSFER_REJECT':
        return PacketType.transferReject;
      case 'TRANSFER_ABORT':
        return PacketType.transferAbort;
      case 'CHUNK_PAYLOAD':
        return PacketType.chunkPayload;
      case 'CHUNK_ACK':
        return PacketType.chunkAck;
      default:
        return PacketType.unknown;
    }
  }
}

class PacketTypeNames {
  static const String transferOffer = 'TRANSFER_OFFER';
  static const String transferAccept = 'TRANSFER_ACCEPT';
  static const String transferReject = 'TRANSFER_REJECT';
  static const String transferAbort = 'TRANSFER_ABORT';
  static const String chunkPayload = 'CHUNK_PAYLOAD';
  static const String chunkAck = 'CHUNK_ACK';
}
