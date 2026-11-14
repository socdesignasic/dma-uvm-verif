// dma_ip_top UVM environment
// Each *_pkg.sv `includes its class files (one class per file) from its own directory.
-f rtl.f
+incdir+../agents/axil_agent
+incdir+../agents/axi4_slv_agent
+incdir+../env/top
+incdir+../sequences/top
+incdir+../tests/top
../agents/axil_agent/axil_if.sv
../agents/axil_agent/axil_pkg.sv
../agents/axi4_slv_agent/axi4_if.sv
../agents/axi4_slv_agent/axi4_slv_pkg.sv
../env/top/dma_env_pkg.sv
../sequences/top/dma_seq_pkg.sv
../tests/top/dma_test_pkg.sv
../tb/top/tb_top.sv
