# RPC 구조

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