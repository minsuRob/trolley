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
```
