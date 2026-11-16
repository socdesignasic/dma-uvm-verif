// DMA 보드 시험 (bare-metal, Zynq-7000 Cortex-A9 #0, Xilinx standalone BSP)
//
// scripts/board.py(xsdb가 JTAG로 레지스터를 직접 씀)와 같은 7개 시험을 ARM에서 C로 실행합니다.
//  - D-cache를 켠 채로 둡니다. HP0 포트는 cache coherent가 아니므로 DMA 전에 원본/대상 범위를
//    flush하고, DMA가 끝난 뒤 대상 범위를 invalidate합니다 (SW/의 원본 예제는 cache를 통째로 끔).
//  - 입력을 기다리지 않습니다 (원본 예제는 scanf). 시험 목록이 코드에 고정돼 있습니다.
//  - 결과를 UART1(115200)로 출력하고, 같은 내용을 DDR의 mailbox(MBOX_ADDR)에 써서
//    호스트(scripts/board_c.py)가 JTAG로 읽어 판정할 수 있게 합니다.
//  - 판정 기준: 대상 바이트 = (원본 바이트 + add_val) & 0xFF (8비트 lane마다 더하고 올림은 버림).

#include <string.h>                                         // memcpy, memset, strncpy
#include "xil_types.h"                                      // u8, u32, u64
#include "xil_io.h"                                         // Xil_In32, Xil_Out32
#include "xil_cache.h"                                      // Xil_DCacheFlushRange, Xil_DCacheInvalidateRange
#include "xil_printf.h"                                     // xil_printf (UART1로 출력)
#include "xtime_l.h"                                        // XTime_GetTime, COUNTS_PER_SECOND (global timer)

// DMA 레지스터 (block design 주소 맵: 0x4000_0000 ~ 0x4000_0FFF)
#define DMA_BASE        0x40000000u                         // DMA AXI4-Lite 기준 주소
#define REG_AP_CTRL     0x00u                               // [0] start, [1] done, [2] idle
#define REG_RDMA_BYTE   0x10u                               // 읽기 바이트 수
#define REG_RDMA_PTR    0x14u                               // 읽기 시작 주소
#define REG_WDMA_BYTE   0x18u                               // 쓰기 바이트 수
#define REG_WDMA_PTR    0x1cu                               // 쓰기 시작 주소
#define REG_AXI00_PTR0  0x20u                               // 사용 안 함 (0으로 씀)
#define REG_ADD_VAL     0x24u                               // 바이트마다 더할 값
#define CTRL_START      0x1u                                // ap_start
#define CTRL_DONE       0x2u                                // ap_done
#define CTRL_IDLE       0x4u                                // ap_idle

#define DDR_TEST        0x10000000u                         // 시험 영역 시작 (mem_copy_test.c, board.py와 같음)
#define MBOX_ADDR       0x0F000000u                         // 결과 mailbox (호스트가 JTAG로 읽음)
#define MBOX_MAGIC      0xD0A7E570u                         // mailbox가 이 프로그램 것인지 표시
#define MBOX_VERSION    1u                                  // mailbox 형식 버전 (board_c.py와 맞춤)
#define MAX_CASES       16u                                 // mailbox에 들어가는 최대 시험 수
#define TIMEOUT_US      1000000u                            // IDLE/DONE 대기 제한 (1초)

enum { ST_PASS = 0, ST_MISMATCH = 1, ST_HANG = 2, ST_NOT_IDLE = 3 };  // 시험 판정 코드
enum { K_RAMP = 0, K_RAND = 1 };                            // 원본 데이터 종류

typedef struct {                                            // 시험 하나의 정의
    const char *name;                                       // 이름 (board.py와 같음)
    u32 src_off;                                            // 원본 오프셋 (DDR_TEST 기준)
    u32 dst_off;                                            // 대상 오프셋 (DDR_TEST 기준)
    u32 bytes;                                              // 전송 바이트 수
    u32 add;                                                // 더할 값
    u32 kind;                                               // 데이터 종류
} tcase_t;                                                  // 구조체 끝

static const tcase_t CASES[] = {                            // 시험 목록 (scripts/board.py의 CASES와 같음)
    {"one_beat",  0x000000, 0x100000,         8,   1, K_RAMP},  // 최소 전송 (1 beat)
    {"burst16",   0x000000, 0x100000,       128,   0, K_RAND},  // 정확히 burst 하나 (16 beat)
    {"burst17",   0x000000, 0x100000,       136, 255, K_RAND},  // burst 하나 + 1 beat, add 최대값
    {"page4k",    0x000000, 0x100000,      4096,   7, K_RAND},  // 정확히 4KB
    {"cross4k",   0x000F80, 0x101F40,       512,   3, K_RAND},  // 원본·대상 모두 4KB 경계를 넘음
    {"c_ref_64k", 0x000000, 0x010000,     65536,  42, K_RAMP},  // mem_copy_test.c 방식 (dst = src + len)
    {"big_1m",    0x000000, 0x200000, 1u << 20, 200, K_RAND},   // 1MB
};                                                          // 목록 끝
#define N_CASES (sizeof(CASES) / sizeof(CASES[0]))          // 시험 수

typedef struct {                                            // mailbox 안의 시험 결과 하나 (56바이트)
    char name[16];                                          // 시험 이름 (NUL로 끝남)
    u32 bytes;                                              // 전송 바이트 수
    u32 add;                                                // 더한 값
    u32 status;                                             // 판정 코드 (ST_*)
    u32 mismatch;                                           // 틀린 바이트 수
    u32 first_bad;                                          // 처음 틀린 오프셋 (없으면 0xFFFFFFFF)
    u32 exp_got;                                            // 처음 틀린 곳의 [15:8] 기대값, [7:0] 실제값
    u32 hw_ticks;                                           // DMA start ~ DONE (global timer tick)
    u32 sw_ticks;                                           // 같은 크기 CPU memcpy (global timer tick)
    u32 ctrl_after;                                         // DONE 뒤 AP_CTRL 값
    u32 idle_before;                                        // start 전 IDLE 비트 (1이면 정상)
} result_t;                                                 // 구조체 끝

typedef struct {                                            // mailbox 전체
    u32 magic;                                              // MBOX_MAGIC
    u32 version;                                            // MBOX_VERSION
    u32 n_cases;                                            // 실행한 시험 수
    u32 n_pass;                                             // PASS 수
    u32 done;                                               // 1이면 모든 시험 끝
    u32 counts_per_sec;                                     // global timer 주파수 (tick -> 시간 변환)
    result_t r[MAX_CASES];                                  // 시험별 결과
} mbox_t;                                                   // 구조체 끝

static volatile mbox_t *const MBOX = (volatile mbox_t *)MBOX_ADDR;  // mailbox 포인터

static u32 lcg;                                             // 랜덤 데이터용 LCG 상태
static u8 next_rand(void) {                                 // 다음 랜덤 바이트
    lcg = lcg * 1664525u + 1013904223u;                     // Numerical Recipes LCG
    return (u8)(lcg >> 24);                                 // 상위 8비트 사용 (하위 비트는 주기가 짧음)
}                                                           // 함수 끝

static inline void reg_wr(u32 off, u32 v) { Xil_Out32(DMA_BASE + off, v); }  // DMA 레지스터 쓰기
static inline u32 reg_rd(u32 off) { return Xil_In32(DMA_BASE + off); }      // DMA 레지스터 읽기

static u32 elapsed_us(XTime t0) {                           // t0 이후 지난 시간 (us)
    XTime t;                                                // 현재 시각
    XTime_GetTime(&t);                                      // global timer 읽기
    return (u32)((t - t0) / (COUNTS_PER_SECOND / 1000000u));  // tick -> us
}                                                           // 함수 끝

static u32 wait_bit(u32 mask) {                             // AP_CTRL의 mask 비트가 설 때까지 대기
    XTime t0;                                               // 시작 시각
    XTime_GetTime(&t0);                                     // 기록
    while (elapsed_us(t0) < TIMEOUT_US)                     // 제한 시간까지
        if (reg_rd(REG_AP_CTRL) & mask) return 1;           // 비트가 서면 성공
    return 0;                                               // 시간 초과
}                                                           // 함수 끝

static void run_case(const tcase_t *c, u32 idx, volatile result_t *r) {  // 시험 하나 실행
    u8 *src = (u8 *)(DDR_TEST + c->src_off);                // 원본 버퍼
    u8 *dst = (u8 *)(DDR_TEST + c->dst_off);                // 대상 버퍼
    XTime t0, t1;                                           // 시간 측정용

    lcg = 1000u + idx;                                      // 시험마다 seed 고정 (재현 가능)
    for (u32 i = 0; i < c->bytes; i++)                      // 원본 채우기
        src[i] = (c->kind == K_RAMP) ? (u8)i : next_rand(); // ramp(0,1,2,...) 또는 랜덤
    memset(dst, 0xA5, c->bytes);                            // 대상을 0xA5로 채움 (쓰이지 않은 곳 구분)
    Xil_DCacheFlushRange((INTPTR)src, c->bytes);            // 원본을 DDR로 내보냄 (DMA가 DDR에서 읽음)
    Xil_DCacheFlushRange((INTPTR)dst, c->bytes);            // 대상의 dirty line도 내보냄 (DMA 결과를 덮지 않게)

    reg_wr(REG_AXI00_PTR0, 0);                              // 사용 안 함
    reg_wr(REG_ADD_VAL, c->add);                            // 더할 값
    reg_wr(REG_RDMA_BYTE, c->bytes);                        // 읽기 바이트 수
    reg_wr(REG_RDMA_PTR, (u32)(UINTPTR)src);                // 읽기 주소
    reg_wr(REG_WDMA_BYTE, c->bytes);                        // 쓰기 바이트 수
    reg_wr(REG_WDMA_PTR, (u32)(UINTPTR)dst);                // 쓰기 주소

    strncpy((char *)r->name, c->name, sizeof(r->name) - 1); // 이름 기록
    r->bytes = c->bytes;                                    // 크기 기록
    r->add = c->add;                                        // 더할 값 기록
    r->first_bad = 0xFFFFFFFFu;                             // 아직 틀린 곳 없음
    r->idle_before = wait_bit(CTRL_IDLE);                   // start 전에 IDLE인지 확인
    if (!r->idle_before) { r->status = ST_NOT_IDLE; return; }  // IDLE이 아니면 시작하지 않음

    XTime_GetTime(&t0);                                     // DMA 시작 시각
    reg_wr(REG_AP_CTRL, CTRL_START);                        // ap_start
    u32 ok = wait_bit(CTRL_DONE);                           // DONE 대기
    XTime_GetTime(&t1);                                     // DMA 끝 시각 (폴링 지연 포함)
    r->hw_ticks = (u32)(t1 - t0);                           // DMA 시간
    r->ctrl_after = reg_rd(REG_AP_CTRL);                    // DONE 뒤 상태
    if (!ok) { r->status = ST_HANG; return; }               // DONE이 안 서면 HANG

    Xil_DCacheInvalidateRange((INTPTR)dst, c->bytes);       // 대상의 오래된 cache line 버림 (DDR 값을 읽게)
    u32 bad = 0;                                            // 틀린 바이트 수
    for (u32 i = 0; i < c->bytes; i++) {                    // 바이트마다 비교
        u8 exp = (u8)(src[i] + c->add);                     // 기대값
        if (dst[i] != exp) {                                // 다르면
            if (bad == 0) {                                 // 처음 틀린 곳이면
                r->first_bad = i;                           // 오프셋 기록
                r->exp_got = ((u32)exp << 8) | dst[i];      // 기대값과 실제값 기록
            }                                               // if 끝
            bad++;                                          // 개수 증가
        }                                                   // if 끝
    }                                                       // for 끝
    r->mismatch = bad;                                      // 틀린 수 기록
    r->status = bad ? ST_MISMATCH : ST_PASS;                // 판정

    XTime_GetTime(&t0);                                     // CPU 비교 기준: 같은 크기 memcpy
    memcpy(dst, src, c->bytes);                             // D-cache 켠 상태의 CPU 복사 (더하기 없음)
    XTime_GetTime(&t1);                                     // 끝 시각
    r->sw_ticks = (u32)(t1 - t0);                           // CPU 복사 시간
}                                                           // 함수 끝

static const char *st_name(u32 s) {                         // 판정 코드 -> 문자열
    switch (s) {                                            // 코드마다
    case ST_PASS:     return "PASS";                        // 통과
    case ST_MISMATCH: return "MISMATCH";                    // 데이터 틀림
    case ST_HANG:     return "HANG";                        // DONE 안 섬
    default:          return "NOT_IDLE";                    // 시작 전 IDLE 아님
    }                                                       // switch 끝
}                                                           // 함수 끝

int main(void) {                                            // 진입점
    u32 tick_per_us = COUNTS_PER_SECOND / 1000000u;         // global timer tick / us
    memset((void *)MBOX, 0, sizeof(mbox_t));                // mailbox 비우기
    MBOX->magic = MBOX_MAGIC;                               // 표시
    MBOX->version = MBOX_VERSION;                           // 형식 버전
    MBOX->counts_per_sec = COUNTS_PER_SECOND;               // 시간 변환용
    MBOX->n_cases = N_CASES;                                // 시험 수
    Xil_DCacheFlushRange(MBOX_ADDR, sizeof(mbox_t));        // 호스트가 볼 수 있게 DDR로 내보냄

    xil_printf("\r\nDMA_BOARD_TEST start cases=%d timer=%dHz\r\n", N_CASES, COUNTS_PER_SECOND);  // 시작 표시
    for (u32 i = 0; i < N_CASES; i++) {                     // 시험마다
        volatile result_t *r = &MBOX->r[i];                 // 이 시험의 결과 칸
        run_case(&CASES[i], i, r);                          // 실행
        if (r->status == ST_PASS) MBOX->n_pass++;           // PASS 수 증가
        xil_printf("CASE %s bytes=%d add=%d status=%s mismatch=%d hw_us=%d sw_us=%d ctrl=0x%08x\r\n",  // 결과 한 줄
                   CASES[i].name, r->bytes, r->add, st_name(r->status), r->mismatch,  // 이름, 크기, 값, 판정, 틀린 수
                   r->hw_ticks / tick_per_us, r->sw_ticks / tick_per_us, r->ctrl_after);  // 시간, 레지스터
        if (r->mismatch)                                    // 틀렸으면
            xil_printf("  first_bad off=%d exp=0x%02x got=0x%02x\r\n",  // 첫 위치
                       r->first_bad, (r->exp_got >> 8) & 0xFF, r->exp_got & 0xFF);  // 기대값, 실제값
        Xil_DCacheFlushRange(MBOX_ADDR, sizeof(mbox_t));    // 중간 결과도 DDR에 반영
    }                                                       // for 끝
    MBOX->done = 1;                                         // 끝 표시
    Xil_DCacheFlushRange(MBOX_ADDR, sizeof(mbox_t));        // DDR에 반영
    xil_printf("ALL_DONE pass=%d/%d\r\n", MBOX->n_pass, N_CASES);  // 요약 (board_c.py가 이 줄을 기다림)
    while (1) {}                                            // 호스트가 CPU를 멈출 때까지 대기
    return 0;                                               // 도달하지 않음
}                                                           // 함수 끝
