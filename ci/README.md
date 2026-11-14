# Local Jenkins CI for dma-uvm

A dedicated Jenkins controller on this PC, port **8090**. Port 8080 is taken by the
separately installed Jenkins Windows service, which this setup does not touch.
All Jenkins configuration is code: `ci/jenkins.yaml` (JCasC) + `ci/plugins.txt` + `Jenkinsfile`.

## Start / stop
```powershell
powershell -ExecutionPolicy Bypass -File ci\start-jenkins.ps1   # installs plugins on first run
powershell -ExecutionPolicy Bypass -File ci\stop-jenkins.ps1
```
- UI: http://localhost:8090/job/dma-uvm/ (listens on 127.0.0.1 only, anonymous access blocked)
- User `admin`. The password is in `%USERPROFILE%\jenkins\home\secrets\casc\JENKINS_ADMIN_PASSWORD`
  (generated on first start).
- Jenkins does not start automatically after a reboot. Run `start-jenkins.ps1` again,
  or register it as a logon task.

| Path | Content |
|---|---|
| `%USERPROFILE%\jenkins\jenkins.war` | Jenkins 2.580.2 LTS (sha256 verified) |
| `%USERPROFILE%\jenkins\home` | JENKINS_HOME (jobs, builds, plugins, `jenkins.log`) |
| `...\home\secrets\casc\` | JCasC secrets: GitHub token (refreshed from `gh auth token` on each start), admin password |

Secrets are read by JCasC through `SECRETS`. They are not in the controller environment, so
build steps cannot see them, and they never go into git.

## Pipeline (`Jenkinsfile`)
| Trigger | Mode | What runs |
|---|---|---|
| push to `main` (SCM poll, every 5 min) | smoke | lint, all unit tests, top smoke subset, 1 seed |
| nightly ~02:00 | full | every test of every TB × 5 seeds + functional coverage HTML |
| "Build with Parameters" | either | `MODE`, `SEEDS` override |

Stages: Plan → Lint → Unit regression → Top regression → Coverage (full only).
Results: JUnit trend (XFAIL known bugs show as *skipped*), archived `run.log`/`result.json`,
and "Coverage <tb>" HTML reports. Each failure prints its `rerun` command, which reproduces
it locally:
```bash
python scripts/sim.py run --tb top --test dma_rand_test --seed 123456
```

## Node environment (from `ci/jenkins.yaml`)
`PYTHON`, `XILINX_VIVADO`, `REGRESS_JOBS` (parallel xsim runs inside one build, default 6).
To change a path, pass a parameter to `start-jenkins.ps1` (e.g. `-RegressJobs 4`) and restart.

## FPGA implementation / CD (`scripts/fpga.py`, `ci/vivado/`)
| Command | What | Time |
|---|---|---|
| `python scripts/fpga.py ooc [--period 10]` | `dma_ip_top` alone: synth + place + route, timing and utilization | ~3 min |
| `python scripts/fpga.py system` | PS7 + DMA block design → `design_1_wrapper.bit` + `design_1_wrapper.xsa` | ~10–20 min |

- RTL comes only from `HW/`. The IP repo is assembled from `HW/` + `ci/vivado/ip/` (component.xml, xgui),
  so the bitstream always contains exactly the verified RTL.
- `ci/vivado/bd/design_1.tcl` is the block design, exported once from the hand-made project by
  `ci/vivado/export_bd.tcl` (opened read-only). PS7 settings are explicit, so no board files are needed.
- Results go to `out/fpga/<mode>/result.json` (verdict, WNS/WHS, utilization, sha256 of bit/xsa).
  Exit code 1 = timing violated, 2 = build error.
- Jenkins: every build runs `ooc`. Nightly/full (or `BITSTREAM=true`) runs `system`. The `.bit`/`.xsa`
  are archived and **fingerprinted**, so a board image traces back to its build and commit.
- Board programming is manual (Vitis or Hardware Manager with the XSA). No board is attached to CI.

## Known log message: "Selected Git installation does not exist. Using Default"
Harmless. Left as is on purpose.

- **Where:** SCM polling logs and the `Declarative: Checkout SCM` stage, followed by
  `The recommended git tool is: NONE`.
- **Cause (git plugin 5.11.0, read from its bytecode):** `GitToolChooser.determineSwitchOnSize`
  sees that the repo is smaller than 5 MB and tries to recommend **JGit**. It looks up a git
  installation named `jgit` (`GitUtils.resolveGitTool("jgit")`). Only `Default` exists, so the lookup
  fails and prints this message. The recommendation becomes `NONE`, and the job's own tool
  `Default` (`git.exe` on PATH) is used, so checkout and polling work normally.
- It shows up only once the repo size is cached. A poll right after a Jenkins restart may not print it.
- **Correction:** the commit `bca3c5d` message says this warning came from the
  `tool: git: home: "${GIT_EXE}"` entry being stored literally. That was wrong. The warning remained
  after the fix (build #9). Removing that entry was still correct, because it was a broken path.
- **To silence it** (not done, because it changes behaviour): add a `jgit` installation to
  `ci/jenkins.yaml`, which makes small-repo checkouts use JGit instead of the git CLI, or disable the
  git tool chooser for the job.
