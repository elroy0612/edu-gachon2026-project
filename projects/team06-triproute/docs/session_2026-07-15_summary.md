# 2026-07-15 작업 정리

전날(`docs/session_2026-07-14_summary.md`) 이후 진행한 작업을 정리합니다.
`feature/performance-tuning` 브랜치, 아직 커밋 전 상태.

---

## 1. 멀티 에이전트 비판적 감사(Critical Audit) 워크플로

"챗봇/시스템 전체에서 문제점을 찾아서 고쳐달라"는 요청에 따라, 코드베이스 전체를
9개 영역으로 나눠 병렬로 감사하는 워크플로를 실행.

### 진행 구조
1. **Review**: 영역별 비판적 에이전트 9개가 각자 담당 파일을 전체 정독하며 "진짜 재현되는
   버그"만 후보로 보고 (스타일 지적/가정 위주 지적은 배제하도록 지시).
   - 담당 영역: orchestration(그래프/코디네이터), route_planner 핵심 로직, route_planner
     필터링/추천사유, financial/비용 규칙, 외부 서비스(Google Places/Kakao/TourAPI/
     Upstage/Supabase), RAG, 스키마/State, UI+보안 가드레일, 캐시 동시성
2. **Verify**: 후보 하나당 독립된 회의론자 에이전트 3명이 각자 실제 코드를 읽고 반박 시도
   (`real: true/false` 판정). 과반수(2표 이상)가 `true`여야 확정.
3. **Fix**: 확정된 버그만 파일별로 최소 수정 적용(관련 없는 리팩터링 금지, 아키텍처
   변경이 필요한 건 스킵하고 사유 기록).
4. **Validate**: `ruff check app tests` + `pytest -q` 재실행으로 회귀 확인.

### 중간에 있었던 일: 세션 사용량 한도
1차 실행 막바지에 계정 세션 사용량 한도에 걸려 Verify 단계 에이전트 20개가
"You've hit your session limit" 에러로 실패(개별 에이전트의 토큰/컨텍스트 문제가 아니라
계정 전체 사용량 한도 문제였음). 영향 받은 파일: `app/utils/cache.py`(9회),
`app/main.py`(3회), `app/utils/formatter.py`(3회), `ui/gradio_app.py`(4회),
`app/agents/route_planner.py`(1회) — 이 파일들의 후보는 "반박당해서" 빠진 게 아니라
검증 자체가 못 돌아서 1차 결과에는 누락됨.
한도 리셋(11pm KST) 후 `resumeFromRunId`로 재개 — 이미 성공한 호출은 캐시로 재사용하고
실패했던 검증만 다시 실행해서 마무리(2차 실행은 에이전트 92개 전부 정상 완료, 에러 0건).

### 최종 집계
- 후보 24건 → 확정된 실제 버그 **21건**
- 수정된 파일 **12개**: `app/graph/workflow.py`, `app/graph/checkpointer.py`,
  `app/agents/route_planner.py`, `app/utils/transport_rules.py`,
  `app/services/chat_store.py`, `app/services/upstage_client.py`, `app/rag/retriever.py`,
  `app/schemas/request.py`, `ui/gradio_app.py`, `app/main.py`, `app/utils/cache.py`,
  `tests/test_chat_store.py`
- `ruff check` 전체 통과, `pytest` **96개 전부 통과**(회귀 없음)

---

## 2. 확정·수정된 버그 상세

### 2-1. LangGraph 상태 누적 버그 (`app/graph/workflow.py`)
- 같은 세션(`thread_id=session_id`, Postgres 체크포인터 활성 시)으로 대화를 이어가면,
  `operator.add`로 선언된 `warnings`/`react_trace` 채널이 매 턴 `[]`를 넘겨도 리셋되지
  않고 이전 턴 값에 계속 append됨 — 턴을 거듭할수록 응답에 중복 트레이스/경고가 무한정
  쌓임.
- 실제 설치된 langgraph로 최소 재현(operator.add 채널 + MemorySaver, 같은 thread_id로
  3회 invoke → 리스트가 1→2→3개로 누적) 및 실제 프로덕션 그래프로도 재현 확인.
- 수정: `run_trip_route_workflow`/`stream_trip_route_workflow`에서 invoke/stream 직전에
  `checkpointer.delete_thread(actual_thread_id)` 호출 — 대화 연속성은 이미
  `previous_condition_summary`/`previous_result`를 인자로 명시 전달하는 방식이라 체크포인터
  히스토리에 의존하지 않으므로 안전.

### 2-2. 체크포인터 ImportError 미처리 (`app/graph/checkpointer.py`)
- `psycopg_pool`/`langgraph.checkpoint.postgres` import가 try/except 밖에 있어서, 해당
  패키지가 없는 환경에서 앱 부팅 자체가 크래시할 수 있었음(현재는 pyproject.toml에
  필수 의존성으로 있어 당장 발생하진 않지만, 문서화된 "연결 실패 시 graceful fallback"
  계약에는 안 맞았음).
- 수정: import를 try/except ImportError로 감싸 실패 시 경고 후 `None` 반환(기존 재시도
  실패 경로와 동일한 패턴).

### 2-3. `route_planner.py` 인덱스/데이터 정합성 버그 7건 (연쇄)
- **근본 원인**: `_insert_lodging_checkin`이 `daily_schedule`만 갱신하고
  `route_summary`는 그대로 둬서, 숙박 체크인이 삽입된 이후 `route_summary[i]`와
  `daily_schedule[i]↔[i+1]` 간 인덱스 대응이 어긋남.
  - `_insert_lodging_checkin`이 `route_summary`/`transport_mode`도 함께 받아 체크인
    전후 두 구간을 새로 계산해 삽입하도록 재작성 → 이 한 곳을 고치니 슬롯 교체
    (`build_slot_replacement_route_plan`)와 장소 이동(`build_place_move_route_plan`)의
    인덱스 오류 2건이 같이 해결됨.
- 장소 이동 시 옮기는 장소 자신이 백필 후보로 다시 뽑혀 중복 등장하던 버그 →
  `existing_keys`에 이동 대상 자신도 추가.
- 카라반/글램핑처럼 이름 기반으로만 숙박 판정된 곳의 추천 사유가 액티비티 문구로
  잘못 나오던 버그 → 숙박 전용 문구로 재생성하도록 수정.
- 여행코스 연관 장소(`related_places`)에 숙박/음식점이 카테고리 필터 없이 섞여 들어가던
  filtering-gap 수정.
- `prefer_local`(로컬/한적한 곳 선호)로 뽑힌 숨은 맛집인데도 리뷰수가 많으면 "인기"
  라벨이 붙던 모순 수정 — `_build_place_reason`/`_normalize_rag_place`에
  `prefer_local` 파라미터 전달.

### 2-4. 택시 비용 계산 버그 2건 (`app/utils/transport_rules.py`)
- **0원=누락 구분 안 됨**: 택시 요금 조회 실패 시 플레이스홀더로 쓰는 `0`을 `is_estimated:
  False`(정상 조회된 실제 값)로 잘못 표시 — 다른 곳(숙박비 등)엔 이미 있는 "0=누락"
  구분 관례가 택시에는 빠져 있었음. → `taxi_fare is None or <= 0`이면 `is_estimated:
  True`로 정정.
- **인원수 미반영**: 대중교통/렌터카는 인원수에 따라 비용이 스케일링되는데 택시만
  인원수를 무시하고 요금 그대로 반환 → `TAXI_SEATS_PER_CAB=4` 기준
  `ceil(인원수/4)`대 수만큼 곱하도록 수정(4인 이하는 기존과 동일한 결과 유지).
- 스킵(범위 밖): 이 `is_estimated` 신호를 `financial.py`의 최종 응답까지 끌어올려
  "이 구간 비용은 추정치/누락"이라고 노출하는 것은 `response.py` 스키마 변경이 필요한
  더 큰 작업이라 이번엔 손대지 않음.

### 2-5. 세션 소유권 검증 누락 (`app/services/chat_store.py`)
- `append_message`/`update_session_condition_summary`/`update_session_title`/
  `update_session_result`가 `session_id`만 받고 그 세션이 실제로 요청자 소유인지
  검증하지 않아서, 조작된 `session_id`로 다른 사용자의 대화 기록을 덮어쓸 수 있는
  인가 우회 가능성이 있었음(읽기 함수들은 이미 소유권 검증이 있었는데 쓰기 함수만
  빠져 있었음).
- 수정: 네 함수 모두 `user_id` 파라미터를 받아 기존 `_session_belongs_to_user` 체크를
  쓰기 전에 수행, 불일치 시 `PermissionError`. `ui/gradio_app.py` 호출부와
  `tests/test_chat_store.py`(신규 거부 테스트 1건 추가) 갱신.

### 2-6. Solar JSON 파싱 브레이스 카운팅 버그 (`app/services/upstage_client.py`)
- `_extract_json`의 중괄호 깊이 계산이 문자열 값 내부의 `{`/`}`까지 구조적 중괄호로
  잘못 세어서, 예를 들어 `{"note": "괄호 { 확인"}` 같은 정상 JSON을 못 찾고
  `ValueError` → Mock 파서로 조용히 폴백되는 버그.
- 수정: 스캔 중 `in_string`/`escape` 상태를 추적해 문자열 내부의 중괄호는 깊이 계산에서
  제외.

### 2-7. RAG 유사도 하한선 없음 (`app/rag/retriever.py`)
- `retrieve_places_by_taste`가 유사도 점수와 무관하게 상위 N개를 그대로 반환해서, 도시의
  임베딩 데이터가 요청 취향과 안 맞아도 무관한 장소가 채워지는 문제. `_search_rag_places`
  쪽엔 "빈 결과 → TourAPI 실검색 폴백" 로직이 이미 있었는데, 결과가 항상 안 비니 폴백이
  전혀 발동을 못 했음.
- 수정: `MIN_SIMILARITY = 0.5` 하한선 도입, 미달 결과는 제외(값이 없는 경우는 기존 관례대로
  통과). 값은 실측 데이터가 없어 다른 휴리스틱 상수(`HIDDEN_GEM_MIN_RATING` 등)와 같은
  방식의 근거 있는 기본값으로 문서화 — 추후 실제 쿼리/유사도 분포 관찰 후 튜닝 필요.
- 스킵(범위 밖): 임계값을 SQL RPC(`match_places`) 단에서 적용하는 건 Supabase 마이그레이션이
  필요해 이번 범위 밖.

### 2-8. `previous_result` 필드 설명 불일치 (`app/schemas/request.py`)
- Field 설명이 "`previous_result`만 주면 기간 연장이 동작한다"고 되어 있었는데, 실제
  트리거 조건(`app/graph/nodes.py`)은 `previous_condition_summary`와
  `previous_result`가 **둘 다** 있어야 함 → 문서 문구만 정정(동작/타입 변경 없음).
- 이후 §2-11(main.py 보안 강화)에서 이 파일의 타입 자체가 한 번 더 바뀜(아래 참고).

### 2-9. 채팅 헤더 XSS 가드레일 누락 (`ui/gradio_app.py`)
- 채팅 말풍선 헤더에서 LLM이 파싱한 `city`/`duration`/`theme_str`가 이스케이프 없이
  raw HTML로 들어가고 있었음(바로 아래 `streamed_text`는 이미 `html.escape()` 처리 중이라
  같은 파일 안에서도 처리가 일관되지 않았던 것) → 세 값 모두 `html.escape()` 적용.

### 2-10. 로그아웃 시 세션 상태 리셋 버그 (`ui/gradio_app.py`)
- `do_logout`이 `active_session_id_state`를 `""`(빈 문자열)로 리셋했는데, `chat()`의
  "새 세션인지" 판정은 `None`을 기준으로 함 → 로그아웃 후 같은 탭에서 재로그인하면
  새 대화 세션이 안 만들어지고 이전 세션에 계속 이어붙던 버그. `None`으로 리셋하도록 수정.

### 2-11. 인증 없는 API 엔드포인트 보강 (`app/main.py`, `app/schemas/request.py`)
`POST /trip/plan`이 Gradio UI를 거치지 않고 직접 호출 가능한데 여러 방어가 없었음.
이번에 고친 것과 의도적으로 안 고친 것을 구분:
- **고침**:
  - `create_trip_plan()`에서 발생한 예외가 그대로 500으로 노출되던 것 → try/except로
    `ValueError`는 400, 그 외는 500으로 구분해 Gradio `chat()`과 동일한 처리로 통일.
  - 요청 바디 크기 제한이 전혀 없던 것 → `/trip/plan` 경로에만 적용되는 미들웨어로
    Content-Length 1MB 초과 시 413.
  - `user_input`에 길이 제한이 없던 것 → `min_length=1, max_length=2000` 추가.
  - `previous_result`가 검증 안 된 `dict[str, Any]`였던 것 → 실제 이 엔드포인트가
    반환하는 것과 동일한 `TripPlanResponse` 타입으로 강화, 잘못된 형태는 422로 조기 차단.
- **의도적으로 스킵(아키텍처 결정 필요)**:
  - **인증 자체**: 지금 있는 인증(`auth_client.py`)은 Supabase 쿠키/세션 기반으로 Gradio
    로그인 흐름 전용 — REST API에 그대로 재사용할 수 있는 구조가 아님. API 키/Bearer
    토큰 중 무엇을 쓸지, 401 응답 형태를 어떻게 할지 등은 코드에서 추측하지 않고
    제품/아키텍처 결정으로 남김.
  - **Rate limiting**: 라이브러리 자체가 프로젝트에 없고, GCP Cloud Run 배포가 목표라
    (여러 인스턴스로 뜰 수 있음) 인메모리 리미터는 인스턴스별로 따로 걸려 사실상 방어가
    안 되면서 "방어하고 있다"는 착각만 줄 수 있어 제외 — Redis 등 공유 저장소 기반으로
    제대로 하려면 별도 작업 필요.

### 2-12. 캐시 레이어 동시성 버그 3건 (`app/utils/cache.py`)
- **레이스 컨디션**: 같은 캐시 키를 여러 스레드가 동시에 미스로 판단하면 `fetch_fn()`이
  중복 호출됨(체크 → 조회 → 저장 사이에 락이 풀렸다 다시 잡히는 구조였음) → 체크~조회~
  저장 전체를 하나의 `RLock`으로 감싸도록 수정. 8스레드 동시 호출 테스트로 `fetch_fn()`
  호출이 정확히 1회로 줄어드는 것 확인.
- **메모리 누수**: `_path_locks`가 한 번이라도 조회된 키의 락을 영구히 들고 있어서
  캐시 키가 늘어날수록 무한정 커짐 → refcount 방식(`_path_lock_waiters`)으로 아무도
  안 쓰는 락은 즉시 정리되도록 수정.
- **에러 처리 누락**: 문법적으로는 유효한 JSON인데 `cached_at`/`data` 키가 없는 캐시
  파일을 만나면 `KeyError`가 그대로 전파되던 것 → 캐시 미스로 처리하도록 catch 범위 확장.

---

## 3. 검증

- `ruff check app tests`: **All checks passed!**
- `pytest -q`: **96 passed**, 1 warning(psycopg_pool의 사전 존재하던 무관한
  DeprecationWarning)
- `git diff --stat`: 12개 파일, +285/-61, 되돌리거나 충돌난 부분 없음(직접 확인)

---

## 참고: 커밋 상태

이번 작업은 전부 `feature/performance-tuning` 브랜치에 **커밋 전 상태**(작업 트리에만
반영). 수정된 파일: `app/graph/workflow.py`, `app/graph/checkpointer.py`,
`app/agents/route_planner.py`, `app/utils/transport_rules.py`,
`app/services/chat_store.py`, `app/services/upstage_client.py`, `app/rag/retriever.py`,
`app/schemas/request.py`, `ui/gradio_app.py`, `app/main.py`, `app/utils/cache.py`,
`tests/test_chat_store.py`, 그리고 이 문서 자체(`docs/session_2026-07-15_summary.md`).
