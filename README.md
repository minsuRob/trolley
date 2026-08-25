# trolley

macOS 접근성 API(AXUIElement 트리)를 이용해 화면 캡처/비전 모델 없이 GUI 앱을 조작하는 Swift CLI.
Claude의 `computer` 툴, OpenAI의 `computer-use-preview`와 같은 개념의 액션(click/type/key/focus/wait)을
좌표+스크린샷 대신 접근성 트리 기반으로 수행한다.

## 빌드

```sh
swift build
swift test
```

## 사용 전 필수 단계: 손쉬운 사용 권한 부여

```sh
swift run trolley check-permissions
```

출력된 실행 파일 경로를 **시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용**에 직접 추가해야 한다.
이 권한은 실행 파일 "경로" 단위로 부여되며, 보안 상 자동으로 켤 수 없다 — 반드시 사용자가 직접 켜야 한다.
경로가 바뀌면(release 빌드 전환 등) 다시 등록해야 한다.

## 커맨드

```sh
# 권한 상태 확인
swift run trolley check-permissions [--prompt]

# 실행 중인 앱의 접근성 트리 덤프 (매칭 로직을 맞추기 위한 디버그 도구)
swift run trolley dump-tree --bundle-id notion.id --max-depth 25 [--output path]

# Notion에서 "제목1" 아래에 "본문1" 입력하는 데모 시나리오
swift run trolley run notion-heading --heading "제목1" --body "본문1" [--dry-run] [--verify] [--create-if-missing]

# MCP 서버 모드 (아래 참고)
swift run trolley mcp
```

## MCP 서버 모드

`trolley mcp`는 stdio로 JSON-RPC 2.0(MCP)을 말하는 서버로, Claude Code·Claude Desktop 등
MCP 클라이언트가 trolley의 AX 원시 동작을 직접 호출할 수 있게 한다. CLI의 산문 출력을 파싱할
필요가 없고, 프로세스가 살아 있는 동안 요소 참조를 `e1`, `e2` 같은 **안정적인 ID로 유지**한다 —
매 호출마다 앱 루트부터 텍스트로 재탐색하는 CLI의 콜드 스타트 문제가 사라진다.

### 연결

```sh
swift build -c release
cp .build/release/trolley ~/bin/trolley     # 권한은 경로 단위이므로 안정된 경로에 설치
~/bin/trolley check-permissions --prompt    # 시스템 설정에서 이 경로를 승인
claude mcp add trolley -- ~/bin/trolley mcp
```

접근성 권한은 **trolley 바이너리 자체**에 부여된다. Claude Code의 자식 프로세스로 실행돼도
부모의 권한과는 무관하며, 재빌드로 바이너리가 바뀌면 다시 승인해야 할 수 있다.

### 툴

| 툴 | 설명 |
| --- | --- |
| `check_permissions` | 손쉬운 사용 권한 상태와 승인해야 할 실행 파일 경로 |
| `list_apps` / `launch_app` | 실행 중인 앱 목록 / 실행·활성화 |
| `snapshot` | AX 트리를 LLM이 읽기 좋은 JSON으로. 노드마다 ID 부여 |
| `find_elements` | 텍스트·역할로 요소 검색(구체적인 것 우선). 역할만으로도 검색 가능 |
| `click` / `focus` | AXPress(실패 시 마우스 폴백) / 포커스 |
| `type_text` | 텍스트 입력(한글·이모지 포함). 기본은 붙여넣기, `method=keys`는 실제 키 입력 |
| `press_key` | 단축키. 문자·숫자·F키 포함 (`cmd+n` 등) |
| `set_ax_value` | AXValue 직접 쓰기 + readback 확인 |
| `wait_for_element` | 요소가 나타날 때까지 폴링 (sleep 추정 대체) |
| `screenshot` | 메인 디스플레이(또는 영역)를 JPEG 이미지 블록으로 반환. 픽셀→포인트 변환 정보 포함 |
| `click_at` | 전역 포인트 좌표로 부드럽게 이동 후 클릭 (커서 애니메이션) |
| `move_mouse` | 클릭 없이 부드럽게 이동만 (호버 상태용) |

### 상태 위젯 ("폴더 펫")

`trolley mcp`를 GUI 세션에서 실행하면 항상-위 플로팅 위젯(폴더 아이콘)이 화면
우하단에 뜬다. Codex Pet처럼 도구 활동을 반영하는 작은 동반자다.

- **대기**: 폴더 아이콘 그대로
- **툴 호출 실행 중**: 바운스 + 회전하는 점선 링, 툴팁에 실행 중인 툴 이름
- **완료**: ✅ 팝인 후 2.5초 뒤 페이드 (실패는 ❌)
- **클릭**: 활동 패널 토글 — 세션 통계(호출 수·에러 수·가동 시간), 권한 상태
  (AX/화면 기록), 최근 호출 8건(시각·성공 여부·소요 시간, 실패는 빨강)
- **드래그**: 위치 이동(재시작 후에도 기억), **우클릭**: 위젯 숨기기

`--no-widget`으로 끌 수 있고, SSH처럼 WindowServer 세션이 없으면 자동으로
헤드리스로 폴백한다. 위젯은 비활성 패널이라 **자동화 대상 앱의 포커스를 절대
뺏지 않으며**, trolley 자신의 `screenshot` 툴에는 **찍히지 않는다**(자기 창
제외) — 항상-위 위젯이 비전 루프를 오염시키지 않게 하기 위해서다.

### 하이브리드 워크플로: AX가 막히면 스크린샷으로

Chromium/Electron 웹 콘텐츠는 `thorough=true`로도 AX 트리가 열리지 않는 경우가 있다.
그 지점부터는 **스크린샷+비전**으로 전환한다: `screenshot`이 화면을 이미지 블록으로
돌려주면, 비전을 가진 MCP 클라이언트(Claude 등)가 눈으로 보고 `click_at`으로 좌표를
클릭한다. `snapshot`이 빈 트리를 돌려줄 때와 `ELEMENT_NOT_FOUND` 에러의 hint가 이
전환을 직접 안내한다.

좌표 계약: AX 프레임과 `click_at`은 모두 전역 화면 **포인트**(좌상단 원점)를 쓴다.
스크린샷은 기본적으로 1 이미지픽셀 = 1 포인트로 정규화되며(`pointsPerPixel: 1.0`),
`maxWidth`로 더 줄이면 비율이 올라가므로 응답의 `pointsPerPixel`과 `capturedRegion`으로
환산한다 — 공식은 툴 description에 있다.

모든 마우스 동작(`click_at`, `move_mouse`, AXPress 실패 시 폴백 클릭)은 순간이동이
아니라 **이지징 곡선으로 미끄러진다**(거리에 따라 0.15~0.6초, 60fps `.mouseMoved`
이벤트). 지켜보는 사람이 자동화가 뭘 하는지 눈으로 따라갈 수 있고, 호버 상태를 읽는
앱에도 자연스러운 이벤트 흐름이 전달된다.

`screenshot`은 **화면 기록 권한**이 필요하다(손쉬운 사용과 별개, 같은 바이너리 경로에
부여). 손쉬운 사용과 달리 부여 후 **trolley를 재시작해야** 적용된다.
`check-permissions`가 두 권한을 함께 보고하며, 화면 기록이 없어도 AX 툴은 전부
동작한다.

### 설계상 지켜지는 것

- **조용한 실패가 없다.** `snapshot`은 노드 예산에 걸리면 `truncated`를 함께 보고하고,
  `set_ax_value`는 쓰기 성공 여부와 별개로 readback을 돌려주며, `type_text`는 입력 후
  요소를 다시 읽어 `containsTypedText`로 실제 반영 여부를 알린다. 모르는 키 이름은
  아무것도 보내지 않고 `UNKNOWN_KEY`로 거절한다.
- **에러가 구조화돼 있다.** `NOT_TRUSTED`, `APP_NOT_RUNNING`, `ELEMENT_NOT_FOUND`,
  `ELEMENT_STALE`, `UNKNOWN_KEY`, `TIMEOUT` 등으로 구분되고 각각 다음 행동을 안내한다.
- **Chromium/Electron 대응은 명시적 선택이다.** `thorough=true`를 주면
  `AXManualAccessibility`를 설정하고 지연 로딩을 기다리며 잘린 children 배열을 재시도한다.
  네이티브 앱에서는 이 비용(노드당 40~80ms)이 낭비이므로 기본값은 빠른 경로다.

### 텍스트 입력 방식

`type_text`의 `method`는 셋 중 하나다.

- **`paste`(기본)** — 클립보드에 넣고 `cmd+V`, 그다음 클립보드를 원래대로 되돌린다.
  한글·이모지 등 모든 유니코드를 실어 나르고 Chromium/Electron에서도 동작한다.
  실측: TextEdit에 `hello 안녕 🎉` 입력 확인, Chrome 주소창에 한글 입력 확인,
  두 경우 모두 기존 클립보드 보존됨.
- **`keys`** — 키코드로 한 글자씩 실제 타이핑. ASCII 전용이며 입력원을 잠시
  ASCII 레이아웃(ABC)으로 바꿨다가 되돌린다. 붙여넣기를 무시하고 키 입력에만 반응하는
  필드에 쓴다. 한글은 `UNSUPPORTED_TEXT`로 거절하며 `paste`를 안내한다.
- **`unicode`** — 예전의 CGEvent 유니코드 주입. **이 머신에서는 전달되지 않는다.**
  이벤트 소스(`hidSystemState`/nil) × 탭(`cghidEventTap`/`cgSessionEventTap`/`postToPid`) ×
  입력원(한글 2벌식/ABC) 모든 조합에서 대상의 AXValue가 그대로였다. 같은 바이너리에서
  키코드 입력은 정상 동작했다. 다른 환경에서 재확인할 수 있도록 남겨둔 진단용이며
  자동으로 선택되지 않는다.

**폴백 체인은 일부러 없다.** 두 번째 시도가 안전하려면 첫 시도가 실패했음이 *증명*돼야
하는데, 폴백이 가장 필요한 뷰(Chromium·리치텍스트)가 바로 그 증명이 불가능한 뷰다.
따라서 한 가지 방식만 실행하고, 결과는 아는 것만 말한다.

`verification` 값: `confirmed`(값에서 확인됨) / `provablyFailed`(값이 전혀 안 바뀜 —
확실한 실패) / `unverifiable`(요소가 값을 보고하지 않음 — **성공이 아니라 모름**) /
`changedUnexpectedly`(값은 바뀌었으나 요청한 텍스트가 아님 — IME 조합 중이거나 필드가
재포맷. 실제로 TextEdit이 `hello`를 `Hello`로 자동 대문자화한 경우가 이렇게 잡혔다).

### 타이밍에 관한 실측

입력은 대상 앱의 런루프에서 **나중에** 처리된다. 고정 대기로는 성공을 실패로 오판했다.

- 붙여넣기 후 0.5초 뒤 값을 읽었더니 비어 있어 `provablyFailed`로 보고했지만, 실제로는
  그 뒤에 반영됐다(다음 호출이 이전 호출의 텍스트를 보게 됐다). 그래서 지금은 고정 대기
  대신 값이 바뀔 때까지 폴링한다(`verifyTimeoutSeconds`, 기본 2초).
- `keys`에서 타이핑 직후 입력원을 되돌렸더니 남은 키가 복원된 IME에 재해석돼
  `trolley keys test`가 `trolley keys tesㅅ`로 들어갔다. 지금은 글자 수에 비례한 시간만큼
  큐가 비워지길 기다린 뒤 되돌린다.

### 그 밖의 한계

- 클립보드 복원은 최선 노력이다. 지연(promise) 데이터와 펴이스트보드 소유권은 보존되지
  않고, 내용이 매우 크면(~10MB 초과) 복원하지 않고 그 사실을 보고한다. 복원 직전에 다른
  앱이 클립보드를 가져갔으면 덮어쓰지 않는다.
- 시스템 전역 보안 입력(암호 필드 포커스)이 켜져 있으면 어떤 합성 키 입력도 통하지 않는다.
  실패 시 이를 감지해 안내한다.
- 웹/Electron 콘텐츠는 `thorough=true`로도 트리가 열리지 않는 경우가 있다. 이 영역은
  AX 방식의 구조적 한계이며 스크린샷·비전 방식이 유리하다.
