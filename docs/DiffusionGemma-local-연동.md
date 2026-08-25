# DiffusionGemma-local 연동 메모

같은 워크스페이스의 자매 프로젝트 `../DiffusionGemma-local`에 대해, trolley 쪽에서
알아야 할 것만 적는다. 아직 두 프로젝트는 **연결돼 있지 않다.**

## 저쪽이 무엇인가

Apple Silicon에서 Google DiffusionGemma를 로컬로 돌리는 자체 호스팅 세트업이다.

| | |
| --- | --- |
| 위치 | `/Users/markhub/Desktop/workspace/llm-trolley/DiffusionGemma-local` |
| 원격 | `github.com/minsuRob/DiffusionGemma-local` |
| 모델 | `mlx-community/diffusiongemma-26B-A4B-it-4bit` (26B MoE / 3.8B 활성, 4bit, ~16.5GB) |
| 런타임 | mlx-vlm. **모델이 서버 프로세스 안에 인프로세스로 로드된다** |
| 서버 | FastAPI + uvicorn, `server.py`, 기본 포트 8842 |
| 인증 | 랜덤 토큰 → `session` httpOnly 쿠키 |
| 스트리밍 | SSE (`GET /api/stream/{job_id}`) |

핵심 제약이 하나 있다. **모델 하나, 워커 스레드 하나로 모든 요청이 직렬화된다.**
두 인스턴스를 띄우면 ~34GB라 즉시 OOM이므로 PID 락으로 중복 실행을 막는다.
따라서 에이전트 루프가 모델을 호출하는 동안 다른 요청은 대기한다(큐 상한 8, 초과 시 503).

## 지금 연동이 안 되는 이유

**DiffusionGemma-local에는 툴 콜링이 없다.** 에이전트 루프도, 함수 호출도, MCP
클라이언트도 없다. 모델은 순수하게 텍스트 생성과 이미지 읽기에만 쓰이고, 출력이
동작으로 디스패치되는 경로가 존재하지 않는다.

trolley 쪽은 준비돼 있다 — `trolley mcp`가 MCP 서버로 뜨므로, 상대가 MCP 클라이언트를
말할 수만 있으면 붙는다.

## 붙이려면

두 갈래가 있고 각각 대가가 다르다.

**A. `server.py`에 MCP 클라이언트 + 에이전트 루프를 넣는다.**
`trolley mcp`를 서브프로세스로 띄우고 stdio로 JSON-RPC를 주고받으면 된다. 프로토콜이
얇아서(initialize / tools/list / tools/call) 파이썬 쪽 구현 부담도 작다. 다만
DiffusionGemma가 툴 콜을 안정적으로 생성하도록 프롬프트를 설계해야 하고, 위의
단일 워커 제약 때문에 루프가 도는 동안 채팅 요청이 막힌다.

**B. OpenAI 호환 API를 쓴다.**
저쪽 README에 나와 있듯 `server.py` 대신 `python -m mlx_vlm.server --port 8080`을
띄우면 OpenAI 호환 엔드포인트가 열린다. 기존 툴 콜링 클라이언트를 그대로 쓸 수 있다.
**단 `server.py`와 동시에 띄우면 모델이 두 번 로드되어 즉시 OOM이다.** 웹 UI·추출
파이프라인을 포기하는 셈이므로 트레이드오프가 크다.

어느 쪽이든 trolley 쪽 수정은 필요 없다.

## 붙일 때 알아야 할 trolley 쪽 사실

- **접근성 권한은 trolley 바이너리 자체에, 경로 단위로 부여된다.** 부모 프로세스의
  권한과 무관하므로, 파이썬이 서브프로세스로 띄워도 그 바이너리 경로가 승인돼 있어야
  한다. 설치파일이 `/Applications/trolley.app`에 고정 설치하므로
  `/Applications/trolley.app/Contents/MacOS/trolley`를 승인하고 `check_permissions`로
  확인할 것.
- **stdout은 JSON-RPC 전용이다.** 진단 출력은 전부 stderr로 나간다.
- **한 번에 한 요청만 처리한다.** AX 호출이 동기라 의도적으로 직렬이다. 즉 양쪽 모두
  직렬이므로, 에이전트 루프의 지연은 두 병목의 합이다.
- **텍스트 입력은 `type_text`의 `method`를 이해해야 한다.** 기본 `paste`가 한글·이모지를
  모두 처리한다. `keys`는 ASCII 전용이며 입력원을 잠시 바꾼다. `unicode`는 이 머신에서
  전달되지 않는다(README의 실측 참고).
- **`verification: "unverifiable"`은 성공이 아니라 모름이다.** Chromium·리치텍스트 뷰가
  값을 보고하지 않아 흔히 나온다. 모델에게 이걸 성공으로 해석하지 말라고 알려야 한다.

## 반대 방향

DiffusionGemma-local 쪽에서 필요한 정보는 그 저장소의 `docs/trolley-연동.md`에 있다.
