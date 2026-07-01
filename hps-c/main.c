#include <stdio.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <stdint.h>
#include <string.h>
#include "hwlib.h"
#include "socal/socal.h"
#include "socal/hps.h"
#include "socal/alt_gpio.h"
#include "hps_0.h"
#include "msg_protocol.h"

// =============================================================================
// Hardware address mapping
// =============================================================================
#define HW_REGS_BASE ( ALT_STM_OFST )
#define HW_REGS_SPAN ( 0x04000000 )
#define HW_REGS_MASK ( HW_REGS_SPAN - 1 )

// Base address of msg_shared_mem in Lightweight bridge (set in Platform Designer)
// Change this if you assign a different base address in Qsys.
#define MSG_MEM_BASE  0x00040000

// Pointer to shared memory (mapped via /dev/mem)
static volatile uint32_t *msg_mem;

// =============================================================================
// calc_checksum — XOR of header and all payload words
// =============================================================================
static uint32_t calc_checksum(uint32_t header,
                              const uint32_t *payload,
                              uint16_t len)
{
    uint32_t crc = header;
    for (uint16_t i = 0; i < len; i++)
        crc ^= payload[i];
    return crc;
}

// =============================================================================
// send_message — write a message into the TX region of shared memory
// =============================================================================
static int send_message(uint8_t msg_type,
                        const uint32_t *payload,
                        uint16_t payload_len)
{
    // Wait until FPGA has consumed the previous message (TX_FLAG == 0)
    int timeout = 100000;
    while (msg_mem[TX_FLAG_WORD] != 0 && --timeout > 0)
        usleep(10);

    if (timeout <= 0) {
        printf("  ERROR: TX timeout — FPGA did not consume previous message\n");
        return -1;
    }

    // Build and write header
    uint32_t header = HDR_BUILD(msg_type, payload_len);
    msg_mem[TX_HEADER_WORD] = header;

    // Write payload (if any)
    for (uint16_t i = 0; i < payload_len; i++)
        msg_mem[TX_PAYLOAD_WORD + i] = payload[i];

    // Write checksum
    uint32_t checksum = calc_checksum(header, payload, payload_len);
    msg_mem[TX_CHECKSUM_WORD] = checksum;

    // Set TX_FLAG **last** — acts as a memory-publish barrier for the FPGA
    msg_mem[TX_FLAG_WORD] = 1;

    printf("  TX: type=0x%02X  len=%u  crc=0x%08X\n",
           msg_type, payload_len, checksum);
    
    // Print payload data if any
    if (payload_len > 0) {
        printf("      Payload Hex : ");
        for (uint16_t i = 0; i < payload_len; i++) {
            printf("%08X ", payload[i]);
        }
        printf("\n");
        printf("      Payload Text: %s\n", (char *)payload);
    }

    return 0;
}

// =============================================================================
// recv_message — poll RX_FLAG, then read the response from RX region
// =============================================================================
static int recv_message(uint8_t *msg_type,
                        uint32_t *payload,
                        uint16_t *payload_len)
{
    // Wait for FPGA to post a response (RX_FLAG == 1)
    int timeout = 100000;
    while (msg_mem[RX_FLAG_WORD] != 1 && --timeout > 0)
        usleep(10);

    if (timeout <= 0) {
        printf("  ERROR: RX timeout — no response from FPGA\n");
        return -1;
    }

    // Read header
    uint32_t header = msg_mem[RX_HEADER_WORD];
    uint8_t  magic  = HDR_GET_MAGIC(header);
    *msg_type       = HDR_GET_TYPE(header);
    *payload_len    = HDR_GET_LEN(header);

    if (magic != MSG_MAGIC) {
        printf("  ERROR: Bad magic 0x%02X (expected 0x%02X)\n",
               magic, MSG_MAGIC);
        msg_mem[RX_FLAG_WORD] = 0;
        return -2;
    }

    // Read payload
    for (uint16_t i = 0; i < *payload_len; i++)
        payload[i] = msg_mem[RX_PAYLOAD_WORD + i];

    // Read & verify checksum
    uint32_t stored_crc = msg_mem[RX_CHECKSUM_WORD];
    uint32_t calc_crc   = calc_checksum(header, payload, *payload_len);

    if (stored_crc != calc_crc) {
        printf("  ERROR: Checksum mismatch  stored=0x%08X  calc=0x%08X\n",
               stored_crc, calc_crc);
        msg_mem[RX_FLAG_WORD] = 0;
        return -3;
    }

    // Acknowledge — clear RX_FLAG so FPGA can reuse the buffer
    msg_mem[RX_FLAG_WORD] = 0;

    printf("  RX: type=0x%02X  len=%u  crc=0x%08X  [OK]\n",
           *msg_type, *payload_len, stored_crc);
    
    // Print payload data if any
    if (*payload_len > 0) {
        printf("      Payload Hex : ");
        for (uint16_t i = 0; i < *payload_len; i++) {
            printf("%08X ", payload[i]);
        }
        printf("\n");
        printf("      Payload Text: %s\n", (char *)payload);
    }

    return 0;
}

// =============================================================================
// main
// =============================================================================
int main(int argc, char *argv[])
{
    void *virtual_base;
    int fd;

    printf("\n");
    printf("========================================\n");
    printf("  PS-PL Message Communication Demo\n");
    printf("  Board: DE1-SoC (5CSEMA5F31C6)\n");
    printf("  Method: Shared Memory via LW bridge\n");
    printf("========================================\n\n");

    // ---- Open /dev/mem ----
    if ((fd = open("/dev/mem", O_RDWR | O_SYNC)) == -1) {
        printf("ERROR: could not open \"/dev/mem\"\n");
        return 1;
    }

    // ---- mmap the HPS register space ----
    virtual_base = mmap(NULL, HW_REGS_SPAN,
                        PROT_READ | PROT_WRITE,
                        MAP_SHARED, fd, HW_REGS_BASE);
    if (virtual_base == MAP_FAILED) {
        printf("ERROR: mmap() failed\n");
        close(fd);
        return 1;
    }

    // ---- Get pointer to shared memory ----
    msg_mem = (volatile uint32_t *)
        (virtual_base +
         ((unsigned long)(ALT_LWFPGASLVS_OFST + MSG_MEM_BASE)
          & (unsigned long)HW_REGS_MASK));

    printf("Shared memory mapped OK  (msg_mem = %p)\n\n", (void *)msg_mem);

    // ---- Clear both flags so we start from a known state ----
    msg_mem[TX_FLAG_WORD] = 0;
    msg_mem[RX_FLAG_WORD] = 0;
    usleep(100000);   // 100 ms — let FPGA sync

    // ==================================================================
    // Interactive Command Line Mode
    // ==================================================================
    if (argc < 2) {
        printf("Sử dụng: %s \"Nội dung tin nhắn\"\n", argv[0]);
        printf("Ví dụ  : %s \"hello fpga\"\n\n", argv[0]);
        
        printf("--- Đang gửi PING mặc định để kiểm tra kết nối ---\n");
        if (send_message(MSG_TYPE_PING, NULL, 0) == 0) {
            uint8_t  rx_type;
            uint32_t rx_payload[MAX_PAYLOAD_WORDS];
            uint16_t rx_len;

            if (recv_message(&rx_type, rx_payload, &rx_len) == 0) {
                printf("  >> %s\n\n", (rx_type == MSG_TYPE_PONG) ? "Kết nối FPGA: TỐT (PING/PONG OK)!" : "Kết nối FPGA: LỖI");
            }
        }
    } else {
        printf("--- Gửi tin nhắn TEXT tới FPGA ---\n");
        
        // Tính toán độ dài tin nhắn (tính theo word 32-bit)
        size_t text_len = strlen(argv[1]) + 1; // +1 cho ký tự null kết thúc chuỗi
        uint16_t words_len = (text_len + 3) / 4; // Chia 4, làm tròn lên

        // Chuẩn bị buffer (tối đa MAX_PAYLOAD_WORDS)
        if (words_len > MAX_PAYLOAD_WORDS) {
            printf("Lỗi: Tin nhắn quá dài! (Tối đa %d ký tự)\n", MAX_PAYLOAD_WORDS * 4 - 1);
        } else {
            // Cấp phát một mảng uint32_t chứa chuỗi (những byte thừa sẽ tự động là 0)
            uint32_t tx_buf[MAX_PAYLOAD_WORDS] = {0};
            strncpy((char *)tx_buf, argv[1], MAX_PAYLOAD_WORDS * 4 - 1);

            // Gửi bản tin DATA
            if (send_message(MSG_TYPE_DATA, tx_buf, words_len) == 0) {
                uint8_t  rx_type;
                uint32_t rx_payload[MAX_PAYLOAD_WORDS];
                uint16_t rx_len;

                // Đợi nhận phản hồi
                if (recv_message(&rx_type, rx_payload, &rx_len) == 0) {
                    if (rx_type == MSG_TYPE_DATA_ECHO) {
                        printf("\n  >> Kết quả trả về từ FPGA: \"%s\"\n\n", (char *)rx_payload);
                    } else {
                        printf("\n  >> LỖI: Nhận sai loại bản tin (type=0x%02X)\n\n", rx_type);
                    }
                }
            }
        }
    }

    // ==================================================================
    printf("========================================\n");
    printf("  Demo complete\n");
    printf("========================================\n\n");

    // ---- Cleanup ----
    if (munmap(virtual_base, HW_REGS_SPAN) != 0) {
        printf("ERROR: munmap() failed\n");
        close(fd);
        return 1;
    }
    close(fd);
    return 0;
}
