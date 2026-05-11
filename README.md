# Flow

Flow는 Google Tasks의 특정 목록을 읽어 macOS 화면 상단에 “지금 할 일”을 작게 띄워주는 네이티브 오버레이 앱입니다.

화면을 계속 바꾸지 않아도 현재 집중할 task가 메뉴바 근처에 남아 있게 만드는 것이 목표입니다. 기본 설정은 Google Tasks의 `TODAY TASK` 목록을 사용합니다.

![Flow app icon](FlowIcon.png)

## 주요 기능

- macOS 메뉴바 근처에 현재 선택한 task 표시
- Google Tasks의 미완료 task를 원래 정렬 순서대로 드롭다운에 표시
- 드롭다운에서 현재 집중할 task 직접 선택
- 앱 시작 시 1회 갱신, 드롭다운을 열 때 즉시 갱신
- 백그라운드 polling 없음
- task 선택 상태 유지
- 여러 모니터에 오버레이 표시
- MacBook 노치가 있는 화면에서는 노치 바로 아래 중앙에 표시
- Dock 아이콘과 실행 표시 점 지원
- 오른쪽 클릭, `Esc`, Dock 메뉴로 종료
- 로그인 시 자동 실행 지원
- OAuth 토큰은 macOS Keychain에 저장
- 기존 `StudyTaskOverlay` 설정 자동 마이그레이션

## 요구 사항

- macOS 13 이상
- Swift 컴파일러가 포함된 Xcode Command Line Tools
- Google 계정
- Google Cloud 프로젝트와 Desktop OAuth client
- Google Tasks API 활성화

Xcode Command Line Tools가 없다면 먼저 설치합니다.

```bash
xcode-select --install
```

## 설치

프로젝트 폴더에서 빌드 스크립트를 실행합니다.

```bash
./build_native.sh
```

빌드 결과는 아래 위치에 설치됩니다.

```text
/Applications/Flow.app
```

실행:

```bash
open /Applications/Flow.app
```

## Google OAuth 설정

Flow는 사용자의 Google Tasks를 읽기 위해 Google OAuth 인증이 필요합니다. 앱은 `https://www.googleapis.com/auth/tasks.readonly` 범위만 요청하므로 task를 읽을 수만 있고 수정하거나 삭제하지 않습니다.

1. Google Cloud Console에서 프로젝트를 만듭니다.
2. `Google Tasks API`를 활성화합니다.
3. OAuth consent screen을 설정합니다.
4. 앱이 테스트 상태라면 `Test users`에 본인 Gmail을 추가합니다.
5. Credentials에서 `OAuth client ID`를 만듭니다.
6. Application type은 `Desktop app`으로 선택합니다.
7. 내려받은 JSON 파일 이름을 `credentials.json`으로 바꿉니다.
8. 아래 폴더에 넣습니다.

```text
~/Library/Application Support/Flow/credentials.json
```

`~`는 현재 사용자 홈 폴더입니다. 예를 들어 이 컴퓨터에서는 보통 아래 경로입니다.

```text
/Users/doltas
```

따라서 전체 경로는 다음처럼 해석됩니다.

```text
/Users/doltas/Library/Application Support/Flow/credentials.json
```

Finder에서 바로 열려면:

```bash
open "$HOME/Library/Application Support/Flow"
```

처음 실행하면 브라우저가 열리고 Google 로그인을 한 번 요청합니다. 인증이 완료되면 토큰은 Keychain에 저장됩니다.

## 사용법

- 상단 task 왼쪽 클릭: 드롭다운 열기/닫기
- 드롭다운 task 클릭: 현재 task로 선택
- 드롭다운 밖 클릭: 드롭다운 닫기
- 상단 task 오른쪽 클릭: 앱 종료
- `Esc`: 앱 종료
- Dock 아이콘 우클릭 후 `Quit`: 앱 종료

## 설정

설정 파일:

```text
~/Library/Application Support/Flow/config.json
```

기본 설정:

```json
{
  "debug_error_message": null,
  "fallback_text": "Google Tasks 연결 필요",
  "max_visible_tasks": 10,
  "task_list": "TODAY TASK"
}
```

설정 항목:

- `task_list`: 읽을 Google Tasks 목록 이름
- `fallback_text`: 표시할 task가 없거나 초기 상태일 때 사용할 문구
- `max_visible_tasks`: 드롭다운에 한 번에 보이는 최대 task 수. 초과분은 스크롤됩니다.
- `debug_error_message`: 오류 표시 테스트용 메시지. 평소에는 `null`로 둡니다.

설정을 수정한 뒤 앱을 재실행하면 반영됩니다.

## 갱신 정책

Flow는 Google Tasks API를 60초마다 계속 호출하지 않습니다.

- 앱 실행 직후 한 번 갱신
- 드롭다운을 열 때 한 번 갱신
- 오류 발생 후 자동 재시도 없음

이 방식은 API 사용량을 줄이고, 사용자가 task를 고르려는 순간에만 최신 목록을 가져오기 위한 선택입니다.

## 저장 위치와 보안

일반 설정과 OAuth 앱 식별 파일은 Application Support에 저장됩니다.

```text
~/Library/Application Support/Flow/config.json
~/Library/Application Support/Flow/credentials.json
```

Google OAuth access token과 refresh token은 파일이 아니라 macOS Keychain에 저장됩니다.

Keychain을 쓰는 이유:

- 토큰 파일이 프로젝트 폴더나 GitHub에 실수로 올라갈 위험을 줄입니다.
- macOS가 앱/사용자 권한 기반으로 민감 정보를 보호합니다.
- 앱을 업데이트해도 인증 상태를 유지하기 쉽습니다.
- 인증을 초기화할 때 Keychain 항목만 지우면 됩니다.

이 저장소에는 `credentials.json`, 토큰, 개인 task 데이터가 포함되면 안 됩니다.

## 로그인 시 자동 실행

자동 실행 켜기:

```bash
./install_login_item.sh
```

자동 실행 끄기:

```bash
./uninstall_login_item.sh
```

자동 실행은 아래 LaunchAgent를 사용합니다.

```text
~/Library/LaunchAgents/local.flow.plist
```

## 인증 초기화

Google 계정을 다시 연결하고 싶으면:

```bash
./reset_auth.sh
open /Applications/Flow.app
```

이 스크립트는 Keychain에 저장된 Flow OAuth 토큰을 삭제합니다. `credentials.json`은 삭제하지 않습니다.

## 기존 이름에서 마이그레이션

이 앱은 원래 `StudyTaskOverlay`라는 이름으로 시작되었습니다. Flow는 처음 실행할 때 아래 기존 위치에 있는 설정 파일을 새 위치로 자동 복사합니다.

```text
~/Library/Application Support/StudyTaskOverlay/credentials.json
~/Library/Application Support/StudyTaskOverlay/config.json
~/.study_task_overlay/credentials.json
~/.study_task_overlay/config.json
```

기존 Keychain 서비스 이름 `local.study-task-overlay`에 저장된 토큰도 발견하면 `local.flow`로 이어받습니다.

## 개발자용 구조

```text
Flow.swift               # macOS 네이티브 앱 본체
FlowIcon.png            # 앱 아이콘 원본 이미지
build_native.sh         # Swift 컴파일, icns 생성, /Applications 설치
install_login_item.sh   # 로그인 자동 실행 등록
uninstall_login_item.sh # 로그인 자동 실행 제거
reset_auth.sh           # Keychain OAuth 토큰 초기화
README.md               # 프로젝트 문서
```

외부 런타임 의존성은 없습니다. Python 프로토타입을 거치지 않고 Swift/AppKit으로 Google OAuth, Tasks API 호출, 오버레이 UI를 직접 처리합니다.

## 빌드 세부 사항

`build_native.sh`는 다음 작업을 수행합니다.

1. `Flow.swift`를 Swift 컴파일러로 빌드합니다.
2. `FlowIcon.png`를 여러 해상도의 iconset으로 변환합니다.
3. `FlowIcon.icns`를 앱 번들에 포함합니다.
4. `Info.plist`에 bundle id, 앱 이름, 아이콘, 버전을 기록합니다.
5. 완성된 앱을 `/Applications/Flow.app`에 설치합니다.
6. 예전 `/Applications/StudyTaskOverlay.app`이 있으면 제거합니다.

현재 bundle id:

```text
local.flow
```

## 오류 표시 디버깅

화면에 오류 문구가 제대로 표시되는지 확인하려면 `config.json`에 디버그 메시지를 넣습니다.

```json
{
  "debug_error_message": "디버그 오류 표시 테스트",
  "fallback_text": "Google Tasks 연결 필요",
  "max_visible_tasks": 10,
  "task_list": "TODAY TASK"
}
```

앱을 다시 실행하면 Google Tasks API를 호출하지 않고 상단에 `디버그 오류 표시 테스트`가 표시됩니다.

테스트 후에는 반드시 다시 `null`로 되돌립니다.

```json
"debug_error_message": null
```

## 문제 해결

`credentials.json 없음`:
`~/Library/Application Support/Flow/credentials.json` 위치에 Google OAuth Desktop client JSON을 넣었는지 확인합니다.

`Access blocked`:
OAuth consent screen이 테스트 상태라면 `Test users`에 로그인하려는 Gmail을 추가해야 합니다.

`목록 이름 확인 필요`:
`config.json`의 `task_list` 값이 Google Tasks 화면의 목록 이름과 정확히 같은지 확인합니다.

`Tasks API 오류`:
Google Cloud Console에서 `Google Tasks API`가 활성화되어 있는지 확인합니다.

Dock 아이콘이 기본 아이콘으로 보임:
Dock에 고정된 기존 아이콘을 제거한 뒤 `/Applications/Flow.app`을 다시 실행합니다. 필요하면 Dock을 재시작합니다.

```bash
killall Dock
```

앱을 다시 실행해도 새 창이 안 뜸:
중복 실행 방지가 정상 동작한 것입니다. 기존 상단 task를 오른쪽 클릭해서 종료한 뒤 다시 실행합니다.

## GitHub에 올릴 때 주의

아래 파일은 절대 GitHub에 올리지 않습니다.

- `credentials.json`
- OAuth token 또는 Keychain export
- `~/Library/Application Support/Flow/config.json`
- `.DS_Store`
- `.clang-module-cache/`
- `.pycache/`

저장소에는 소스, 빌드 스크립트, README, 아이콘 원본만 포함하는 것을 권장합니다.
