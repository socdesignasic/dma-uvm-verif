// unit TB들이 함께 쓰는 UVM 기반 코드 (vr agent, unit env, unit 테스트)
// 각 *_pkg.sv가 자기 디렉터리의 클래스 파일(파일 하나에 클래스 하나)을 `include함.
+incdir+../agents/vr_agent
+incdir+../env/unit
+incdir+../tests/unit
+incdir+../tb/unit
../agents/vr_agent/vr_if.sv
../agents/vr_agent/vr_pkg.sv
../env/unit/unit_env_pkg.sv
../tests/unit/unit_test_pkg.sv
