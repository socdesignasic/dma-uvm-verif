// UVM infrastructure shared by unit TBs (vr agent, unit env, unit tests)
// Each *_pkg.sv `includes its class files (one class per file) from its own directory.
+incdir+../agents/vr_agent
+incdir+../env/unit
+incdir+../tests/unit
+incdir+../tb/unit
../agents/vr_agent/vr_if.sv
../agents/vr_agent/vr_pkg.sv
../env/unit/unit_env_pkg.sv
../tests/unit/unit_test_pkg.sv
