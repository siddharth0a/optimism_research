.
├── batcher         // 배처 핵심 로직
├── cmd             // 커맨드라인 인터페이스 로직, entry point
├── compressor      // 데이터 압축기 로직
├── flags           // 커맨드 라인 플래그, 설정 코드
├── metrics         // 성능 모니터링 지표 수집 관련 코드
└── rpc             // Remote Procedure Call 코드, 다른 서비스와 상호작용하거나
                    // 외부에서 op-batcher에 요청 보내는 방식으로 데이터 주고받는 로직
                    // RPC 서버와 클라이언트 코드, 메시지 형식 정의 등 포함



