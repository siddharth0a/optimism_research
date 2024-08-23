# RPC flow


## Endpoint 연결
/batcher/service.go의 initRPCClients에서 l1Client, L2Endpoint에 연결

```plaintext
=> /batcher/service.go : initPRCClients {
    L1Client    // L1 연결
    endpointProvider // L2 연결 {
        rollupUrls  // L2 op-node 연결
        ethUrls     // L2 op-geth 연결
    }
}
```

## Interface

RPC interface
```go
type L1Client interface {
	HeaderByNumber(ctx context.Context, number *big.Int) (*types.Header, error)
	NonceAt(ctx context.Context, account common.Address, blockNumber *big.Int) (uint64, error)
}
type L2Client interface {
	BlockByNumber(ctx context.Context, number *big.Int) (*types.Block, error)
}

type RollupClient interface {
	SyncStatus(ctx context.Context) (*eth.SyncStatus, error)
}
```



## L1 상호작용

```plaintext
=> /batcher/driver.go : StartBatchSubmitting {
        : waitNodeSync // rollup node가 적절히 동기화되었는지 확인하는 전체 프로세스를 관리 {
            /op-service/dial/rollup_sync.go : WaitRollupSync // rollup 노드 싱크
        }
        : loop {
            : publishStateToL1 {
                : publishTxToL1 {
                    : l1Tip // L1 블록체인의 현재 상태를 가져옴
                    /bathcer/channel_manager.go : TxData // L1에 제출해야할 데이터 추출
                    : sendTransaction // L1에 Tx데이터 제출
                }
            }
        }
    }

```


```go
// L1에 트랜잭션 제출
// publishTxToL1 submits a single state tx to the L1
func (l *BatchSubmitter) publishTxToL1(ctx context.Context, queue *txmgr.Queue[txRef], receiptsCh chan txmgr.TxReceipt[txRef]) error {
	// send all available transactions
    // L1 tip 조회
	l1tip, err := l.l1Tip(ctx)
	if err != nil {
		l.Log.Error("Failed to query L1 tip", "err", err)
		return err
	}
    // L1 tip 기록
	l.recordL1Tip(l1tip)

	// Collect next transaction data
	// L1 tip에 해당하는 tx데이터 수집
	txdata, err := l.state.TxData(l1tip.ID())

	if err == io.EOF {
		l.Log.Trace("No transaction data available")
		return err
	} else if err != nil {
		l.Log.Error("Unable to get tx data", "err", err)
		return err
	}

    // 수집된 트랜잭션 제출
	if err = l.sendTransaction(ctx, txdata, queue, receiptsCh); err != nil {
		return fmt.Errorf("BatchSubmitter.sendTransaction failed: %w", err)
	}
	return nil
}

// l1Tip : L1 블록체인의 현재 상태를 가져옴
// l1Tip gets the current L1 tip as a L1BlockRef. The passed context is assumed
// to be a lifetime context, so it is internally wrapped with a network timeout.
func (l *BatchSubmitter) l1Tip(ctx context.Context) (eth.L1BlockRef, error) {
    // context 추출
	tctx, cancel := context.WithTimeout(ctx, l.Config.NetworkTimeout)
	defer cancel()
	head, err := l.L1Client.HeaderByNumber(tctx, nil)
	if err != nil {
		return eth.L1BlockRef{}, fmt.Errorf("getting latest L1 block: %w", err)
	}
	return eth.InfoToL1BlockRef(eth.HeaderBlockInfo(head)), nil
}

// waitSyncNode는 L1 블록체인과 동기화상태를 확인하고, 최근 제출한 배치 트랜잭션이
// 충분한 블록 확인을 거쳐 최종적으로 확정되었는지 확인하는 역할
// waitNodeSync Check to see if there was a batcher tx sent recently that
// still needs more block confirmations before being considered finalized
func (l *BatchSubmitter) waitNodeSync() error {
	ctx := l.shutdownCtx

    // rollupClient (op-node) 가져오기
	rollupClient, err := l.EndpointProvider.RollupClient(ctx)
	if err != nil {
		return fmt.Errorf("failed to get rollup client: %w", err)
	}

	cCtx, cancel := context.WithTimeout(ctx, l.Config.NetworkTimeout)
	defer cancel()

    // L1 블록체인 현재 상태 나타내는 L1tip 가져옴
	l1Tip, err := l.l1Tip(cCtx)
	if err != nil {
		return fmt.Errorf("failed to retrieve l1 tip: %w", err)
	}

	l1TargetBlock := l1Tip.Number
	if l.Config.CheckRecentTxsDepth != 0 {
		l.Log.Info("Checking for recently submitted batcher transactions on L1")
        // 최근에 제출된 배치 트랜잭션 있는지 확인
		recentBlock, found, err := eth.CheckRecentTxs(cCtx, l.L1Client, l.Config.CheckRecentTxsDepth, l.Txmgr.From())
		if err != nil {
			return fmt.Errorf("failed checking recent batcher txs: %w", err)
		}
		l.Log.Info("Checked for recently submitted batcher transactions on L1",
			"l1_head", l1Tip, "l1_recent", recentBlock, "found", found)
		l1TargetBlock = recentBlock
	}
    // 롤업 노드 동기화 대기
	return dial.WaitRollupSync(l.shutdownCtx, l.Log, rollupClient, l1TargetBlock, time.Second*12)
}
```

op-node, L1 싱크
```go
func WaitRollupSync(
	ctx context.Context,
	lgr log.Logger,
	rollup SyncStatusProvider,
	l1BlockTarget uint64,
	pollInterval time.Duration,
) error {
	timer := time.NewTimer(pollInterval)
	defer timer.Stop()

	for {
		syncst, err := rollup.SyncStatus(ctx)
		if err != nil {
			// don't log assuming caller handles and logs errors
			return fmt.Errorf("getting sync status: %w", err)
		}

		lgr := lgr.With("current_l1", syncst.CurrentL1, "target_l1", l1BlockTarget)
		if syncst.CurrentL1.Number >= l1BlockTarget {
			lgr.Info("rollup current L1 block target reached")
			return nil
		}

		lgr.Info("rollup current L1 block still behind target, retrying")

		timer.Reset(pollInterval)
		select {
		case <-timer.C: // next try
		case <-ctx.Done():
			lgr.Warn("waiting for rollup sync timed out")
			return ctx.Err()
		}
	}
}

```

## L2 RPC 상호작용


배처(Batcher)가 제출하는 데이터의 출처는 주로 L2 노드(op-geth)에서 가져온 블록 데이터이지만, op-node(롤업 노드)도 동기화 상태를 관리하고, L2와 L1 간의 연계 정보를 제공하는 데 중요한 역할을 합니다. 이 두 가지를 조합하여 배처가 데이터를 준비하고 L1에 제출

/batcher/driver.go

```plaintext
=>  loop {
        : loadBlocksIntoState {
            : calculateL2BlockRangeToStore // op-node에서 동기화 상태 관리 {
                RollupClient {
                    op-conductor/rpc/node_proxy.go : SyncStatus
                }
            }
            : loadBlockIntoState // op-geth에서 블록 데이터 추출 {
                EthClient
            }
        }
    }

```


```go
// calculateL2BlockRangeToStore determines the range (start,end] that should be loaded into the local state.
// It also takes care of initializing some local state (i.e. will modify l.lastStoredBlock in certain conditions)
func (l *BatchSubmitter) calculateL2BlockRangeToStore(ctx context.Context) (eth.BlockID, eth.BlockID, error) {
	rollupClient, err := l.EndpointProvider.RollupClient(ctx)
	if err != nil {
		return eth.BlockID{}, eth.BlockID{}, fmt.Errorf("getting rollup client: %w", err)
	}

	cCtx, cancel := context.WithTimeout(ctx, l.Config.NetworkTimeout)
	defer cancel()

	syncStatus, err := rollupClient.SyncStatus(cCtx)
	// Ensure that we have the sync status
	if err != nil {
		return eth.BlockID{}, eth.BlockID{}, fmt.Errorf("failed to get sync status: %w", err)
	}
	if syncStatus.HeadL1 == (eth.L1BlockRef{}) {
		return eth.BlockID{}, eth.BlockID{}, errors.New("empty sync status")
	}

	// Check last stored to see if it needs to be set on startup OR set if is lagged behind.
	// It lagging implies that the op-node processed some batches that were submitted prior to the current instance of the batcher being alive.
	if l.lastStoredBlock == (eth.BlockID{}) {
		l.Log.Info("Starting batch-submitter work at safe-head", "safe", syncStatus.SafeL2)
		l.lastStoredBlock = syncStatus.SafeL2.ID()
	} else if l.lastStoredBlock.Number < syncStatus.SafeL2.Number {
		l.Log.Warn("Last submitted block lagged behind L2 safe head: batch submission will continue from the safe head now", "last", l.lastStoredBlock, "safe", syncStatus.SafeL2)
		l.lastStoredBlock = syncStatus.SafeL2.ID()
	}

	// Check if we should even attempt to load any blocks. TODO: May not need this check
	if syncStatus.SafeL2.Number >= syncStatus.UnsafeL2.Number {
		return eth.BlockID{}, eth.BlockID{}, errors.New("L2 safe head ahead of L2 unsafe head")
	}

	return l.lastStoredBlock, syncStatus.UnsafeL2.ID(), nil
}

// loadBlockIntoState fetches & stores a single block into `state`. It returns the block it loaded.
func (l *BatchSubmitter) loadBlockIntoState(ctx context.Context, blockNumber uint64) (*types.Block, error) {
	l2Client, err := l.EndpointProvider.EthClient(ctx)
	if err != nil {
		return nil, fmt.Errorf("getting L2 client: %w", err)
	}

	cCtx, cancel := context.WithTimeout(ctx, l.Config.NetworkTimeout)
	defer cancel()

	block, err := l2Client.BlockByNumber(cCtx, new(big.Int).SetUint64(blockNumber))
	if err != nil {
		return nil, fmt.Errorf("getting L2 block: %w", err)
	}

	if err := l.state.AddL2Block(block); err != nil {
		return nil, fmt.Errorf("adding L2 block to state: %w", err)
	}

	l.Log.Info("Added L2 block to local state", "block", eth.ToBlockID(block), "tx_count", len(block.Transactions()), "time", block.Time())
	return block, nil
}
```


