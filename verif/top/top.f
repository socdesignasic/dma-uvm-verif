// dma_ip_top UVM 환경
// 각 *_pkg.sv가 자기 디렉터리의 클래스 파일(파일 하나에 클래스 하나)을 `include함.
-f ../rtl.f
+incdir+../vip/axil
+incdir+../vip/axi4_slave
+incdir+coverage
+incdir+env
+incdir+model
+incdir+scoreboard
+incdir+seq
+incdir+test
../vip/axil/axil_if.sv
../vip/axil/axil_pkg.sv
../vip/axi4_slave/axi4_if.sv
../vip/axi4_slave/axi4_slave_pkg.sv
dma_reset_if.sv
env/dma_env_pkg.sv
seq/dma_seq_pkg.sv
test/dma_test_pkg.sv
dma_ap_ctrl_sva.sv
tb_dma.sv
