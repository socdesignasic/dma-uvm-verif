// -----------------------------------------------------------------------------
// dma-uvm CI : Vivado 2022.2 XSim에서 dma_ip UVM 회귀
//
//   main에 push (SCM poll) : smoke = unit 테스트 전부 + top smoke 묶음, seed 1개
//                            + FPGA 단독(out-of-context) 합성/배치배선 타이밍 확인 (100 MHz)
//   매일 타이머 (02:00)    : full  = 모든 TB의 모든 테스트, seed 5개, 커버리지 보고서
//                            + FPGA 시스템 빌드: 비트스트림 + XSA (CD 결과물)
//   수동 "Build with Parameters"로 둘 중 하나를 강제하거나, seed 수를 바꾸거나, 비트스트림을 요청할 수 있음.
//
// Agent: label 'vivado' (이 PC). PYTHON / XILINX_VIVADO / REGRESS_JOBS는 노드 환경
// (ci/jenkins.yaml)에서 옴. 모든 단계는 개발자가 손으로 돌리는 것과 같은 스크립트를
// 부르므로, CI 실패는 출력된 `rerun` 명령으로 로컬에서 재현됨.
// -----------------------------------------------------------------------------
def TOP_SMOKE = 'dma_reg_reset_test dma_reg_bitbash_test dma_smoke_test dma_small_test dma_irq_test dma_aw_backpressure_test'
def COV_TBS   = ['top', 'adder8', 'adder', 'fifo', 'fifo_d4', 'skid']

pipeline {
  agent { label 'vivado' }

  options {
    timestamps()
    timeout(time: 4, unit: 'HOURS')
    buildDiscarder(logRotator(numToKeepStr: '30', artifactNumToKeepStr: '10'))
    disableConcurrentBuilds()
  }

  parameters {
    choice(name: 'MODE', choices: ['auto', 'smoke', 'full'],
           description: 'auto: 코드가 바뀌면 smoke, 매일 타이머면 full')
    string(name: 'SEEDS', defaultValue: '', description: '테스트당 seed 수 (비우면 smoke=1, full=5)')
    booleanParam(name: 'BITSTREAM', defaultValue: false, description: '비트스트림 + XSA도 빌드 (full 모드에서는 항상 켜짐)')
  }

  stages {
    stage('Plan') {
      steps {
        script {
          def nightly = !currentBuild.getBuildCauses('hudson.triggers.TimerTrigger$TimerTriggerCause').isEmpty()
          env.RUN_MODE = (params.MODE == 'auto') ? (nightly ? 'full' : 'smoke') : params.MODE
          env.N_SEEDS  = params.SEEDS?.trim() ? params.SEEDS.trim() : (env.RUN_MODE == 'full' ? '5' : '1')
          env.JOBS     = env.REGRESS_JOBS ?: '4'
          env.DO_BITSTREAM = (env.RUN_MODE == 'full' || params.BITSTREAM) ? 'true' : 'false'
          currentBuild.description = "${env.RUN_MODE}, ${env.N_SEEDS} seed(s)" + (env.DO_BITSTREAM == 'true' ? ', bitstream' : '')
        }
        bat 'if exist out rmdir /s /q out'
        bat '"%PYTHON%" --version && "%PYTHON%" scripts/sim.py list'
      }
    }

    stage('Lint') {
      steps {
        bat '"%PYTHON%" scripts/sim.py lint --tb rtl'
        bat '"%PYTHON%" scripts/sim.py lint --tb top'
      }
    }

    stage('Unit regression') {
      steps {
        // 회귀가 실패하면 stage/빌드에 표시하지만 이후 stage는 계속 실행
        catchError(buildResult: 'FAILURE', stageResult: 'FAILURE') {
          bat '"%PYTHON%" scripts/regress.py --suite unit --seeds %N_SEEDS% --jobs %JOBS% --name unit'
        }
      }
    }

    stage('Top regression') {
      steps {
        script {
          def subset = (env.RUN_MODE == 'smoke') ? "--tests ${TOP_SMOKE}" : ''
          catchError(buildResult: 'FAILURE', stageResult: 'FAILURE') {
            bat "\"%PYTHON%\" scripts/regress.py --suite top --seeds %N_SEEDS% --jobs %JOBS% --name top ${subset}"
          }
        }
      }
    }

    stage('FPGA timing (OOC)') {
      steps {
        catchError(buildResult: 'FAILURE', stageResult: 'FAILURE') {
          bat '"%PYTHON%" scripts/fpga.py ooc'
        }
      }
    }

    stage('FPGA bitstream') {
      when { environment name: 'DO_BITSTREAM', value: 'true' }
      steps {
        catchError(buildResult: 'FAILURE', stageResult: 'FAILURE') {
          bat '"%PYTHON%" scripts/fpga.py system --jobs %JOBS%'
        }
      }
    }

    stage('Coverage') {
      when { environment name: 'RUN_MODE', value: 'full' }
      steps {
        script {
          COV_TBS.each { tb ->
            catchError(buildResult: 'UNSTABLE', stageResult: 'UNSTABLE') {
              bat "\"%PYTHON%\" scripts/sim.py cov-report --tb ${tb}"
            }
          }
        }
      }
    }
  }

  post {
    always {
      junit testResults: 'out/regress/*/junit.xml', allowEmptyResults: true
      archiveArtifacts allowEmptyArchive: true, fingerprint: false,
        artifacts: 'out/regress/**/*.json, out/regress/**/*.xml, out/*/runs/**/run.log, out/*/runs/**/result.json, out/*/build/*.log, out/fpga/*/result.json, out/fpga/*/*.rpt, out/fpga/*/vivado.log'
      // CD 결과물: fingerprint를 남겨 보드 이미지가 어느 빌드와 커밋에서 나왔는지 추적 가능
      archiveArtifacts allowEmptyArchive: true, fingerprint: true,
        artifacts: 'out/fpga/system/design_1_wrapper.bit, out/fpga/system/design_1_wrapper.xsa'
      script {
        COV_TBS.each { tb ->
          publishHTML(target: [reportName: "Coverage ${tb}", reportDir: "out/${tb}/cov/func",
                               reportFiles: 'dashboard.html', allowMissing: true,
                               alwaysLinkToLastBuild: true, keepAll: true])
        }
      }
    }
  }
}
