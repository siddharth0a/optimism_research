# 주요 작동 플로우

## /cmd/main.go
main.go는 애플리케이션의 진입점으로, 초기 설정을 수행하고 BatchSubmitter 서비스를 시작

```plaintext
=>  : main {
        /batcher/batch_submitter.go : Main
        /op-service/cliapp/lifecycle.go : LifecycleCmd {
            /batcher/service.go : Start
        }
}
```

## /batcher/batch_submitter.go
batch_submitter.go는 배처 서비스의 진입점 역할을 하며, CLI 설정을 통해 배처 서비스를 초기화하고 실행

```plaintext
=>  : Main {
        /batcher/service.go : BatcherServiceFromCLIConfig
}
```

## /batcher/service.go
service.go는 배처 서비스의 CLIConfig를 설정하고, BatchSubmitter를 생성하고 시작

```plaintext
=>  : BatcherServiceFromCLIConfig {
        : initFromCLIConfig {
            : initRPCClients
            : initMetrics
            : initBalanceMonitor
            : initRollupConfig
            : initChannelConfig
            : initTxManager
            : initPProf
            : initAltDA
            : initMetricsServer
            : initDriver {
                /batcher/driver.go : NewBatchSubmitter {
                    /batcher/driver.go : NewChannelManager
                }
            }
            : initRPCServer
        }
    }
    : Start {
        /batcher/driver.go : StartBatchSubmitting
    }
```


## /batcher driver.go
driver.go는 배처 서비스의 주요 실행 로직을 담당하며, 트랜잭션을 L1 블록체인에 제출하고 상태를 관리하는 역할

```plaintext
=>  : StartBatchSubmitting {
        loop {
            : make(chan struct{})
            : txpoolState.Store(TxpoolGood)
            : handleReceipt(r)
            : publishStateToL1(queue, receiptCh)
            : loadBlocksIntoState {
                : calculateL2BlockRangeToStore
                : loadBlockIntoState
                : L2BlockToBlockRef {
                    /batcher/channel_manager.go : AddL2Block
                }
                : RecordL2BlocksLoaded
            }
            : publishStateToL1 {
                : publishTxToL1 {
                    /batcher/channel_manager.go : TxData
                    : sendTransaction
                    => blob or CallData
                }
            }
        }
    }
```

## channel.go
channel.go는 블록 데이터를 처리하고, 이를 채널에 프레임으로 전환하여 L1에 제출하기 위한 역할을 담당

```plaintext
=>  : newChannel {
    /batcher/channel_builder.go : NewChannelBuilder
}
```

## channel_builder.go
channel_builder.go는 채널 빌더를 초기화하고, 데이터를 압축 및 프레임으로 변환하는 작업을 수행

```plaintext
=>  : NewChannelBuilder {
        /compressor/config.go  : NewCompressor
        /op-node/rollup/derive.go : NewSpanChannelOut
    }
```

## channel_manager.go
channel_manager.go는 블록 데이터를 관리하고, 이를 L1에 제출하기 위한 트랜잭션 데이터를 생성하며, 채널 상태를 관리

```plaintext
=>  : TxData {
        : ensureChannelWithSpace {
            /batcher/channel.go : newChannel
        }
        : processBlocks {
            /batcher/channel.go : AddBlock {
                /batcher/channel_builder.go : AddBlock {
                    /op-node/rollup/derive/channel_out.go : BlockToSingularBatch
                    /op-node/rollup/derive/channel_out.go : AddSingularBatch
                }
            }
            : l2BlockRefFromBlockAndL1Info
        }
        : registerL1Block
        : outputFrames {
            /batcher/channel.go : OutputFrames
        }
        : nextTxData
    }
```


# 데이터 플로우

