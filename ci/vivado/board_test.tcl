# 보드 시험 (xsdb): 비트스트림을 올리고 PS를 초기화한 뒤, DMA 레지스터를 JTAG로 직접 써서 mem copy를 실행.
# SW/의 mem_copy_test.c와 같은 순서 (레지스터 설정 -> IDLE 확인 -> start -> DONE 대기)를 C 컴파일 없이 수행.
# 데이터 준비와 비교는 scripts/board.py가 함 (이 스크립트는 메모리 쓰기/읽기와 DMA 제어만).
#   xsdb ci/vivado/board_test.tcl <bit> <ps7_init.tcl> <case_file> <work_dir>
# case_file 한 줄: <name> <src_hex> <dst_hex> <bytes> <add_val>
set bit     [lindex $argv 0]                                ;# 첫 인자: 비트스트림
set ps7     [lindex $argv 1]                                ;# 둘째 인자: XSA에서 꺼낸 ps7_init.tcl
set cases   [lindex $argv 2]                                ;# 셋째 인자: 시험 목록 파일
set work    [lindex $argv 3]                                ;# 넷째 인자: src/dst 바이너리 디렉터리
set base    0x40000000                                      ;# DMA 레지스터 기준 주소 (block design 주소 맵)
set timeout_ms 3000                                         ;# DONE 대기 시간 제한 (넘으면 HANG)

proc reg_wr {off val} {                                     ;# DMA 레지스터 쓰기
    global base                                             ;# 기준 주소
    mwr -force [expr {$base + $off}] $val                   ;# JTAG로 32비트 쓰기
}                                                           ;# proc 끝
proc reg_rd {off} {                                         ;# DMA 레지스터 읽기
    global base                                             ;# 기준 주소
    return [lindex [mrd -force -value [expr {$base + $off}]] 0]  ;# JTAG로 32비트 읽기
}                                                           ;# proc 끝

proc setup {} {                                             ;# 보드를 처음 상태로 만드는 함수
    global bit ps7                                          ;# 비트스트림, ps7_init 경로
    targets -set -nocase -filter {name =~ "APU*"}           ;# APU 선택
    rst -system                                             ;# PS와 PL 전체 리셋
    after 1000                                              ;# 리셋 안정화 대기
    fpga -file $bit                                         ;# PL에 비트스트림 올리기
    targets -set -nocase -filter {name =~ "APU*"}           ;# 다시 APU 선택
    uplevel #0 [list source $ps7]                           ;# PS 초기화 스크립트 읽기 (변수가 전역이어야 함)
    uplevel #0 ps7_init                                     ;# 클럭, DDR, MIO 초기화
    uplevel #0 ps7_post_config                              ;# PS-PL level shifter 켜기
    targets -set -nocase -filter {name =~ "*A9*#0"}         ;# CPU 0 선택 (메모리 접근 경로)
    catch {stop}                                            ;# CPU 정지 (이미 멈췄으면 무시)
    puts "SETUP ok"                                         ;# 준비 완료 표시
}                                                           ;# proc 끝

connect                                                     ;# hw_server 연결 (없으면 시작)
set names {}                                                ;# JTAG 장치 이름 목록 (xsdb는 Tcl 8.5라 lmap 없음)
catch {foreach t [jtag targets -target-properties] { lappend names [dict get $t name] }}  ;# 이름 모으기 (실패해도 계속)
puts "JTAG [join $names {, }]"                              ;# JTAG 체인 출력
setup                                                       ;# 첫 준비

set fh [open $cases r]                                      ;# 시험 목록 열기
set lines [split [read $fh] "\n"]                           ;# 줄 목록
close $fh                                                   ;# 파일 닫기
foreach ln $lines {                                         ;# 시험마다
    if {[string trim $ln] eq ""} continue                   ;# 빈 줄은 건너뜀
    lassign $ln name src dst bytes add                      ;# 이름, 원본, 대상, 바이트 수, 더할 값
    set words [expr {$bytes / 4}]                           ;# 32비트 단어 수
    mwr -force -bin -file [file join $work $name.src] $src $words  ;# 원본 데이터 쓰기
    mwr -force -bin -file [file join $work $name.clr] $dst $words  ;# 대상 영역을 0xA5로 채움 (이전 값과 구분)
    reg_wr 0x20 0                                           ;# AXI00_PTR0 (사용 안 함)
    reg_wr 0x24 $add                                        ;# 더할 값
    reg_wr 0x10 $bytes                                      ;# RDMA 바이트 수
    reg_wr 0x14 $src                                        ;# RDMA 주소
    reg_wr 0x18 $bytes                                      ;# WDMA 바이트 수
    reg_wr 0x1c $dst                                        ;# WDMA 주소
    set idle [expr {([reg_rd 0x00] & 0x4) != 0}]            ;# 시작 전 IDLE 비트
    set t0 [clock milliseconds]                             ;# 시작 시각
    reg_wr 0x00 1                                           ;# ap_start
    set st HANG                                             ;# 기본 판정: 멈춤
    while {[clock milliseconds] - $t0 < $timeout_ms} {      ;# 시간 제한까지
        if {([reg_rd 0x00] & 0x2) != 0} { set st DONE; break }  ;# DONE 비트가 서면 끝
    }                                                       ;# while 끝
    set ms [expr {[clock milliseconds] - $t0}]              ;# 걸린 시간 (JTAG 폴링 포함, 대략값)
    set ctrl [format 0x%08x [reg_rd 0x00]]                  ;# 끝난 뒤 AP_CTRL 값
    mrd -force -bin -file [file join $work $name.dst] $dst $words  ;# 대상 데이터 읽기
    puts "CASE $name idle=$idle status=$st ctrl=$ctrl ms=$ms"  ;# 결과 한 줄 (board.py가 파싱)
    if {$st eq "HANG"} { setup }                            ;# 멈췄으면 다음 시험 전에 다시 초기화
}                                                           ;# foreach 끝
puts "ALL_DONE"                                             ;# 전체 완료 표시
