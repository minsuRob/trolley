# trolley

macOS 접근성 트리로 GUI 앱을 조작하는 Swift CLI이자, 그 위에 얹힌 메뉴 막대 앱.
무엇이 어떻게 도는지는 `README.md`. 이 파일은 **작업 절차**만 적는다.

## 확인은 자체 빌드로만 한다

화면에 보이는 것이 바뀌었으면 띄워서 눈으로 본다. 띄우는 방법은 하나뿐이다:

```sh
Scripts/dev-run.sh            # swift build → .build/dev/trolley.app → open -n
Scripts/dev-run.sh --replace  # 이미 떠 있는 설치본을 먼저 종료
```

- `swift run trolley` 로는 창이 **안 뜬다.** `WelcomeFlow.shouldRun()` 이 "launchd 가 이
  번들의 identifier 로 띄웠을 것"을 요구하는데 맨 바이너리에는 identifier 가 없다. 안 뜬다고
  코드를 의심하지 말 것 — 설계대로다.
- 확인하겠다고 `Scripts/build-installer.sh` 를 돌리지 않는다. 저건 배포 절차다: 유니버설
  빌드, 임시 키체인, Developer ID 서명, 공증 Apple 왕복 8~10분. 확인에는 하나도 필요 없다.
- **`/Applications/trolley.app` 을 건드리지 않는다.** 거기 있는 것은 사람이 지금 쓰고 있는
  앱이다. dev 번들은 `.build/dev` 에서 따로 돌고, identifier 가 같아 나란히 떠도 된다.
  방금 빌드한 쪽은 창 제목의 커밋이 `dev-` 로 시작한다. 끌 때는
  `pkill -f '.build/dev/trolley.app'` 로 그쪽만 끈다.
- 준비 항목 세 줄(위치·손쉬운 사용·화면 기록)이 주황인 것은 정상이다. 권한은 실행 파일
  경로에 묶이고 dev 번들은 다른 경로다. 그 세 줄로 무언가를 판단하지 말 것.
- 화면과 무관한 변경은 `swift test` 로 끝낸다. 띄우는 것은 눈으로 볼 것이 있을 때만.

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

`UserDefaults` 도 같다. `WikiSettings.mode` 는 저장된 선택이 없으면 **디스크를 보고** 정하므로,
`rootKey` 를 임시 폴더로 지정하지 않은 테스트는 그 맥에 볼트가 있느냐로 갈린다. 마찬가지로
`WikiTools` 의 `mode`·`storedFilter` 는 테스트에서 명시적으로 넘긴다 — 기본값은 테스트
프로세스의 defaults 를 읽는다.
