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

### 설치

`trolley-<버전>.dmg`를 열고 **trolley를 Applications로 끌어다 놓는다.** 관리자 암호는
필요 없다 — `/Applications`는 admin 그룹이 쓸 수 있다.

그다음 앱을 실행하면 **폴더 펫이 화면에 뜨고 계속 떠 있는다.** 손볼 게 남아 있으면 설정
창이 함께 열린다 — 준비돼야 할 것들을 상태와 함께 보여주고, 각각 옆의 버튼이 그 자리에서
처리한다. 터미널로 할 일은 없다.

창은 다 초록이 되면 스스로 닫히고 펫만 남는다. 다시 열려면 **펫을 우클릭 → 설정 열기**,
또는 Finder 에서 앱을 다시 열면 된다(Dock 아이콘이 없다). 터미널에서는 `trolley setup`.

| 항목 | 창이 하는 일 |
| --- | --- |
| 설치 위치 | 디스크 이미지나 다른 폴더에서 실행 중이면 경고하고 **Applications로 옮긴 뒤 다시 연다** |
| 손쉬운 사용 | 시스템 프롬프트를 띄우고 해당 설정 화면을 연다 |
| 화면 기록 | 같은 방식. `screenshot` 툴에만 필요하다 |
| Claude Code 연결 | `claude mcp add`를 앱이 직접 실행한다. `claude`를 못 찾으면 명령을 복사해준다 |

권한은 시스템 설정에서 켜지므로 창이 1.5초마다 다시 확인해 상태를 갱신한다.
터미널에서 같은 창을 열려면 `trolley setup`.

**설치 위치를 가장 먼저 확인하는 이유.** 디스크 이미지에서 그대로 실행하면 경로가
`/Volumes/...`가 되는데, 접근성·화면 기록 권한(TCC)도 MCP 등록도 모두 그 경로에 걸린다.
이미지를 꺼내는 순간 전부 무효가 된다.

**CLI인데 왜 앱 번들인가.** 셋 다 이유가 있다.

- TCC는 **실행 파일의 절대 경로**에 걸린다. `/Applications`에 놓인 번들은 그 경로가
  고정이고, 시스템 설정에도 맨 경로 대신 이름과 아이콘으로 뜬다.
- `/Applications`는 `drwxrwxr-x root:admin`이라 설치도, 이후 `trolley update`도 암호 없이
  끝난다. 원자적 교체에는 파일이 아니라 그 **디렉터리** 쓰기 권한이 필요하다.
- flat 패키지(`.pkg`)는 Developer ID **Installer** 인증서 없이는 서명할 수 없고, macOS는
  미서명 pkg를 열어주지 않는다. 번들과 디스크 이미지는 가지고 있는 Application 인증서로
  서명된다.

`trolley`를 터미널에서 이름만으로 부르고 싶으면 링크를 하나 걸면 된다. 링크를 타도
`_NSGetExecutablePath` + `realpath`로 실제 경로를 보고하므로 TCC 안내가 어긋나지 않는다.

```sh
sudo ln -sf /Applications/trolley.app/Contents/MacOS/trolley /usr/local/bin/trolley
```

### 업데이트

```sh
trolley update           # 최신 릴리스로 교체
trolley update --check   # 확인만
```

경로와 서명 신원이 둘 다 고정이므로 **권한을 다시 줄 필요가 없다.** 실행 위치를 보고
번들이면 번들 통째로, 맨 실행 파일이면 그 파일만 교체한다. 번들 안의 실행 파일만 갈아끼우는
길은 없다 — 실행 파일의 code directory가 `Info.plist`를 해시하므로, 번들 밖에서 서명된
바이너리는 어느 번들에도 맞지 않는다.

교체는 옆에 받아 서명(팀 `46LU76SNUA`)을 검증한 뒤 `renamex_np(RENAME_SWAP)`으로 맞바꾼다.
원자적이라 중간에 죽어도 경로가 비지 않고, 덮어쓰기가 아니라서 커널이 캐시한 코드 서명과
어긋나 `Killed: 9`로 죽는 일도 없다. 이미 실행 중인 `trolley mcp`는 재시작해야 새 버전이 된다.

접근성 권한은 **trolley 실행 파일 자체**에 부여된다. Claude Code의 자식 프로세스로 실행돼도
부모의 권한과는 무관하다.

### 설치파일 만들기 (개발자용)

```sh
./Scripts/build-installer.sh
```

유니버설(arm64 + x86_64) 릴리스를 빌드해 앱 번들로 조립하고, Developer ID Application으로
서명·공증한 뒤 `dist/`에 둘을 만든다.

| 산출물 | 용도 |
| --- | --- |
| `trolley-<버전>.dmg` | 배포용. `trolley.app` + `/Applications` 별칭, 창 배치와 볼륨 아이콘 포함 |
| `trolley-app.zip` | `trolley update` 가 받아가는 서명된 번들 |

아이콘은 **위젯이 그리는 폴더 그림에서 빌드 때 렌더링한다**(`trolley export-icon` →
`iconutil`). 체크인된 아트가 아니라서 아이콘과 폴더 펫이 갈라질 수 없다.

dmg 창 배치(아이콘 위치, 창 크기)는 볼륨의 `.DS_Store`에 들어가고 그건 Finder만 쓸 수
있어서 AppleScript로 시킨다. Finder 자동화 권한이 없으면 배치를 건너뛰고 기능은 그대로인
이미지를 낸다. **볼륨 아이콘은 반드시 배치 다음에 넣는다** — Finder가 창을 만지는 동안
`.VolumeIcon.icns`를 지워버려서, 먼저 넣으면 조용히 사라진다.

서명 자산은 MAKi 데스크톱 릴리스가 쓰는 것과 같은 SSM 파라미터
(`/front/master/MAC_*`, `/front/master/APPLE_*`)에서 가져온다.
`TROLLEY_CERT_PEM` / `TROLLEY_KEY_PEM`으로 직접 지정할 수도 있다. 서명은 임시 키체인에서
이뤄지고 **EXIT 트랩으로 반드시 복원**된다 — 키체인 검색 목록과 기본 키체인을 건드렸다가
복원에 실패하면 죽은 키체인이 쌓이고, 그러면 이후 모든 `codesign`이 암호 대화상자를 띄운다.

**pkg 를 포기한 이유.** 셋 다 실측했다. `productsign`은 Application 인증서를 거절하고
(`An installer signing identity ... is required for signing flat-style products`),
미서명 pkg는 공증이 `Invalid`, 서명된 dmg 안에 넣어도 `Invalid`다. Developer ID Installer
인증서를 발급하면 pkg 경로를 되살릴 수 있다.

**스테이플이 실패해도 배포는 된다.** 이 개발 머신에서는 지금 항상 실패한다
(`Could not validate ticket`, Error 65). 전파 지연이 아니다 — `stapler -v`가 티켓을
**정상적으로 내려받고**(레코드 `2/2/<cdhash>`, `recordType = DeveloperIDTicket`) 그 다음
검증에서 넘어진다. 우리 산출물 문제도 아니다: **이미 공증된 제3자 앱
(`/Applications/Maccy.app`)을 복사해 스테이플을 떼고 다시 붙여도 똑같이 Error 65**가 난다.
Xcode 26.4를 macOS 26.3 위에서 쓰는 조합으로 보인다. 툴체인이나 OS가 올라간 뒤 다시 시도할 것:

```sh
xcrun stapler staple dist/trolley-<버전>.dmg
```

스테이플이 없으면 Gatekeeper가 **온라인으로** 공증을 확인하므로, 인터넷이 있는 맥에서는
그대로 설치된다. 오프라인 첫 실행에서만 문제가 된다.

### 종료

정상 경로는 stdin EOF다 — 클라이언트가 파이프를 닫으면 서버도 끝난다. 다만 클라이언트가
파이프의 쓰기 끝을 남긴 채 죽으면 EOF가 영영 오지 않아 서버가 유령처럼 남는다. 그래서 5초마다
부모 프로세스를 확인해, **launchd로 재부모화됐으면(PPID 1) 스스로 종료**한다. 처음부터 launchd가
띄운 서버는 대상이 아니다. 위젯 모드에서는 우클릭 → 위젯 종료로 직접 끌 수도 있다.

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
| `take_prompt` | 위젯 프롬프트 상자에 사용자가 넣어둔 말을 오래된 것부터 꺼내고 큐를 비움 (위젯 모드에서만 노출) |

### 상태 위젯 ("폴더 펫")

**앱을 켜면** 항상-위 플로팅 위젯(폴더 아이콘)이 화면 우하단에 떠서 계속 머문다.
Codex Pet처럼 도구 활동을 반영하는 작은 동반자다.

위젯은 **앱이 소유한다.** 예전에는 `trolley mcp` 프로세스 안에 살아서 클라이언트가 붙어
있는 동안에만 존재했다 — 그냥 켜두면 아무것도 안 뜨고, `claude mcp list`가 헬스체크로
서버를 띄웠다 닫을 때마다 2초쯤 보였다 사라졌다. 지금은 서버가 앱이 떠 있는지 보고, 떠
있으면 자기 위젯을 만들지 않고 **툴 호출을 분산 알림으로 넘긴다**(`ActivityBridge`).
앱이 없으면 예전처럼 서버가 직접 띄운다.

- **대기**: 폴더 아이콘 그대로
- **툴 호출 실행 중**: 바운스 + 회전하는 점선 링, 툴팁에 실행 중인 툴 이름
- **완료**: ✅ 팝인 후 2.5초 뒤 페이드 (실패는 ❌)
- **클릭**: 활동 패널 토글 — 세션 통계(호출 수·실패 수·가동 시간), 권한 상태
  (AX/화면 기록 점등), 최근 호출 8건(시각·성공 여부·툴 이름·소요 시간, 실패는
  빨강), 그리고 **프롬프트 상자**
- **드래그**: 위치 이동(재시작 후에도 기억)
- **우클릭**: PID 표시 + **설정 열기** + **위젯 종료**. 숨기기는 없다(숨기면 되살릴
  수단이 없어 보이지 않는 프로세스만 남으므로).

#### 프롬프트 상자: 실행 중인 에이전트에게 말 걸기

패널 아래쪽 입력란에 쓰고 ⏎ 를 누르면 그 텍스트가 **대기열**에 들어가고,
에이전트가 `take_prompt`로 가져간다. stdio MCP 서버는 클라이언트에게 먼저 말을
걸 수 없기 때문에(요청은 항상 클라이언트가 시작한다) 위젯이 직접 보내는 게 아니라
맡겨두는 방식이다. 대기 중인 프롬프트가 있으면 **다른 모든 툴 결과에
`userPromptWaiting` 필드가 붙어** 에이전트가 다음 호출에서 알아차린다 — 작업
중간에 끼어들 수 있는 지점이 그것뿐이다.

- 전달은 **정확히 한 번**이다. `take_prompt`가 큐를 비우므로 결과를 버리면 사라진다.
- 공백만 있는 입력은 큐에 들어가지 않고, 20건을 넘기면 가장 오래된 것부터 버린다
  (아무도 안 가져가는 중이면 최신 지시가 더 쓸모 있으므로).
- 패널은 대기 중인 프롬프트를 최대 3건까지 미리 보여주고, 에이전트가 가져가는
  순간 목록에서 사라진다.
- **포커스**: 상자를 클릭하는 순간에만 trolley가 포커스를 가져온다(맥OS는 키
  입력을 활성 앱에만 보내므로 이게 없으면 타이핑이 앞의 앱으로 새어 나간다).
  ⏎ 로 넣거나 esc 로 닫으면 곧바로 원래 앱에 포커스를 돌려준다. 그 외에는 위젯이
  포커스를 건드리지 않는다.
- ⌘C/⌘V/⌘X/⌘A가 동작한다. 메뉴 막대가 없는 액세서리 앱이라 단축키를 라우팅할
  최소 편집 메뉴를 따로 심어뒀다 — 없으면 붙여넣기가 조용히 무시된다.

떠 있는 동안에는 항상 보인다. 디스플레이를 뽑아 위젯이 화면 밖으로 밀리면 다음
화면 구성 변경에서 기본 위치로 되돌아온다.

`--no-widget`으로 끌 수 있고, SSH처럼 WindowServer 세션이 없으면 자동으로
헤드리스로 폴백한다. 위젯은 비활성 패널이라 **자동화 대상 앱의 포커스를
뺏지 않으며**(예외는 위의 프롬프트 상자 클릭뿐), trolley 자신의 `screenshot` 툴에는 **찍히지 않는다**(자기 창
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
