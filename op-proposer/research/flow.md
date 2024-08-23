# 주요 작동 플로우

## /cmd/main.go
main.go는 애플리케이션의 진입점으로, 초기 설정을 수행하고 proposer 서비스를 시작

```plaintext
=>  : main {
        /op-service/cliapp/lifecycle.go: RunContext{
            /proposer/l2_output_submitter.go : Main {
                /proposer/service.go : ProposerServiceFromCLIConfig   // 프로포저 서비스의 진입점, CLI 설정을 통해 프로포저 서비스를 초기화하고 실행
            }
            /op-service/cliapp/lifecycle.go : LifecycleCmd {
                        /proposer/service.go : Start {
                            /proposer/driver.go : StartL2OutputSubmitting
                        }
                    }
        }

}
```


## /proposer/service.go
service.go는 배처 서비스의 CLIConfig를 설정하고, L2OutputSubmitter 생성하고 시작

```plaintext
=>  : ProposerServiceFromCLIConfig {
        : initFromCLIConfig {
            : initMetrics
            : initL2ooAddress
            : initDGF
            : initRPCClients
            : initTxManager
            : initBalanceMonitor
            : initMetricsServer
            : initPProf
            : initRPCServer
            : RecordInfo
            : RecordUp
            : initMetricsServer
            : initDriver {
                /proposer/driver.go : NewL2OutputSubmitter {
                    /proposer/driver.go : newL2OOSubmitter
                }
            }
        }
    }
```

## /proposer/driver.go

```plaintext
=>  : StartL2OutputSubmitting {
        : waitNodeSync {
            /op-service/dial/rollup_sync.go : WaitRollupSync
        }
        : loop {

        }

}