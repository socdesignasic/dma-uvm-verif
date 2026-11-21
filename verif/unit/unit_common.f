// unit TB들이 함께 쓰는 UVM 기반 코드 (vr agent, unit env, unit 테스트)
// 각 *_pkg.sv가 자기 디렉터리의 클래스 파일(파일 하나에 클래스 하나)을 `include함.
+incdir+../vip/stream
+incdir+coverage
+incdir+env
+incdir+scoreboard
+incdir+test
+incdir+.
../vip/stream/stream_if.sv
../vip/stream/stream_pkg.sv
env/unit_env_pkg.sv
test/unit_test_pkg.sv
