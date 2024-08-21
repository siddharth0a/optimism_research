# 주요 작동 플로우

/cmd main.go : main
=> /batcher batch_submitter.go : Main
=> /batcher service.go : BatcherServiceFromCLIConfig
=> /batcher service.go : initFromCLIConfig
=> /batcher service.go : initRPCClients
                       : initMetrics
                       : initBalanceMonitor
                       : initRollupConfig
                       : initChannelConfig
                       : initTxManager
                       : initPProf
                       : initMetricsServer
                       : initDriver
                       : initRPCServer
                       : initAltDA

# 데이터 플로우