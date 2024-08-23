# dir struct
```plaintext
.
├── bindings        // 스마트 컨트랙트 바인딩 코드, Go에서 스마트 컨트랙트와 상호작용하는 코드 포함
├── cmd             // 커맨드라인 인터페이스 로직, 애플리케이션의 진입점
├── contracts       // 스마트 컨트랙트 정의 및 관련 코드, Solidity 소스 파일 포함
├── flags           // 커맨드 라인 플래그 및 설정 코드
├── metrics         // 성능 모니터링 지표 수집 관련 코드
└── proposer        // Proposer 핵심 로직
    └── rpc         // Remote Procedure Call 코드, 다른 서비스와 상호작용하거나
                    // 외부에서 Proposer에 요청을 보내는 방식으로 데이터 주고받는 로직
                    // RPC 서버와 클라이언트 코드, 메시지 형식 정의 등 포함
```

# file struct
```plaintext
├── Makefile                             // 프로젝트의 빌드, 테스트, 배포 등의 작업을 자동화하기 위한 명령어 집합
├── bindings
│   └── l2outputoracle.go                // L2 Output Oracle 스마트 컨트랙트와 상호작용하는 Go 바인딩 코드
├── cmd
│   └── main.go                          // Proposer 애플리케이션의 진입점으로, 커맨드라인 인터페이스 실행 코드
├── contracts
│   ├── disputegamefactory.go            // Dispute Game Factory 스마트 컨트랙트 정의
│   └── disputegamefactory_test.go       // Dispute Game Factory 스마트 컨트랙트의 테스트 코드
├── flags
│   ├── flags.go                         // 커맨드라인 플래그 및 설정 관련 코드
│   └── flags_test.go                    // 플래그 관련 기능의 테스트 코드
├── metrics
│   ├── metrics.go                       // 성능 모니터링 지표를 수집하고 보고하는 로직
│   └── noop.go                          // 비활성화된 성능 모니터링 기능을 처리하기 위한 'no-operation' 코드
├── proposer
    ├── abi_test.go                      // ABI(애플리케이션 바이너리 인터페이스) 관련 테스트 코드
    ├── config.go                        // Proposer 서비스의 설정 관련 코드
    ├── driver.go                        // Proposer의 주요 로직을 처리하는 드라이버 코드
    ├── driver_test.go                   // 드라이버 로직에 대한 테스트 코드
    ├── l2_output_submitter.go           // L2 Output 데이터를 제출하는 로직
    ├── rpc
    │   └── api.go                       // Proposer의 RPC 인터페이스를 정의하고, 외부 서비스와의 상호작용을 처리하는 코드
    └── service.go                       // Proposer 서비스의 주요 비즈니스 로직을 처리하는 코드
```