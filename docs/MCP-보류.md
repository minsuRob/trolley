# MCP / Claude Code 연동 — 지금은 뺐다

`e97ded4` 까지는 trolley 가 **두 가지 소비자**를 동시에 섬겼다. 이 문서는 그중 하나를
왜 걷어냈고, 되살릴 때 무엇을 보면 되는지를 남긴다.

## 무엇이 있었나

같은 도구 묶음(`TrolleyTools`)을 두 방향에서 불렀다.

```
[로컬 모델]  ──in-process──→ TrolleyTools ──→ macOS      ← 남긴 쪽
[Claude Code] ──stdio JSON-RPC──→ MCPServer ──→ TrolleyTools ──→ macOS   ← 뺀 쪽
```

`trolley mcp` 는 Claude Code 같은 MCP 클라이언트가 **자식 프로세스로** 띄우는 별개
프로세스였다. GUI 앱이 띄우는 게 아니다 — 앱과 아무 연결이 없고 바이너리만 같았다.
(이 점을 한동안 반대로 알고 있었다. 앱은 자식 프로세스를 갖지 않는다.)

## 왜 뺐나

초반 복잡도. 실제로 쓰이는 경로는 프롬프트 상자 → 로컬 모델 하나인데, MCP 쪽이
데려오는 것이 적지 않았다:

- JSON-RPC 프레이밍, stdio 루프, 클라이언트 사망 감지(`OrphanWatch`)
- 위젯의 목적지 스위치 — 프롬프트를 로컬 모델에게 줄지 대기열에 넣을지
- `take_prompt` 도구와 그 대기열(`PromptQueue`)
- 설정 창의 "Claude Code에 연결" 행과 등록 상태 폴링

쓰는 사람이 한 명이고 그 한 명이 프롬프트 상자만 쓰는 단계에서, 위의 절반은 화면과
설정에 자리만 차지했다.

## 무엇을 지웠나 (`e97ded4` 에서 꺼내면 된다)

```
git show e97ded4:Sources/TrolleyMCP/MCPServer.swift
git show e97ded4:Sources/TrolleyMCP/JSONRPC.swift
git show e97ded4:Sources/TrolleyMCP/OrphanWatch.swift
git show e97ded4:Sources/TrolleyMCP/PromptQueue.swift
git show e97ded4:Sources/trolley/Commands/McpCommand.swift
git show e97ded4:Tests/TrolleyMCPTests/MCPServerTests.swift
git show e97ded4:Tests/TrolleyMCPTests/OrphanWatchTests.swift
git show e97ded4:Tests/TrolleyMCPTests/PromptQueueTests.swift
```

부분 삭제가 들어간 파일 — 되살릴 때 여기도 같이 봐야 한다:

| 파일 | 뺀 것 |
|---|---|
| `Sources/TrolleyMCP/TrolleyTools.swift` | `take_prompt` 도구, `MCPServer.extraContentKey` 로 붙이던 부가 콘텐츠 |
| `Sources/TrolleyWidget/ActivityPanelController.swift` | `PromptDestination` 열거형과 목적지 세그먼트 컨트롤 |
| `Sources/TrolleyWidget/StatusWidgetController.swift` | 목적지 분기, `promptQueue` 보유와 그 변경 알림 |
| `Sources/TrolleyWidget/PromptSectionState.swift` | 목적지에 따라 갈리던 문구·표시 규칙 |
| `Sources/trolley/ToolHost.swift` | `makeTools(launcher:promptQueue:)` 의 두 번째 인자 |
| `Sources/trolley/Trolley.swift` | `McpCommand` 등록 |
| `Sources/trolley/Setup/SetupCopy.swift` | `mcpTitle`, `mcp(claudeFound:registered:)`, 자세히의 "MCP 등록" 행 |
| `Sources/trolley/Setup/SetupWindowController.swift` | Claude Code 행과 등록 상태 폴링 |

## 남긴 것 — 이게 중요하다

`Sources/TrolleyMCP/` 모듈 자체는 남아 있고, 이름과 달리 **MCP 서버가 아니라 도구
구현**이다. 로컬 모델의 도구 루프가 전부 여기에 의존한다:

- `TrolleyTools.swift` — 도구 본체 (클릭·타이핑·스냅샷·앱 실행…)
- `TrolleyToolRunner.swift` — 로컬 모델의 턴 루프가 도구를 부르는 어댑터
- `ElementRegistry`, `TreeSnapshotter`, `Arguments`, `ToolError`, `JSONValue`, `WikiTools`

모듈 이름이 이제 거짓말이다. 바꾸지 않은 건 자동 업데이트 작업이 같은 파일들을
건드리고 있어서다 — 그쪽이 병합된 뒤에 한 번에 옮기는 게 맞다.

## 되살릴 때

MCP 프로토콜 계층만 되돌리면 된다. 도구 쪽은 그대로 있으므로 `MCPServer` 가 이미
있는 `TrolleyTools` 를 감싸면 끝이다. 다만 되살릴지 판단할 때 이건 알고 있어야 한다:

**`trolley mcp` 는 접근성 권한을 앱과 따로 받는다.** macOS 는 허가를 '실행에 책임 있는
프로세스' 에 귀속시켜서, Claude Code 가 띄운 `trolley mcp` 는 Claude Code 로 취급된다.
실측: Finder 로 연 앱은 trusted 인데 그 옆의 `trolley mcp` 는 같은 바이너리 같은 경로로
not trusted 였다. 그래서 MCP 경로는 앱이 이미 받아 둔 권한을 물려받지 못한다. 이건
되살려도 그대로 남는 문제다.
