# 작업 지시 — trolley 자동 업데이트

이 파일을 읽는 세션이 할 일 전부가 여기 있다. 다른 대화의 맥락은 필요 없다.

여기 적힌 숫자와 경로는 전부 직접 측정한 것이다. 추측은 "정해 주세요" 절로 뺐다.
믿기지 않으면 다시 재 보라 — 재는 방법도 같이 적어 뒀다.

## 가장 먼저 — 격리 규칙

**당신은 `/Users/markhub/workspace/llm-trolley/trolley-autoupdate` 에서만 작업한다.**
지금 이 워크트리는 `develop` 브랜치에 있다. `develop` 이 기본 브랜치다 — `main` 은
없앴고, `feat/auto-update` 와 `feat/mcp-server-and-text-entry` 는 둘 다 `develop` 에
병합돼 있다.

- `/Users/markhub/workspace/llm-trolley/trolley` 은 **건드리지 마라.** 옆 세션의 작업은
  끝나서 병합됐지만(`8f325f7`), 그 워크트리는 여전히 그쪽 것이다.
- `git reset --hard`, `git clean` 을 쓰지 마라. 직전에 정확히 이 조합으로 옆 세션의
  미커밋 작업을 날린 사고가 있었다. 격리돼 있다고 *믿고* 실행한 것이 원인이었다.
  의심되면 `git worktree list` 로 확인하고, 그래도 애매하면 사람에게 물어라.
- `/Users/markhub/Desktop/workspace/MAKi` 는 **읽기 전용.** `.gitignore` 포함 무엇도 쓰지 마라.
- `/Applications` 에 설치하지 마라.
- `Scripts/build-installer.sh` 는 **사람의 허락을 받고만** 돌려라. 전역 키체인 검색 목록과
  기본 키체인을 바꾼다 — `signing-keychain.sh` 주석에 그것 때문에 죽은 키체인 ~70개가
  쌓이고 기본 키체인이 삭제된 워크트리를 가리키게 된 사고가 적혀 있다. 로컬 검증만
  필요하면 `--skip-notarize` 로 충분하다 (`verifySignature` 는 팀 핀만 본다).
- 푸시는 사람이 시킬 때만 한다.

## 배경

trolley 는 SwiftPM 으로 만든 macOS 메뉴 막대 앱이다. 로컬 LLM(DiffusionGemma-local)이 도구를
불러 맥을 조작한다. 배포는 서명·공증된 `.dmg` 와, 업데이트용 `trolley-app.zip` 이다.

`Package.swift` 는 `swift-tools-version: 6.0` 이지만 **모든 타깃이
`.swiftLanguageMode(.v5)`** 로 고정돼 있다. 엄격 동시성은 안 걸려 있다. actor 나 `Sendable`
로 감싸서 해결하려 들지 마라 — 이 저장소는 동시성을 컴파일러가 아니라 관례로 지킨다.
그 관례는 "만들 것 3" 에 적어 뒀다.

**업데이트 엔진의 절반은 이미 있다. 나머지 절반과 배포 파이프라인이 없다.**

### 손대지 말 것 (그대로 재사용)

- `Sources/TrolleyKit/Update/SelfUpdate.swift` 의 `SemanticVersion`(숫자 비교),
  `ReleaseInfo`, `UpdateDecision.decide`
- `Sources/TrolleyKit/Update/UpdateInstaller.swift` 의 살아 있는 규칙들:
  - `extract` 는 `unzip` 이 아니라 `ditto` — 번들의 서명이 확장 속성에 실려 있어 unzip 이면 깨진다
  - `verifySignature` 는 Developer ID 팀 `46LU76SNUA` 에 `codesign -R` 로 핀 고정.
    **보안 경계다. 손대지 마라.**
  - `replace` 는 `renamex_np(RENAME_SWAP)` — 원자적, 경로가 비는 순간이 없다
  - 스테이징 경로는 언제나 타깃의 형제다 (`rename(2)` 가 한 파일시스템을 요구한다)
  - 실패하면 받다 만 것을 지우고 설치본은 건드리지 않는다
- `Sources/TrolleyKit/Update/InstallLayout.swift` — 앱 번들 / 맨 바이너리 판별

### 고쳐야 할 것 (허가된 수술 범위)

브리프의 이전 판은 "엔진은 이미 다 있다, 재사용만 하라"고 적었다. **그건 틀렸다.**
아래 요구를 만족시키려면 시그니처를 뜯어야 한다. 뜯어도 되는 곳은 여기까지다:

| 파일 | 무엇을 | 왜 |
|---|---|---|
| `UpdateInstaller.swift:36` | 파서 호출부와 `assetName` 파라미터 | 매니페스트 형식이 바뀐다 (A1, A2) |
| `UpdateInstaller.swift` `install` | stage / commit 으로 분리 | "받아 두고 나중에 설치" 정책 (A4) |
| `UpdateInstaller.swift` 주입 목록 | `verifyChecksum` 추가 | sha256 을 끼울 자리가 없다 (A3) |
| `SelfUpdate.swift` `UpdateError` | `.checksumMismatch` 추가 | 기존 케이스로 대신하면 거짓말이 된다 |
| `SelfUpdate.swift` `GitHubRelease` | 삭제, `ReleaseManifest` 로 교체 | GitHub 을 더는 안 쓴다 |
| `Version.swift` `releaseFeed` | 새 URL + 환경변수 오버라이드 | 배포처 이전, 리허설 (A7) |
| `UpdateCommand.swift` | 새 시그니처에 맞춤 | 안 고치면 컴파일이 깨진다 |
| `MenuBarController.swift` / `MenuBarMenu` | 항목 하나 + 상태 반영 | 설치를 누를 곳이 필요하다 (A5) |

이 표에 없는 파일은 건드리지 마라.

## 확인된 사실 (직접 측정된 것들)

**1. 지금 피드는 죽어 있다.** `https://api.github.com/repos/minsuRob/trolley/releases/latest`
→ **HTTP 404**. 저장소는 공개(200)인데 릴리스도 태그도 0개고(`git tag` → 0줄),
`build-installer.sh` 에 업로드 단계가 없다. `trolley update` 는 한 번도 성공한 적이 없다.

직접 돌려 본 결과다. 세 번 연달아, 매번 같다:

```
$ swift build && ./.build/debug/trolley update --check
설치 위치: .../.build/arm64-apple-macosx/debug/trolley
현재 버전: 0.1.0
Error: 공개된 릴리스가 아직 없습니다.
$ echo $?
1
```

**여기서 만들 것 6 의 근거가 나온다.** "릴리스 없음" 이 지금은 `Error:` 에 종료코드 1 로
나온다 — 요구하는 "차분한 정상 상태"의 정반대다. 고친 뒤 이 명령이 종료코드 0 으로
차분하게 끝나는지가 그대로 확인 방법이 된다.

(레이아웃 판별은 잘 돈다: `.build/.../debug/trolley` 를 `bareBinary` 로 맞게 집었다.)

**2. 배포 위치는 MAKi 인프라를 재사용한다.** 같은 사용자의 다른 제품이 이미 라이브 피드를
돌린다. 규약 참고용으로 읽어라 (읽기만):

- `/Users/markhub/Desktop/workspace/MAKi/apps/front/electron/scripts/electron-update-channel.js`
  — 피드 URL 모양: `https://maki.ink/updates/electron/<mac|win>/<channel>/latest`
- `.../scripts/publish-mac-release.js` — `<version>/` 과 `latest/` 를 스테이징한 뒤 env 로 고른
  대상에 보낸다: 로컬 디렉터리 / S3 sync / rsync-over-ssh
- `/Users/markhub/Desktop/workspace/MAKi/docs/github-actions-cicd.md` (200~310행) — 권장 대상은
  `<repo>/apps/server/public/updates/electron`, 정적 서빙, `maki.ink` 가 그 오리진

trolley 는 `https://maki.ink/updates/trolley/mac/latest/` 를 쓴다. **단일 채널** — master/staging
로 나누지 마라. MAKi 코드 주석에 브랜치/채널 불일치로 설치본이 영영 업데이트를 못 받은 실제
사고가 기록돼 있다. 사용자가 한 명인 지금 그 위험을 살 이유가 없다.

**베끼지 말 것 하나.** `publish-mac-release.js` 의 `copyDirContents` 는 복사 전에
`fs.rmSync(targetDir, { recursive: true, force: true })` 로 **타깃을 통째로 지운다.**
사실 4와 합치면 이 패턴은 살아 있는 피드를 지우는 총구다. 아래 "만들 것 2" 를 보라.

**3. 없는 파일을 요청하면 404 가 아니라 200 + HTML 이 온다.** 재측정:

```
$ curl -sIL https://maki.ink/updates/trolley/mac/latest/manifest.json
→ 301 → https://app.markhub.ai/updates/trolley/mac/latest/manifest.json
→ 200  content-type: text/html; charset=utf-8   34,790 bytes
   본문: <!DOCTYPE html><html  lang="ko"> ... Expo SPA 셸
```

`/updates/` 아래 없는 경로는 전부 이렇다. `LiveUpdateIO.send()` 는 404 만 `.noRelease` 로
매핑하므로(`UpdateInstaller.swift:200`) **이 호스트에서 그 분기는 죽은 코드다.**
첫 배포 전에는 "릴리스 없음" 대신 "JSON 이 아닙니다" 오류가 뜬다.

(대조군: `https://maki.ink/updates/electron/mac/master/latest/latest-mac.yml` 은 리다이렉트
없이 `200 application/octet-stream`, 509 bytes 로 잘 나온다. 즉 정상 배포된 경로는 멀쩡하다.)

**4. 이 맥이 라이브 오리진이다.** 로컬
`apps/server/public/updates/electron/mac/master/latest/latest-mac.yml`(509바이트, `version: 1.2.23`)
과 실제 서비스 URL 응답이 **바이트 단위로 같다.** 로컬 디렉터리에 복사하는 순간 그게 프로덕션
배포다. 스크립트에 반드시 속도 방지턱을 둬라.

**5. 앱은 자식 프로세스를 갖지 않는다.** 확인됨 — 교체 후 깔끔한 재실행으로 충분하다.

**6. 지금 테스트는 정확히 405개다** (`grep -rho '^\s*func test[A-Za-z0-9_]*' Tests | wc -l`).
이건 하한이 아니라 오늘의 값이다. 아래 A1 을 보라.

**7. `dist/` 는 지금 없다.** 배포할 zip 자체가 아직 존재하지 않는다.

---

## 만들 것

### 1. 매니페스트와 파서

electron-updater 의 `latest-mac.yml` 은 Swift 에 안 맞는다. 자체 JSON:

```json
{ "version": "0.2.0", "asset": "trolley-app.zip", "sha256": "...", "publishedAt": "..." }
```

- `asset` 은 **피드 URL 기준 상대 경로**로 푼다 — 매니페스트가 호스트를 박아 두지 않게.
  기준 URL 은 `check(feed:)` 가 이미 갖고 있다
- `sha256` 의 대상은 **내려받은 zip 바이트**다. 푼 번들이 아니다
- sha256 검증은 codesign 팀 핀 **대신이 아니라 추가로** 한다
- `TrolleyVersion.releaseFeed` 를 새 URL 로 돌려라

**A1 — `GitHubRelease` 는 재사용이 아니라 교체다.** `tag_name`/`assets[]` 와
`version`/`asset`/`sha256` 은 겹치는 필드가 하나도 없다. `GitHubRelease` 를 지우고
`ReleaseManifest` 를 새로 써라. `Tests/TrolleyKitTests/SelfUpdateTests.swift:33` 의
`GitHubReleaseTests`(테스트 3개)도 같이 지운다 — GitHub 을 안 쓰는데 남길 이유가 없다.
**그래서 405 가 402 로 줄어든다. 그건 정상이다.** 요구는 "405 유지"가 아니라
"새 테스트로 순증할 것"이다.

**A2 — 파서는 주입 시임이 아니다.** `UpdateInstaller.swift:36` 이
`GitHubRelease.parse(data, assetName: assetName)` 를 하드코딩한다. 그 호출부를 고쳐라.
`assetName` 파라미터의 의미도 바뀐다: 지금은 "assets 배열에서 이 이름을 찾아라"인데,
새 매니페스트는 이름을 스스로 들고 온다. `TrolleyVersion.updateAssetName` 은
**배포 스크립트가 쓰는 상수**로 남고, 파서는 매니페스트가 말하는 대로 따른다.

**A3 — sha256 을 끼울 자리가 지금 없다.** `download` 는 디스크에 쓰고 끝이라 바이트가 손에
안 남는다. 주입 클로저를 하나 늘려라 (예: `verifyChecksum: (URL, String) throws -> Void`).
그리고 `UpdateError` 에 `.checksumMismatch` 를 더해라 — `.signatureRejected` 를 재사용하면
사용자에게 서명 문제라고 거짓말하게 된다.

**해시를 언제 하는가**: 이전 판은 "`extract` 전에"라고 적었는데 부정확하다.
`bareBinary` 레이아웃에는 `extract` 가 아예 없다 (`UpdateInstaller.swift:71-72` 는
`download` 만 한다). 정확한 규칙은 → **내려받은 바이트에 대해, 두 레이아웃 모두,
`verifySignature` 보다 먼저.**

**B2 — SPA 셸을 `.noRelease` 로 이어라.** 사실 3 때문에 404 분기는 이 호스트에서 안 돈다.
그러니 "만들 것 6"(`.noRelease` → 차분한 정상 상태)이 의미를 가지려면 셸 감지가 그 분기로
들어가야 한다:

```
SPA 셸 감지 → .noRelease → UpdateStatus.upToDate("아직 배포된 릴리스가 없습니다")
```

**B1 — content-type 가드를 `send()` 에 통으로 넣지 마라.** `send()` 는 `fetch`(JSON 기대)와
`download`(octet-stream 기대)가 **공유한다**. JSON 가드를 거기 박으면 zip 다운로드가 전부
실패한다. 요청별 기대 타입을 넘겨라.

그리고 `send` 는 `private static` 이라 테스트가 안 붙는다. **판정을 순수 함수로 분리해라**
— (content-type, 본문 앞부분) → 판정. 캡처한 셸 HTML 을
`Tests/TrolleyKitTests/Fixtures/` 에 두고 그 순수 함수에 테스트를 붙여 가드가 썩지 않게 하라.

**B3 — `Accept` 헤더가 GitHub 용이다.** `UpdateInstaller.swift:99` 의
`application/vnd.github+json` 은 maki.ink 엔 무의미하다. `application/json` 으로.
`TrolleyVersion.userAgent` 의 "GitHub rejects API requests without one" 주석도 같이 낡는다.

### 2. 배포 스크립트 `Scripts/publish-release.sh`

`build-installer.sh` 와 분리한다 (배포가 서명을 함의하면 안 된다).

**입출력** (이전 판에 없던 것):
- **입력**: `dist/trolley-app.zip`. 스크립트는 이걸 **만들지 않고 있는 걸 쓴다.**
  없으면 무엇을 실행해야 하는지 알려 주고 멈춘다. 사실 7 — 지금은 없다
- **출력**: `$TROLLEY_RELEASE_TARGET_DIR/mac/latest/` 아래 `manifest.json` + `trolley-app.zip`.
  sha256 은 스크립트가 계산해 매니페스트에 박는다

**가드**:
- `TROLLEY_RELEASE_TARGET_DIR` 은 **기본값 없이 필수.** 실수로 배포되는 경로를 만들지 마라
- 해석된 절대 목적지를 출력하고, 쓰기 전에 명시적 `--yes` 를 요구한다 (사실 4)
- **경로가 `updates/trolley` 로 끝나지 않으면 거부한다.** `--yes` 만으로는 부족하다 —
  한 단계 위를 가리키는 오타 하나가 살아 있는 electron 피드에 닿는다
- **`rm -rf` 금지.** 디렉터리를 비우지 말고 파일만 덮어써라 (사실 2의 "베끼지 말 것")
- `-dirty` 빌드는 거부한다. **`git status` 만 보면 부족하다** — 트리가 깨끗해도 zip 은
  옛날 dirty 빌드일 수 있다. `build-installer.sh` 가 `-dirty` 접미사를 `COMMIT` 에 붙여
  `Scripts/app/Info.plist` 의 `TrolleyCommit` 에 박으므로, **zip 안의 `Info.plist` 를 읽어**
  판단하라: `TrolleyCommit` 이 `-dirty` 로 끝나거나 HEAD 와 다르면 거부.
  `CFBundleShortVersionString` 이 `Version.swift`·태그와 셋 다 일치하는지도 본다
- HEAD 에 `v$TrolleyVersion.current` 태그가 없으면 거부한다. **태그를 스크립트가 만들지 마라**
  — 릴리스 판단은 사람 몫이다. 태그가 0개이므로 첫 실행은 반드시 실패한다.
  그 실패 메시지가 쓸모 있게 하라. 예:

  ```
  error: HEAD 에 v0.1.0 태그가 없습니다.
         릴리스로 확정하려면:  git tag -a v0.1.0 -m "trolley 0.1.0"
         그다음 다시:          Scripts/publish-release.sh --yes
  ```
- `Version.swift` 의 `0.1.0` 을 올리지 마라

### 3. 앱 안의 주기적 확인

실행 시 + 6시간마다 `check(...)`.

**메인 스레드 밖에서** 돌려라 — `LiveUpdateIO.send` 는 세마포어로 블록하고(`UpdateInstaller.swift`
의 `send`), 커밋 `e97ded4`("패널을 얼리던 데드락을 걷어낸다")가 메인 스레드를 얼린 사고의 기록이다.

**단, 상태 콜백은 메인으로 되돌려라.** `MenuBarController` 주석이 "main-thread only, by
convention rather than `@MainActor`" 라고 못박고 있고 위젯 컨트롤러들도 같은 관례다.
언어 모드가 v5 라 컴파일러는 이걸 안 잡아 준다 — 사람이 지켜야 한다.

타이머는 `WelcomeFlow` 의 다른 static 들처럼 프로세스 수명만큼 잡아 둬라. 맥이 잠들었다
깨면 `Timer` 는 밀린 발화를 몰아 쏘지 않고 한 번만 쏜다 — 그 동작으로 충분하다.

### 4. 새 버전이 있으면 백그라운드 다운로드

기본 정책: **자동 확인 + 자동 다운로드, 설치는 사용자가 누를 때.** 정책은 이름 붙은
상수/enum 하나로 두어 나중에 완전 무인으로 옮길 때 수술이 필요 없게 하라.
그 enum 이 덮어야 할 축은 넷이다: 자동 확인 / 자동 다운로드 / 자동 설치 / 자동 재실행.

**A4 — 지금 `install()` 은 한 호출로 교체까지 간다.** 이 정책은 둘로 쪼개야 성립한다:
받아서 sha256·서명 검증까지 하고 멈추는 단계와, `replace` 하는 단계. 이름은 알아서 정해라.

쪼개면 검증까지 끝난 `.trolley.app.update` 가 `/Applications` 에 남는다.
그 수명은 사람이 정한다 — "정해 주세요" 1번.

### 5. 상태만 노출하고 뷰는 만들지 마라

`UpdateStatus`(`.upToDate / .checking / .available(version) / .downloaded(version) / .failed(String)`)
를 `TrolleyKit` 에 두고 `WelcomeFlow.run()` 에서만 배선하라.

**이 금지는 풀렸다.** 이전 판은 옆 세션이 `StatusWidgetController.swift` 와
`ActivityPanelController.swift` 를 크게 뜯는 중이라 손대지 말라고 적었다. 그 작업은
`8f325f7`("MCP 를 걷어내고 도구만 남긴다")로 끝나 `develop` 에 병합됐다 — `PromptQueue`
는 아예 삭제됐고 두 파일은 지금 안정 상태다. 충돌 걱정으로 피할 이유는 사라졌다.

그래도 **설치 트리거는 여전히 `MenuBarController` 다.** 이유가 바뀌었을 뿐이다:
메뉴 막대는 백그라운드 앱을 찾을 때 사람이 보는 자리이고, `MenuBarMenu.specs` 가
데이터라 윈도우 서버 없이 테스트된다. 위젯 쪽은 필요하면 상태 표시에 써도 된다.

**A5 — 그런데 그러면 설치를 누를 곳이 없다.** 정책은 "사용자가 누를 때"인데 위 금지를 다
지키면 앱 안에 누를 자리가 남지 않는다. 이전 판의 구멍이다.

**설치 트리거는 `Sources/trolley/MenuBarController.swift` 다.** 금지 목록에 없고 옆 세션이
뜯는 두 파일도 아니다. `MenuBarMenu.specs` 가 이미 데이터 기반이라 윈도우 서버 없이 테스트된다.

- 항목 하나. 문구는 `UpdateStatus` 에 따라 바뀐다 (`.downloaded` 일 때만
  "설치하고 다시 시작", 그 외에는 비활성 안내)
- `MenuBarMenu.specs` 는 지금 **정적 `let` 배열**이다. 상태를 반영하려면 함수로 바꿔야 한다.
  그 변경은 허가된다
- **`Tests/trolleyTests/MenuBarMenuTests.swift` 가 깨진다.** `testTheMenuIsAskSettingsQuitInThatOrder`
  는 `titles == ["물어보기","설정","종료"]` 를, `testQuitIsSeparatedFromTheRest` 는
  `specs.count == 4` 를 못박는다. 두 테스트를 새 모양에 맞게 고쳐라 — 지우지 말고
- 커밋할 때 이 파일을 따로 언급해라. 옆 세션과 겹칠지는 미지수다

**A6 — `UpdateCommand.swift` 도 같이 고쳐라.** 옛 시그니처로 `check`/`install` 을 부르고
있어서, 엔진을 바꾸면 컴파일이 깨진다. `--check` 는 SPA 셸 상태에서도 차분한 문구를 내야 한다.

### 6. "아직 배포된 릴리스가 없음" 은 오류가 아니라 차분한 정상 상태

첫 배포 전에는 이게 정상이고 UI 에 보인다. `.noRelease` 는 `.failed` 가 아니라
`.upToDate` 쪽으로 가야 한다. 실제로 그 상태에 도달하는 경로는 404 가 아니라
SPA 셸이다 — 위 B2 를 보라.

**지금은 반대로 돼 있다.** 사실 1 에 붙여 둔 측정대로 `trolley update --check` 가
`Error:` 를 찍고 종료코드 1 로 죽는다. CLI 와 `UpdateStatus` 양쪽 다 고쳐야 한다.
고친 뒤 그 명령이 종료코드 0 으로 차분히 끝나면 이 항목은 끝난 것이다.

### 7. 재실행

`replace` 는 새 inode 를 만들어 돌던 프로세스는 옛것을 계속 쓴다. 설치 후 앱을 다시 띄워라.

**순서가 중요하다.** 지금 프로세스가 살아 있는 채로 `open -a` 를 하면 "이미 실행 중"이 되어
아무 일도 안 일어난다. 종료 **전에** 재실행을 예약하고 종료해라.

진행 중이던 로컬 LLM 세션은 끊긴다. 그래서 재실행 시점은 사람이 정한다 — "정해 주세요" 3번.

---

## 검증 — 이대로 하면 한 번도 안 돌려 보고 커밋하게 된다

**A7.** `Version.swift` 의 `0.1.0` 을 올리지 말라 + HEAD 에 `v$current` 태그 필수
= 첫 릴리스 버전이 곧 현재 버전. `UpdateDecision.decide` 는 `current < latest` 일 때만
`.available` 이므로 **항상 `.upToDate` 다.** "새 버전 발견 → 다운로드 → 설치" 경로가
한 번도 안 돈다.

그래서 리허설 시임을 만든다:

- `TrolleyVersion.releaseFeed` 를 `TROLLEY_RELEASE_FEED` 환경변수로 덮을 수 있게 하라
  (없으면 maki.ink 기본값). 개발용 시임이라는 걸 주석에 적어라
- 로컬 디렉터리에 `0.2.0` 매니페스트 + **진짜 서명된** zip 을 세우고
  `python3 -m http.server` 로 띄운 뒤 전 경로를 돌린다. 서명이 진짜여야
  `verifySignature` 까지 통과한다
- **`maki.ink` 라이브 오리진은 리허설에 쓰지 마라** (사실 4)

돌려 봐야 하는 것: 매니페스트 없음(SPA 셸) → 차분한 정상 상태 / 새 버전 발견 → 다운로드 →
메뉴 항목 활성화 → 설치 → 재실행 / sha256 불일치 → 교체 안 됨 / 서명 불일치 → 교체 안 됨.

---

## 정해 주세요 — 실행 세션이 마음대로 정하면 안 되는 것

착수 전에 사람에게 물어라. 답이 없으면 그 항목만 남기고 나머지를 진행하라.

1. **스테이징된 다운로드의 수명** — 앱을 끄면 지울지, 남겨서 다음 실행에 이어받을지.
   남기면 `/Applications` 에 수백 MB 가 조용히 눕는다
2. **`<version>/` 사본도 둘지** — MAKi 는 `latest/` 와 `<version>/` 을 둘 다 스테이징한다.
   trolley 는 `latest/` 만 읽지만, 롤백하려면 버전 사본이 있어야 한다
3. **재실행 시점** — 사용자가 설치를 누르는 즉시인지, 진행 중인 LLM 세션이 끝날 때까지
   기다리는지
4. **`publishedAt`** — 매니페스트에 넣어 뒀지만 쓸 데가 정해지지 않았다. UI 에 안 보일
   거면 빼라

---

## 코드 스타일 — 이 저장소는 여기에 엄격하다

- 주석은 **왜**를 적는다. 추측이 아니라 측정된 사실을 인용한다. 코드를 다시 말하는 주석은 쓰지 마라.
  먼저 `UpdateInstaller.swift`, `LocalLLMSession.swift` 를 읽고 어조를 맞춰라.
- 순수 함수에는 전부 XCTest 를 붙인다. 네트워크·윈도우 서버·맥 상태 없이 돌아야 한다.
  `Tests/TrolleyKitTests/SelfUpdateTests.swift` 스타일을 따라 확장하라.
- 사용자에게 보이는 문자열과 커밋 메시지는 한국어. 주석과 식별자는 영어.
- `swift build` 는 green 이어야 한다. `swift test` 는 **405 가 아니라 402 에서 시작해**
  순증해야 한다 (A1). 줄어든 3개 말고 다른 게 빨개지면 그건 회귀다.

## 끝나면

`feat/auto-update` 에 커밋하고, 다음을 보고하라: 무엇을 만들었는지, 정확한 피드 URL 과 배포 명령,
"정해 주세요" 에 대해 받은 답(또는 못 받아서 비워 둔 것), 지시에 없어서 스스로 정한 것,
브리프와 어긋나는 발견, 일부러 뺀 것.
