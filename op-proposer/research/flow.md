# 주요 작동 플로우

## /cmd/main.go
main.go는 애플리케이션의 진입점으로, 초기 설정을 수행하고 proposer 서비스를 시작

```plaintext
=>  : main {
        /op-service/cliapp/lifecycle.go: RunContext{
            /proposer/l2_output_submitter.go : Main {          // L2 Output Submitter 초기화 및 실행
                /proposer/service.go : ProposerServiceFromCLIConfig   // 프로포저 서비스의 진입점, CLI 설정을 통해 프로포저 서비스를 초기화하고 실행
            }
            /op-service/cliapp/lifecycle.go : LifecycleCmd {    // CLI 애플리케이션 수명주기 관리
                /proposer/service.go : Start {
                    /proposer/driver.go : StartL2OutputSubmitting   // L2 Output 제출 시작
                }
            }
        }
    }
```


## /proposer/service.go
service.go는 proposer 서비스의 CLIConfig를 설정하고, L2OutputSubmitter 생성하고 시작

```plaintext
=>  : ProposerServiceFromCLIConfig {
        : initFromCLIConfig {
            : initMetrics               // 성능 지표 초기화
            : initL2ooAddress           // L2 Output Oracle 주소 초기화
            : initDGF                   // Dispute Game Factory 초기화
            : initRPCClients            // RPC 클라이언트 초기화
            : initTxManager             // 트랜잭션 관리 초기화
            : initBalanceMonitor        // 잔액 모니터링 초기화
            : initMetricsServer         // 성능 모니터링 서버 초기화
            : initPProf                 // 프로파일링 초기화
            : initRPCServer             // RPC 서버 초기화
            : RecordInfo                // 서비스 정보 기록
            : RecordUp                  // 서비스 시작 상태 기록
            : initMetricsServer         // (중복된) 성능 모니터링 서버 초기화
            : initDriver {              // 드라이버 초기화
                /proposer/driver.go : NewL2OutputSubmitter {    // 새로운 L2 Output Submitter 생성
                    /proposer/driver.go : newL2OOSubmitter      // L2 Output Submitter 인스턴스 생성
                }
            }
        }
    }
```

## /proposer/driver.go

```plaintext
=>  : StartL2OutputSubmitting {
        : waitNodeSync {                   // 노드 동기화 대기
            /op-service/dial/rollup_sync.go : WaitRollupSync   // 롤업 동기화 대기
        }
        : loop {                            // L2 Output 제출 루프
            {
                : FetchL2OOOutput       // L2 Output Oracle과 fetch
                or
                : FetchDGFOutput        // Dispute Game Factory과 fetch
            }
            : proposeOutput {               // 출력 제안
                : sendTransaction {         // 트랜잭션 전송
                    : waitForL1Head         // L1 블록체인 헤드 대기
                    {
                        : ProposeL2OutputDGFTxCandidate  // Dispute Game Factory 트랜잭션 후보 제안
                        : Send          // 트랜잭션 전송 로직, TODO: 구체적인 구현 분석 필요
                        or
                        : ProposeL2OutputTxData          // L2 Output 트랜잭션 데이터 제안
                        : Send          // 트랜잭션 전송 로직, TODO: 구체적인 구현 분석 필요
                    }
                }
                /metrics/metrics.go : RecordL2BlocksProposed {   // L2 블록 제안 기록
                    /op-service/metrics/ref_metrics.go : RecordL2Ref   // L2 참조 기록
                }
            }
        }
    }
```