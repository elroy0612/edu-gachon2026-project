# TripRoute LangGraph Workflow 연결

`pyproject.toml`에 `langgraph>=1.2.8` 의존성만 있고 실제로는 쓰이지 않던 상태(`app/graph/nodes.py`, `edges.py`, `workflow.py`가 전부 빈 파일)를 해소하고, Coordinator의 순차 함수 호출을 실제 LangGraph `StateGraph`로 교체했다.

## 이전 상태

- `app/agents/coordinator.py`의 `run_triproute_coordinator()`가 `parse_trip_request → build_route_plan → build_financial_summary`를 그냥 순서대로 함수 호출.
- `app/core/state.py`에 `TripRouteState` TypedDict가 "LangGraph Workflow에서 쓸 State"라는 주석과 함께 정의만 되어 있고 실제로 어디서도 쓰이지 않음.
- 응답에 포함되는 `react_trace`(6단계: parse_trip_request/search_places/get_related_places/get_route_info/estimate_cost/build_final_response)는 실제 실행 로그가 아니라 코드에 하드코딩된 설명 리스트.

## 변경 내용

### 1. `app/core/state.py` — State 스키마 확장

기존 `TripRouteState`에 없던 필드(schedule_intensity, prefer_local/budget, is_peak_season, parser, selected_places, lodging_place, data_source, result 등)를 추가하고 `total=False`로 선언(그래프 실행 중간에는 모든 필드가 채워져 있지 않으므로).

`warnings`, `react_trace`는 노드마다 새로 반환한 리스트가 기존 값 뒤에 이어 붙어야 해서 `Annotated[List[...], operator.add]` 리듀서를 사용했다. 나머지 필드는 LangGraph 기본 동작대로 마지막에 쓴 값으로 교체(replace)된다.

### 2. `app/graph/nodes.py` — 4개 노드

기존 Coordinator/Route Planner/Financial Agent 경계를 그대로 노드 경계로 사용했다(각 Agent의 로직 자체는 건드리지 않고, 그 호출을 그래프 노드로 감싸기만 함):

| 노드 | 하는 일 |
|---|---|
| `parse_trip_request` | Solar API/Mock parser로 입력 파싱, 파싱 결과를 State 필드로 분해 |
| `route_planner` | `build_route_plan()` 호출, 관광지/동선/일정 결과를 State에 반영 |
| `financial` | `build_financial_summary()` 호출, 비용 요약을 State에 반영 |
| `finalize` | 최종 응답(`condition_summary`/`daily_schedule`/`route_summary`/`cost_summary`/`warnings`/`react_trace`) 조립 |

각 노드는 실행되며 자기 자신의 `react_trace` 항목 1개씩을 반환한다 — 이제 트레이스는 **실제로 그 노드가 실행됐다는 기록**이지, 미리 적어둔 설명이 아니다.

### 3. `app/graph/edges.py` — 선형 엣지

TripRoute Workflow는 조건 분기가 없는 단순 파이프라인이라, `LINEAR_EDGES`로 `parse → route_planner → financial → finalize` 순서만 정의한다.

### 4. `app/graph/workflow.py` — 그래프 조립/실행

`StateGraph(TripRouteState)`에 4개 노드와 엣지를 등록하고 `compile()`, 모듈 로드 시 한 번만 컴파일해서 재사용한다. `run_trip_route_workflow(user_input, transport_mode, people_count)`가 그래프를 `invoke()`하고 최종 State의 `result` 키를 반환한다.

### 5. `app/agents/coordinator.py` — 얇은 wrapper로 축소

`run_triproute_coordinator()`는 이제 `run_trip_route_workflow()`를 호출하기만 한다. **함수 시그니처와 반환 dict 형태는 그대로 유지**되므로 `react_loop.py`, `app/main.py`(FastAPI), `ui/gradio_app.py` 등 호출부는 전혀 수정할 필요가 없었다.

## 동작 변화

- `react_trace`가 6개(하드코딩) → **4개(실제 노드 실행 순서)** 로 바뀜: `parse_trip_request` / `build_route_plan` / `build_financial_summary` / `finalize_response`.
- `tests/test_react_loop.py`의 `assert len(result["react_trace"]) == 6`을 `== 4` + 순서 검증으로 갱신.
- 그 외 API 응답 스키마(`app/schemas/response.py`)와 실제 값들은 동일.

## 검증

- 전체 테스트 54개 통과 (`uv run python -m pytest tests/ -q`).
- `run_triproute_react_loop()` 직접 호출로 실제 Solar/RAG/TourAPI/Kakao Mobility 연동까지 end-to-end 실행 확인.

## 남은 여지 (지금은 안 한 것)

- 노드 4개는 여전히 각 Agent 함수를 통째로 호출하는 수준이라, `build_route_plan()` 내부(장소 검색/연관 장소/동선 계산)를 더 잘게 쪼개 별도 그래프 노드로 만들면 트레이스가 더 세분화되고 조건부 재시도(예: RAG 실패 시 real_api로, 그마저 실패 시 mock으로) 같은 로직을 엣지의 조건부 분기(`add_conditional_edges`)로 명시적으로 표현할 수 있다. 지금은 그 fallback 로직이 여전히 `build_route_plan()` 내부에 `try/except`로 감춰져 있음 — 필요해지면 다음 단계로 고려.
