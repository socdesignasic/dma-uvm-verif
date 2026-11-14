// -----------------------------------------------------------------------------
// dma-uvm CI : UVM regression of dma_ip on Vivado 2022.2 XSim
//
//   push to main (SCM poll) : smoke = all unit tests + top smoke subset, 1 seed
//                             + FPGA out-of-context synth/P&R timing check (100 MHz)
//   nightly timer (02:00)   : full  = every test of every TB, 5 seeds, coverage report
//                             + FPGA system build: bitstream + XSA (the CD artifacts)
//   manual "Build with Parameters" can force either, override the seeds, or request a bitstream.
//
// Agent: label 'vivado' (the local PC). PYTHON / XILINX_VIVADO / REGRESS_JOBS come
// from the node environment (ci/jenkins.yaml). Every step calls the same scripts a
// developer runs by hand, so a CI failure reproduces locally with the printed
// `rerun` command.
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
           description: 'auto: smoke on SCM change, full on the nightly timer')
    string(name: 'SEEDS', defaultValue: '', description: 'seeds per test (empty: smoke=1, full=5)')
    booleanParam(name: 'BITSTREAM', defaultValue: false, description: 'also build bitstream + XSA (always on in full mode)')
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
        // a failing regression marks the stage/build but later stages still run
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
      // CD artifacts: fingerprinted so a board image can be traced back to its build and commit
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
