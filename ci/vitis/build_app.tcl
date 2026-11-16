# C 보드 시험 프로그램 빌드 (xsct, Vitis 2022.2)
# XSA로 standalone 플랫폼(BSP)을 만들고, fw/dma_board_test/의 C 소스를 넣어 ELF를 만듭니다.
#   xsct ci/vitis/build_app.tcl <xsa> <src_dir> <workspace>
# 결과: <workspace>/dma_board_test/Release/dma_board_test.elf
set xsa  [lindex $argv 0]                                   ;# 첫 인자: XSA (Vivado 출력)
set src  [lindex $argv 1]                                   ;# 둘째 인자: C 소스 디렉터리
set ws   [lindex $argv 2]                                   ;# 셋째 인자: Vitis workspace (매번 새로 만듦)
set app  dma_board_test                                     ;# 앱 이름

file delete -force $ws                                      ;# 이전 workspace 삭제 (XSA가 바뀌었을 수 있음)
file mkdir $ws                                              ;# 새로 생성
setws $ws                                                   ;# workspace 지정
app create -name $app -hw $xsa -proc ps7_cortexa9_0 -os standalone -lang C -template {Empty Application(C)}  ;# 플랫폼 + BSP + 빈 앱
importsources -name $app -path $src                         ;# C 소스 넣기
app config -name $app build-config release                  ;# -O2 빌드
app build -name $app                                        ;# BSP와 앱 빌드
set elf [file join $ws $app Release $app.elf]               ;# 결과 ELF 경로
if {![file exists $elf]} { puts "BUILD_FAIL no elf"; exit 1 }  ;# ELF가 없으면 실패
puts "ELF $elf"                                             ;# board_c.py가 파싱
