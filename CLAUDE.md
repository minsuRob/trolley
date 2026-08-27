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
Scripts/dev-run.sh            # 빌드 → 서명 → /Applications/trolley.app 바꿔치기 → 재실행
Scripts/dev-run.sh --preview  # 안 건드리고 잠깐 보기: swift build → .build/dev → open -n
```

- `swift run trolley` 로는 창이 **안 뜬다.** `WelcomeFlow.shouldRun()` 이 "launchd 가 이
  번들의 identifier 로 띄웠을 것"을 요구하는데 맨 바이너리에는 identifier 가 없다. 안 뜬다고
  코드를 의심하지 말 것 — 설계대로다.
- 확인하겠다고 `Scripts/build-installer.sh` 를 직접 돌리지 않는다. 저건 배포 절차다:
  유니버설 빌드, 임시 키체인, Developer ID 서명, 공증 Apple 왕복 8~10분. `dev-run.sh` 의
  기본 경로는 이미 서명하므로 권한을 보려고 이걸 따로 쓸 일은 이제 거의 없다 — 여전히
  필요한 건 유니버설 빌드 자체를 테스트할 때뿐이다 (아래 절 참고).
- **`dev-run.sh` 기본값은 `/Applications/trolley.app` 을 그 자리에서 바꿔치고, 떠 있던
  걸 죽이고 다시 연다 — 의도한 것이다.** 애드혹 서명(옛 기본 경로)은 빌드마다 cdhash 가
  바뀌어 손쉬운 사용·화면 기록 허락을 매번 다시 묻는데, 설치본 자리에서 Developer ID로
  서명해 두면 허락이 (경로 + 팀 id)에 묶여 그대로 유지된다. 위키 대화나 LLM 생성이 진행
  중이어도 상관없이 교체한다 — `UpdateCoordinator` 가 "설치는 항상 사용자 클릭이 있을 때만"
  으로 설계된 이유(진행 중인 세션은 우리 것이 아니라 마음대로 끊어도 되는 게 아니다)를
  알고도 명시적으로 포기한 것이다. 원자적 스왑은 `trolley install-local`(숨김 서브커맨드,
  `trolley update` 가 쓰는 것과 같은 `LiveUpdateIO` 경로)이 한다.
  안 건드리고 잠깐 보기만 하려면 `--preview` — 애드혹 서명, `.build/dev` 에서 열리고
  `/Applications` 는 손대지 않는다(옛 `--release`/`--replace`/`--signed` 도 `--preview`
  뒤에서 그대로 동작한다). 끌 때는 메뉴 막대에서 종료하거나 `pkill -x trolley`.
- 준비 항목 세 줄(위치·손쉬운 사용·화면 기록)이 주황인 것은 정상이다. 그 세 줄로
  무언가를 판단하지 말 것 — 이유는 아래.
- 화면과 무관한 변경은 `swift test` 로 끝낸다. 띄우는 것은 눈으로 볼 것이 있을 때만.

## 권한이 걸린 것을 확인할 때는 서명 빌드로

`dev-run.sh` 기본값이 이제 항상 Developer ID로 서명해 설치본 자리에 두므로, 일상적인
권한 확인에는 이 절이 더 이상 필요 없다. 아래는 `--preview` 로 애드혹 서명을 쓸 때,
또는 유니버설 빌드 자체(`build-installer.sh`)를 테스트할 때만 해당한다.

```sh
Scripts/dev-run.sh --preview --signed   # 몇 분 걸린다. 유니버설 빌드를 볼 때만.
```

애드혹 서명(`--preview` 의 기본 경로)은 `TeamIdentifier` 가 없고 cdhash 가 빌드마다
바뀐다. 손쉬운 사용·화면 기록·데스크탑 접근은 전부 서명에 묶이므로, macOS 는 매
실행을 처음 보는 앱으로 취급한다. 한 번 허락해도 다음 빌드가 물려받지 못하고, 팝업이 계속
뜬다.

**그리고 조용히 막힌다.** trolley 는 `.accessory` 라 그 동의 창이 앞으로 나오지 않을 때가
있는데, 그동안 `~/Desktop` 을 여는 `open()` 은 답을 기다리며 멈춰 있는다. 실측으로 위키를
순회하던 스레드 셋이 그 상태였다 — 오류도 로그도 없고, 목록만 "읽는 중…" 에서 멈춘다.
**앱이 멈춘 것처럼 보이면 코드를 의심하기 전에 `sample <pid>` 를 먼저 떠 볼 것.**
`open` 안에서 멈춰 있으면 그것은 버그가 아니라 대기 중인 동의 창이다.

`--preview --signed` 는 Developer ID 로 서명한다(공증은 생략 — 이 맥에서 실행하는 데는
필요 없다). `.build/signed/trolley.app` 에서 뜨고 `/Applications` 는 건드리지 않는다.
허락이 (번들 id + 팀 id) 에 묶이는데 그 둘이 설치본과 같으므로 그대로 물려받고, 다시
빌드해도 유지된다 — 지금은 `dev-run.sh` 기본값도 이 성질을 그대로 쓰지만, 결과물이
`/Applications/trolley.app` 자리 그 자체라는 점만 다르다.

**`--preview --signed` 는 파일 및 폴더(데스크탑)를 물려받지 못한다.** 그건 경로로도
걸리는 허락이라 `/Applications/trolley.app` 의 것이 `.build/signed/trolley.app` 에
적용되지 않는다. 위키 볼트가 `~/Desktop` 아래라 위키 목록이 안 뜨면 그것이다 —
**시스템 설정 → 개인정보 보호 및 보안 → 파일 및 폴더**에서 그 번들에 한 번 허락해
주면 된다(창이 4초 뒤에 같은 안내를 띄운다). `dev-run.sh` 기본값은 경로 자체가
`/Applications/trolley.app` 이라 이 문제가 아예 없다 — 파일 및 폴더도 그대로 물려받는다.

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
