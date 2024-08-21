# dir struct
.
├── batcher         // 배처 핵심 로직
├── cmd             // 커맨드라인 인터페이스 로직, entry point
├── compressor      // 데이터 압축기 로직
├── flags           // 커맨드 라인 플래그, 설정 코드
├── metrics         // 성능 모니터링 지표 수집 관련 코드
└── rpc             // Remote Procedure Call 코드, 다른 서비스와 상호작용하거나
                    // 외부에서 op-batcher에 요청 보내는 방식으로 데이터 주고받는 로직
                    // RPC 서버와 클라이언트 코드, 메시지 형식 정의 등 포함

# file struct
.
├── Makefile
├── batcher
│   ├── batch_submitter.go          // L2 데이터를 L1에 제출하는 핵심 로직
│   ├── channel.go                  // 채널(여러 트랜잭션을 묶어 처리하는 단위)의 기본적인 구조
│   ├── channel_builder.go          // 채널을 생성하고 관리하는 로직
│   ├── channel_config.go           // 채널 config 구조체 및 로직
│   ├── channel_config_provider.go  // 채널 config 제공 로직. 설정을 외부에서 받아오거나 내부에서 생성
│   ├── channel_manager.go          // 채널 관리 및 트랜잭션 배분 로직
│   ├── config.go                   // op-batcher의 전체 설정을 정의
│   ├── driver.go                   // 배처의 주요 작업을 실행하고 관리하는 드라이버 로직
│   ├── service.go                  // 배처의 서비스 로직을 관리
│   ├── tx_data.go                  // 트랜잭션 데이터와 관련된 구조체 및 로직
├── cmd
│   └── main.go                     // op-batcher의 entry point, 메인함수 정의
├── compressor
│   ├── compressors.go              // 압축 알고리즘 구현
│   ├── config.go                   // 압축 설정 정의
│   ├── non_compressor.go           // 압축을 수행하지 않는 경우에 대한 로직
│   ├── ratio_compressor.go         // 특정 압축 비율에 따라 데이터를 압축하는 알고리즘
│   ├── shadow_compressor.go        // shadow 압축기 구현(데이터의 특정 부분만 압축)
├── flags
│   ├── flags.go                    // 플래그를 정의하고 처리하는 로직
│   └── types.go                    // 플래그와 관련된 타입 정의
├── metrics
│   ├── metrics.go                  // 메트릭을 수집하고 관리하는 주요 로직
│   └── noop.go                     // "No Operation"을 수행하는 메트릭 로직, 메트릭 수집이 필요하지 않을때 사용
├── research
│   └── dir.md
└── rpc
    └── api.go                      // RPC API 관련 로직