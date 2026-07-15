# 2026-07-13 작업 정리

오늘 진행한 작업을 주제별로 정리합니다. 마지막 "성능 개선" 항목은 아직 진행 중입니다.

---

## 1. UI 디자인 & 구현

- **Claude.ai 스타일 1차 구현**: `docs/ui_claude_design_spec.md` 작성 후 `ui/gradio_app.py`에 적용 — 크림톤 배경 + 테라코타 포인트 컬러, 정보구조 재설계(여행 계획 결과를 챗봇 버블에서 분리해 탭형 "결과 패널"로), React trace 기본 숨김, 입력창 placeholder 전환, 로딩 상태 표시.
- **디자인 스펙 멀티 에이전트 검토**: 4개 관점(시각 충실도/Gradio 구현 가능성/WCAG 접근성/프로젝트 적합성) 에이전트로 스펙을 비평·토론시켜 문서를 개정(근거 없는 HEX 값에 면책 문구 추가, 버튼 대비 WCAG 기준 수정, serif 제목 제거, Pretendard 폰트 실제 로딩 코드 추가 등).
- **"CHAT A.I+" 스타일로 전환**: 사용자가 새 디자인 레퍼런스로 `docs/ui_claude_design_spec.md`를 인디고/라벤더 톤으로 교체 → `ui/gradio_app.py`를 이 스펙에 맞춰 재구성(2단 레이아웃, pill 버튼, 무카드 챗봇 등). 이후 사용자가 세그먼트 pill 라디오, 넓은 컨테이너, 말풍선 스타일 등을 계속 다듬는 중.
- **다크모드 버그 수정**: 시스템이 다크모드면 Gradio 자체 다크 테마가 커스텀 CSS보다 먼저 적용되는 타이밍 문제를 발견 — `?__theme=light` 쿼리 파라미터로 강제 리다이렉트시키는 방식으로 해결(Playwright로 다크모드 에뮬레이션 후 검증 완료).

## 2. LangGraph 연결

- `app/graph/nodes.py`(4개 노드: parse_trip_request → route_planner → financial → finalize), `edges.py`(선형 엣지), `workflow.py`(StateGraph 조립)를 실제로 구현 — 기존엔 `langgraph` 의존성만 있고 미사용 상태였음.
- `app/core/state.py`의 `TripRouteState`를 실제로 사용하도록 필드 확장, `warnings`/`react_trace`는 `Annotated[..., operator.add]` 리듀서로 누적.
- `app/agents/coordinator.py`가 이 그래프를 호출하는 얇은 wrapper로 축소 — `react_loop.py`/`main.py`/`gradio_app.py` 호출부는 수정 없이 그대로 동작.
- `react_trace`가 하드코딩된 6단계 설명에서 **실제 노드 실행 기록**(4단계)으로 전환됨.

## 3. Route Planner 개선

- **추천 이유(reason) 장소별 개인화**: 기존엔 검색 배치 전체가 동일한 문구를 공유해 일정표의 "추천 이유"가 획일적이었음 — 장소별 category/rating/review_count를 반영하도록 수정.
- **식사 시간대 로직**: 점심/저녁 슬롯에 `category == "음식점"`인 장소를 우선 배정(`_reorder_places_for_time_slots`), RAG 랭킹에 음식점이 안 뽑히는 경우를 대비해 `_search_restaurant_places()`로 음식점 후보를 별도 확보.
- **일정 강도별 관광지 개수 차등화**: 빡빡한 일정=하루 3개, 그 외=2개로 구분(기존엔 구분 없음/여유로운 일정은 점심 슬롯 자체가 없었음). 점심/저녁은 강도와 무관하게 항상 포함.
- (사용자가 이어서) Solar 파싱 결과에 `must_include_places`(사용자가 명시적으로 콕 집은 장소) 필드 추가.

## 4. 회원가입/로그인 + 대화 기록 저장 + 맥락 이어가기

- **Supabase Auth 기반 이메일/비밀번호 회원가입·로그인** (`app/services/auth_client.py` 신규) — 로그인은 선택 사항이며 비로그인도 여행 계획 생성은 전부 가능.
- **대화 기록 저장** (`app/services/chat_store.py` 신규, `docs/sql/chat_history.sql`) — `chat_sessions`/`chat_messages` 테이블, RLS 정책 포함. 사용자가 Supabase SQL Editor에서 직접 실행 완료.
- **로그인 지속**: `gr.BrowserState`에 `refresh_token`만 저장(access_token은 저장 안 함), 새로고침 시 자동 갱신 + refresh_token 회전 처리.
- **맥락 이어가기**: `previous_condition_summary`를 Coordinator/그래프/Solar 프롬프트까지 관통시켜, "카페 말고 맛집 위주로 바꿔줘" 같은 후속 요청이 실제로 이전 조건(도시/기간 등)을 이어받아 처리되도록 함 — Solar에 멀티턴 메시지(이전 사용자 발화 + 이전 파싱 결과)로 전달.
- Playwright로 회원가입 → 새로고침 후 로그인 유지 → 후속 메시지 맥락 이어짐 → 최근 대화 목록에서 이전 세션 복원까지 end-to-end 검증 완료.
- (사용자가 이어서) 인증 에러 메시지를 한글로 번역하는 `_translate_auth_error()` 추가.

## 5. 성능 개선 (진행 중)

- **문제 진단**: 여행 계획 생성 1회에 60~90초 이상 걸리는 원인을 프로파일링 — `route_planner` 단계가 전체의 대부분을 차지하고, 그중에서도 `get_detail_common`(TourAPI 상세조회)이 캐싱 없이 순차 호출되며 최종 사용 장소(7개)보다 훨씬 많은 후보(약 40개)에 대해 호출되고 있었음.
- **1차 완료**: `get_detail_common` 호출에 캐싱(7일 TTL) + 스레드풀 병렬화(최대 6개 동시)를 적용 — 처음 보는 도시 기준 64초 → 27초, 캐시 있는 경우 19초까지 단축. TourAPI 429 이력(`docs/api_notes.md`)을 감안해 동시 개수는 6개로 제한.
- **근본 원인 추가 발견**: 데이터 수집 시점(`ingest_city`)에 TourAPI 좌표(mapx/mapy)를 이미 가져오는데도 Supabase `places` 테이블에 저장하지 않고 버려서, 요청마다 같은 장소의 좌표를 TourAPI로 재조회해야 했음.
- **진행 중인 작업**: `places` 테이블에 `latitude`/`longitude` 컬럼 추가, `insert_place()`/`ingest_city()`가 이미 가져온 좌표를 저장하도록 수정(완료), `_normalize_rag_place`가 RAG 검색 결과에서 바로 좌표를 읽도록 수정, 기존 ~1100건 백필 스크립트 작성, `match_places` SQL 함수도 좌표 컬럼을 반환하도록 재정의(현재 라이브 함수의 정확한 시그니처 확인 대기 중 — `match_places`가 여러 오버로드로 등록돼 있어 사용자가 실제 정의를 조회 중).

---

## 참고: 함께 만든 문서
- `docs/ui_claude_design_spec.md` — UI 디자인 스펙(현재 CHAT A.I+ 스타일)
- `docs/langgraph_workflow.md` — LangGraph 연결 상세
- `docs/sql/chat_history.sql` — 대화 기록 테이블 DDL (실행 완료)
- `docs/sql/add_place_coordinates.sql` — 좌표 컬럼 추가 DDL (**아직 실행 전** — match_places 함수까지 같이 정리한 뒤 한 번에 실행 권장)
- `docs/sql/get_current_match_places_definition.sql` — 현재 라이브 `match_places` 정의 확인용 쿼리
- `docs/project_plan.md` — 전체 프로젝트 계획 문서에 오늘 완료분 반영
