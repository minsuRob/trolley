# trolley

macOS 접근성 트리로 GUI 앱을 조작하는 Swift CLI이자, 그 위에 얹힌 메뉴 막대 앱.
무엇이 어떻게 도는지는 `README.md`. 이 파일은 **작업 절차**만 적는다.

## 확인은 자체 빌드로만 한다

화면에 보이는 것이 바뀌었으면 띄워서 눈으로 본다. **그 절차는 `docs/검증.md` 에 있다 —
확인을 시작하기 전에 읽는다.** 공증 없는 빌드로 띄우고, 창은 trolley 자체의 computer use
로 열고(`trolley click`), 무엇이 어디에 있는지는 `trolley dump-tree --frames` 로 재고,
그림은 `Scripts/window-shot.swift` 로 창 단위로 찍는다. 그 경로가 막혔을 때만 Claude 의
computer use 로 넘어간다. 아래는 띄우는 방법만 적는다:

```sh
Scripts/dev-run.sh            # swift build → .build/dev/trolley.app → open -n
Scripts/dev-run.sh --replace  # 이미 떠 있는 설치본을 먼저 종료
```

- `swift run trolley` 로는 창이 **안 뜬다.** `WelcomeFlow.shouldRun()` 이 "launchd 가 이
  번들의 identifier 로 띄웠을 것"을 요구하는데 맨 바이너리에는 identifier 가 없다. 안 뜬다고
  코드를 의심하지 말 것 — 설계대로다.
- 확인하겠다고 `Scripts/build-installer.sh` 를 직접 돌리지 않는다. 저건 배포 절차다:
  유니버설 빌드, 임시 키체인, Developer ID 서명, 공증 Apple 왕복 8~10분. 권한이 걸린 것을
  볼 때만 필요하고, 그때도 `dev-run.sh --signed` 가 대신 부른다 (아래).
- **`/Applications/trolley.app` 을 건드리지 않는다.** 거기 있는 것은 사람이 지금 쓰고 있는
  앱이다. dev 번들은 `.build/dev` 에서 따로 돌고, identifier 가 같아 나란히 떠도 된다.
  방금 빌드한 쪽은 창 제목의 커밋이 `dev-` 로 시작한다. 끌 때는
  `pkill -f '.build/dev/trolley.app'` 로 그쪽만 끈다.
- 준비 항목 세 줄(위치·손쉬운 사용·화면 기록)이 주황인 것은 정상이다. 그 세 줄로
  무언가를 판단하지 말 것 — 이유는 아래.
- 화면과 무관한 변경은 `swift test` 로 끝낸다. 띄우는 것은 눈으로 볼 것이 있을 때만.

## 권한이 걸린 것을 확인할 때는 서명 빌드로

```sh
Scripts/dev-run.sh --signed   # 몇 분 걸린다. 권한 볼 때만.
```

기본 경로(`swift build`)는 **애드혹으로 서명**한다 — `TeamIdentifier` 가 없고 cdhash 가
빌드마다 바뀐다. 손쉬운 사용·화면 기록·데스크탑 접근은 전부 서명에 묶이므로, macOS 는 매
실행을 처음 보는 앱으로 취급한다. 한 번 허락해도 다음 빌드가 물려받지 못하고, 팝업이 계속
뜬다.

**그리고 조용히 막힌다.** trolley 는 `.accessory` 라 그 동의 창이 앞으로 나오지 않을 때가
있는데, 그동안 `~/Desktop` 을 여는 `open()` 은 답을 기다리며 멈춰 있는다. 실측으로 위키를
순회하던 스레드 셋이 그 상태였다 — 오류도 로그도 없고, 목록만 "읽는 중…" 에서 멈춘다.
**앱이 멈춘 것처럼 보이면 코드를 의심하기 전에 `sample <pid>` 를 먼저 떠 볼 것.**
`open` 안에서 멈춰 있으면 그것은 버그가 아니라 대기 중인 동의 창이다.

`--signed` 는 Developer ID 로 서명한다(공증은 생략 — 이 맥에서 실행하는 데는 필요 없다).
`.build/signed/trolley.app` 에서 뜨고 `/Applications` 는 건드리지 않는다. **손쉬운 사용과
화면 기록은 이걸로 해결된다** — 실측으로 두 줄이 주황에서 초록이 됐다. 허락이 (번들 id +
팀 id) 에 묶이는데 그 둘이 설치본과 같아서 그대로 물려받고, 다시 빌드해도 유지된다.

**파일 및 폴더(데스크탑)는 물려받지 못한다.** 그건 경로로도 걸리는 허락이라
`/Applications/trolley.app` 의 것이 `.build/signed/trolley.app` 에 적용되지 않는다. 위키 볼트가
`~/Desktop` 아래라 위키 목록이 안 뜨면 그것이다 — **시스템 설정 → 개인정보 보호 및 보안 →
파일 및 폴더**에서 그 번들에 한 번 허락해 주면 된다(창이 4초 뒤에 같은 안내를 띄운다).

유니버설 릴리스 빌드와 SSM 서명 자산이 필요해 몇 분 걸리므로, 권한과 무관한 확인에는
쓰지 않는다.

## 끝나면 푸시한다

`swift test` 전체 통과 + (화면이 바뀌었으면) `dev-run.sh` 로 확인까지 끝난 것을 완성으로
보고, 커밋하고 지금 브랜치로 푸시한다. 반쯤 된 것을 올리지 않는다.

- `main` 에 직접 푸시하지 않는다. `feat/...` 브랜치에서 작업하고 그 브랜치로 올린다.
- 커밋 메시지는 한국어. 제목 한 줄은 무엇을 하게 됐는지의 평서문("위키에서 무엇을 볼지
  trolley가 직접 고른다"), 본문은 **왜 그렇게 고쳤는지** — 무엇이 문제였고 무엇을 재봤는지.
  바뀐 파일 목록은 적지 않는다. `git log` 를 그대로 따른다.
- 사람의 트리에서 `git stash` 를 돌리지 않는다. 커밋되지 않은 다른 작업이 섞여 있다.

## 테스트가 사람의 볼트를 읽지 않게

`~/Desktop/workspace/MAKi/markhub-llm-wiki` 는 사람이 매일 고치는 폴더다. 테스트가 그걸
읽으면 남의 커밋에 실패한다. 임시 폴더 픽스처(`WikiFixture`)를 쓴다.

`UserDefaults` 도 같다. `WikiSettings.rootIsReadable` 은 **디스크를 보고** 정하므로,
`rootKey` 를 임시 폴더로 지정하지 않은 테스트는 그 맥에 볼트가 있느냐로 갈린다.
`WikiSeparationTests.withRoot` 가 그 일을 한다.
