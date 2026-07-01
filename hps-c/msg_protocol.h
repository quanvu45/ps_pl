#ifndef _MSG_PROTOCOL_H_
#define _MSG_PROTOCOL_H_

#include <stdint.h>

// =============================================================================
// Message Protocol Definitions for PS-PL Shared Memory Communication
//
// Message format:
//   HEADER  (32-bit):  [31:24]=Magic(0xAB), [23:16]=msg_type, [15:0]=payload_len
//   PAYLOAD (N×32-bit): up to 124 words of data
//   CHECKSUM(32-bit):  XOR of header and all payload words
// =============================================================================

// Magic byte — validates that the header is well-formed
#define MSG_MAGIC           0xAB

// ---- Message types (PS → PL) ----
#define MSG_TYPE_PING       0x01    // Ping request (no payload)
#define MSG_TYPE_DATA       0x02    // Data message (with payload)

// ---- Message types (PL → PS) — bit 7 set = response ----
#define MSG_TYPE_PONG       0x81    // Ping response
#define MSG_TYPE_DATA_ECHO  0x82    // Data echo response

// Maximum payload size in 32-bit words
#define MAX_PAYLOAD_WORDS   124

// =============================================================================
// Shared Memory Layout — word offsets (index a uint32_t pointer)
//
// Total: 256 words = 1 KB
//   TX region  0x00–0x7F  (PS writes, PL reads)
//   RX region  0x80–0xFF  (PL writes, PS reads)
// =============================================================================

// TX Region (PS → PL)
#define TX_FLAG_WORD        0x00    // 1 = message ready, 0 = empty
#define TX_HEADER_WORD      0x01    // Header word
#define TX_CHECKSUM_WORD    0x02    // XOR checksum
// 0x03 reserved
#define TX_PAYLOAD_WORD     0x04    // First payload word (up to 0x7F)

// RX Region (PL → PS)
#define RX_FLAG_WORD        0x80    // 1 = message ready, 0 = empty
#define RX_HEADER_WORD      0x81    // Header word
#define RX_CHECKSUM_WORD    0x82    // XOR checksum
// 0x83 reserved
#define RX_PAYLOAD_WORD     0x84    // First payload word (up to 0xFF)

// =============================================================================
// Header helpers
// =============================================================================
#define HDR_GET_MAGIC(h)    (((h) >> 24) & 0xFF)
#define HDR_GET_TYPE(h)     (((h) >> 16) & 0xFF)
#define HDR_GET_LEN(h)      ((h) & 0xFFFF)
#define HDR_BUILD(type,len) (((uint32_t)MSG_MAGIC << 24) | \
                             ((uint32_t)(type) << 16)    | \
                             ((uint32_t)(len) & 0xFFFF))

#endif /* _MSG_PROTOCOL_H_ */
