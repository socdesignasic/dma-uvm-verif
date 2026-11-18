// -----------------------------------------------------------------------------
// dma-uvm CI : Vivado 2022.2 XSim에서 dma_ip UVM 회귀
//
//   main에 push (SCM poll) : smoke = ML 회귀 계획(verif/regress_plan.json, 47회)대로 unit + top 회귀,
//                            계획의 목표 bin을 모두 채웠는지 확인 (못 채우면 UNSTABLE)
//                            + FPGA 단독(out-of-context) 합성/배치배선 타이밍 확인 (100 MHz)
//   매일 타이머 (02:00)    : full  = 모든 TB의 모든 테스트, seed 5개, 커버리지 보고서
//                            + FPGA 시스템 빌드: 비트스트림 + XSA (CD 결과물)
//   모든 빌드 끝에 Sign-off 단계가 verif/SIGNOFF.md 기준을 판정 (smoke / nightly 수준, 못 채우면 UNSTABLE)
//   수동 "Build with Parameters"로 둘 중 하나를 강제하거나, seed 수를 바꾸거나, 비트스트림을 요청할 수 있음.
//
// Agent: label 'vivado' (이 PC). PYTHON / XILINX_VIVADO / REGRESS_JOBS는 노드 환경
// (ci/jenkins.yaml)에서 옴. 모든 단계는 개발자가 손으로 돌리는 것과 같은 스크립트를
// 부르므로, CI 실패는 출력된 `rerun` 명령으로 로컬에서 재현됨.
// -----------------------------------------------------------------------------
def TOP_SMOKE = 'dma_reg_reset_test dma_reg_bitbash_test dma_smoke_test dma_small_test dma_irq_test dma_aw_backpressure_test'  // 계획 없이 smoke를 돌릴 때(SEEDS 지정)의 top 테스트
def PLAN      = 'verif/regress_plan.json'                // smoke 회귀 계획 (scripts/ml_regress.py analyze --save-plan)
def COV_TBS   = ['top', 'adder8', 'adder', 'fifo', 'fifo_d4', 'skid']  // 커버리지 보고서를 만들 TB

pipeline {                                                  // declarative pipeline 시작
  agent { label 'vivado' }                                  // vivado label이 붙은 노드에서 실행

  options {                                                 // 빌드 옵션
    timestamps()                                            // 콘솔 로그에 시각 표시
    timeout(time: 4, unit: 'HOURS')                         // 빌드 전체 시간 제한 4시간
    buildDiscarder(logRotator(numToKeepStr: '30', artifactNumToKeepStr: '10'))  // 빌드 30개, 결과물 10개만 보관
    disableConcurrentBuilds()                               // 동시에 한 빌드만
  }                                                         // options 끝

  parameters {                                              // 빌드 파라미터
    choice(name: 'MODE', choices: ['auto', 'smoke', 'full'],  // 실행 모드 선택
           description: 'auto: 코드가 바뀌면 smoke, 매일 타이머면 full')  // 설명
    string(name: 'SEEDS', defaultValue: '', description: '테스트당 seed 수 (비우면 smoke=ML 계획, full=5)')  // seed 수
    booleanParam(name: 'BITSTREAM', defaultValue: false, description: '비트스트림 + XSA도 빌드 (full 모드에서는 항상 켜짐)')  // 비트스트림 빌드 여부
  }                                                         // parameters 끝

  stages {                                                  // stage 목록
    stage('Plan') {                                         // 실행 계획 정하기
      steps {                                               // steps 시작
        script {                                            // Groovy 코드 블록
          def nightly = !currentBuild.getBuildCauses('hudson.triggers.TimerTrigger$TimerTriggerCause').isEmpty()  // 타이머로 시작한 빌드인지
          env.RUN_MODE = (params.MODE == 'auto') ? (nightly ? 'full' : 'smoke') : params.MODE  // auto면 타이머는 full, 그 밖은 smoke
          env.N_SEEDS  = params.SEEDS?.trim() ? params.SEEDS.trim() : (env.RUN_MODE == 'full' ? '5' : '1')  // seed 수 (지정 없으면 full 5, smoke 1)
          env.JOBS     = env.REGRESS_JOBS ?: '4'            // 병렬 실행 수 (노드 환경, 기본 4)
          env.DO_BITSTREAM = (env.RUN_MODE == 'full' || params.BITSTREAM) ? 'true' : 'false'  // full이거나 요청했으면 비트스트림 빌드
          env.USE_PLAN = (env.RUN_MODE == 'smoke' && !params.SEEDS?.trim() && fileExists(PLAN)) ? 'true' : 'false'  // smoke이고 seed 지정이 없으면 계획 사용
          env.PLAN_ARG = (env.USE_PLAN == 'true') ? "--plan ${PLAN}" : ''  // regress.py에 넘길 계획 인자
          def what = (env.USE_PLAN == 'true') ? 'ML plan' : "${env.N_SEEDS} seed(s)"  // 빌드 설명용
          currentBuild.description = "${env.RUN_MODE}, ${what}" + (env.DO_BITSTREAM == 'true' ? ', bitstream' : '')  // 빌드 설명에 모드와 회귀 방식 표시
        }                                                   // script 끝
        bat 'if exist out rmdir /s /q out'                  // 이전 결과 삭제
        bat '"%PYTHON%" --version && "%PYTHON%" scripts/sim.py list'  // Python 버전과 TB 목록 출력
      }                                                     // steps 끝
    }                                                       // stage 끝

    stage('Lint') {                                         // 컴파일 확인
      steps {                                               // steps 시작
        bat '"%PYTHON%" scripts/sim.py lint --tb rtl'       // RTL만 컴파일
        bat '"%PYTHON%" scripts/sim.py lint --tb top'       // top TB 컴파일
      }                                                     // steps 끝
    }                                                       // stage 끝

    stage('Unit regression') {                              // unit 회귀
      steps {                                               // steps 시작
        // 회귀가 실패하면 stage/빌드에 표시하지만 이후 stage는 계속 실행
        catchError(buildResult: 'FAILURE', stageResult: 'FAILURE') {  // 실패해도 다음 stage 계속
          bat '"%PYTHON%" scripts/regress.py --suite unit --seeds %N_SEEDS% --jobs %JOBS% --name unit %PLAN_ARG%'  // unit 회귀 실행 (smoke면 계획대로)
        }                                                   // catchError 끝
      }                                                     // steps 끝
    }                                                       // stage 끝

    stage('Top regression') {                               // top 회귀
      steps {                                               // steps 시작
        script {                                            // Groovy 코드 블록
          def subset = (env.RUN_MODE == 'smoke' && env.USE_PLAN != 'true') ? "--tests ${TOP_SMOKE}" : ''  // 계획 없는 smoke면 정해진 테스트만
          catchError(buildResult: 'FAILURE', stageResult: 'FAILURE') {  // 실패해도 다음 stage 계속
            bat "\"%PYTHON%\" scripts/regress.py --suite top --seeds %N_SEEDS% --jobs %JOBS% --name top ${subset} %PLAN_ARG%"  // top 회귀 실행 (smoke면 계획대로)
          }                                                 // catchError 끝
        }                                                   // script 끝
      }                                                     // steps 끝
    }                                                       // stage 끝

    stage('Plan coverage') {                                // 계획대로 돈 smoke가 목표 bin을 모두 채웠는지
      when { environment name: 'USE_PLAN', value: 'true' }  // 계획을 쓴 빌드만
      steps {                                               // steps 시작
        catchError(buildResult: 'UNSTABLE', stageResult: 'UNSTABLE') {  // 못 채우면 UNSTABLE (검증 확률 99.1%라 드물게 생김)
          bat '"%PYTHON%" scripts/ml_regress.py check --plan verif/regress_plan.json --jobs %JOBS% --summary out/regress/unit/summary.json out/regress/top/summary.json'  // 목표 bin 확인
        }                                                   // catchError 끝
      }                                                     // steps 끝
    }                                                       // stage 끝

    stage('FPGA timing (OOC)') {                            // FPGA 단독 타이밍 확인
      steps {                                               // steps 시작
        catchError(buildResult: 'FAILURE', stageResult: 'FAILURE') {  // 실패해도 다음 stage 계속
          bat '"%PYTHON%" scripts/fpga.py ooc'              // ooc 합성/배치/배선
        }                                                   // catchError 끝
      }                                                     // steps 끝
    }                                                       // stage 끝

    stage('FPGA bitstream') {                               // 비트스트림 빌드
      when { environment name: 'DO_BITSTREAM', value: 'true' }  // DO_BITSTREAM이 true일 때만
      steps {                                               // steps 시작
        catchError(buildResult: 'FAILURE', stageResult: 'FAILURE') {  // 실패해도 다음 stage 계속
          bat '"%PYTHON%" scripts/fpga.py system --jobs %JOBS%'  // 시스템 빌드 (비트스트림 + XSA)
        }                                                   // catchError 끝
      }                                                     // steps 끝
    }                                                       // stage 끝

    stage('Coverage') {                                     // 커버리지 보고서 (smoke, full 모두. out/은 빌드마다 비우므로 이번 빌드 실행만 합침)
      steps {                                               // steps 시작
        script {                                            // Groovy 코드 블록
          COV_TBS.each { tb ->                              // TB마다
            catchError(buildResult: 'UNSTABLE', stageResult: 'UNSTABLE') {  // 실패하면 UNSTABLE로 표시
              bat "\"%PYTHON%\" scripts/sim.py cov-report --tb ${tb}"  // 커버리지 보고서 생성
            }                                               // catchError 끝
          }                                                 // each 끝
        }                                                   // script 끝
      }                                                     // steps 끝
    }                                                       // stage 끝

    stage('Sign-off') {                                     // verif/SIGNOFF.md 기준 판정 (smoke는 smoke, full은 nightly 수준)
      steps {                                               // steps 시작
        catchError(buildResult: 'UNSTABLE', stageResult: 'UNSTABLE') {  // 기준을 못 채우면 UNSTABLE
          bat "\"%PYTHON%\" scripts/signoff.py --level ${env.RUN_MODE == 'full' ? 'nightly' : 'smoke'}"  // 판정, out/signoff/signoff.md
        }                                                   // catchError 끝
      }                                                     // steps 끝
    }                                                       // stage 끝
  }                                                         // stages 끝

  post {                                                    // 빌드가 끝난 뒤
    always {                                                // 결과와 상관없이 항상
      junit testResults: 'out/regress/*/junit.xml', allowEmptyResults: true  // JUnit 결과 수집 (Test Result 화면)
      archiveArtifacts allowEmptyArchive: true, fingerprint: false,  // 결과물 보관 (fingerprint 없음)
        artifacts: 'out/signoff/*, out/ml/check.json, out/regress/**/*.json, out/regress/**/*.xml, out/*/runs/**/run.log, out/*/runs/**/result.json, out/*/build/*.log, out/fpga/*/result.json, out/fpga/*/*.rpt, out/fpga/*/vivado.log'  // 회귀 요약, 실행 로그, 빌드 로그, FPGA 보고서
      // CD 결과물: fingerprint를 남겨 보드 이미지가 어느 빌드와 커밋에서 나왔는지 추적 가능
      archiveArtifacts allowEmptyArchive: true, fingerprint: true,  // 비트스트림과 XSA 보관 (fingerprint 남김)
        artifacts: 'out/fpga/system/design_1_wrapper.bit, out/fpga/system/design_1_wrapper.xsa'  // 보관할 파일
      script {                                              // Groovy 코드 블록
        COV_TBS.each { tb ->                                // TB마다
          publishHTML(target: [reportName: "Coverage ${tb}", reportDir: "out/${tb}/cov/func",  // 커버리지 HTML 보고서 게시
                               reportFiles: 'dashboard.html', allowMissing: true,  // 보고서 파일, 없어도 허용
                               alwaysLinkToLastBuild: true, keepAll: true])  // 마지막 빌드 링크, 빌드마다 보관
        }                                                   // each 끝
      }                                                     // script 끝
    }                                                       // always 끝
  }                                                         // post 끝
}                                                           // pipeline 끝
