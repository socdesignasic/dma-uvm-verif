# C 보드 시험 실행 (xsdb): 비트스트림을 올리고 PS를 초기화한 뒤 ELF를 CPU 0에 올려 실행합니다.
# 프로그램이 DDR mailbox에 쓴 결과를 JTAG로 읽어 파일로 저장합니다 (판정은 scripts/board_c.py).
#   xsdb ci/vivado/board_run_elf.tcl <bit> <ps7_init.tcl> <elf> <mbox_out> [timeout_s]
set bit     [lindex $argv 0]                                ;# 비트스트림
set ps7     [lindex $argv 1]                                ;# XSA에서 꺼낸 ps7_init.tcl
set elf     [lindex $argv 2]                                ;# C 프로그램
set out     [lindex $argv 3]                                ;# mailbox를 저장할 파일
set tmo     [expr {[llength $argv] > 4 ? [lindex $argv 4] : 60}]  ;# 완료 대기 제한 (초)
set mbox    0x0F000000                                      ;# mailbox 주소 (dma_board_test.c의 MBOX_ADDR)
set mbox_words 230                                          ;# mailbox 크기 (24 + 16*56 = 920바이트)

connect                                                     ;# hw_server 연결 (없으면 시작)
targets -set -nocase -filter {name =~ "APU*"}               ;# APU 선택
rst -system                                                 ;# PS와 PL 전체 리셋
after 1000                                                  ;# 리셋 안정화 대기
fpga -file $bit                                             ;# PL에 비트스트림 올리기
targets -set -nocase -filter {name =~ "APU*"}               ;# 다시 APU 선택
uplevel #0 [list source $ps7]                               ;# PS 초기화 스크립트 (변수가 전역이어야 함)
uplevel #0 ps7_init                                         ;# 클럭, DDR, MIO 초기화
uplevel #0 ps7_post_config                                  ;# PS-PL level shifter 켜기
targets -set -nocase -filter {name =~ "*A9*#0"}             ;# CPU 0 선택
catch {stop}                                                ;# CPU 정지 (이미 멈췄으면 무시)
mwr -force $mbox 0 $mbox_words                              ;# mailbox 비우기 (이전 실행 결과와 구분)
dow $elf                                                    ;# ELF 내려받기
puts "SETUP ok"                                             ;# 준비 완료
con                                                         ;# 실행

set t0 [clock seconds]                                      ;# 시작 시각
set done 0                                                  ;# 완료 여부
while {[clock seconds] - $t0 < $tmo} {                      ;# 제한 시간까지
    after 500                                               ;# 0.5초마다
    stop                                                    ;# 잠깐 멈추고 (실행 중엔 메모리 읽기가 막힘)
    set d [lindex [mrd -force -value [expr {$mbox + 16}]] 0]  ;# mailbox.done
    if {$d == 1} { set done 1; break }                      ;# 끝났으면 나감
    con                                                     ;# 아니면 다시 실행
}                                                           ;# while 끝
catch {stop}                                                ;# CPU 정지
mrd -force -bin -file $out $mbox $mbox_words                ;# mailbox 저장
puts "RUN done=$done secs=[expr {[clock seconds] - $t0}]"   ;# board_c.py가 파싱
