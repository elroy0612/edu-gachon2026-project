# Step 3 Agent 구현 보고서

> Coordinator/Route Planner Agent 구현 작업 전체 기록. 발표/보고서 작성 시 이 문서를 기반으로 정리하면 됩니다.
> 관련 브랜치: `feature/coordinator-agent`, `feature/route-planner-agent`

---

## 0. 시작 전 상태

- **평점/리뷰수 백필 완료**: TourAPI 일일 트래픽 한도 초과로 하루 지연됐다가, 429 재시도(backoff) 로직 추가 후 완료. `places` 테이블 1,137건 중 1,057건(93%) rating/review_count 채워짐. 나머지 80건은 Google Places 매칭 실패(소규모 펜션·체인점 등)로 영구 결측 예상 — Route Planner가 `None` 값을 명시적으로 처리하도록 설계함.
- **팀원이 이미 Coordinator/Route Planner/Financial/Gradio UI를 PR로 구현해서 main에 병합해둔 상태**였음 — 새로 설계하지 않고 기존 뼈대의 갭(RAG 미연동, review_count 필터링 없음 등)을 메우는 방향으로 작업 진행.

---

## 1. Coordinator Agent

| 항목 | 내용 |
|---|---|
| prefer_local 신호 추출 | Solar 시스템 프롬프트에 필드 추가(의미 기반 zero-shot 판단). "사람 안 몰리는 로컬 맛집" → true, "유명한 관광지" → false로 실제 Solar API 응답 검증 완료 |
| Mock parser 개선 | Solar API 장애 시 쓰는 fallback이 원래 사용자 입력을 무시하고 "강릉" 고정값만 반환했는데, `city`/`prefer_local`은 키워드 매칭(`KNOWN_CITIES`, `PREFER_LOCAL_KEYWORDS`)으로 실제 입력을 반영하도록 개선 |
| 프롬프트 중앙화 | `app/core/prompts.py`에 `COORDINATOR_PARSE_SYSTEM_PROMPT`로 이관 (기존엔 `upstage_client.py`에 인라인) |
| 확인된 사실 | `transport_mode`/`people_count`는 자연어 추출 대상이 아니라 Gradio UI 체크박스/숫자 입력값을 그대로 받음 (README 설계대로) |

테스트 6건 추가, 전체 통과.

---

## 2. Route Planner Agent

### 2-1. RAG 연동 (Supabase pgvector)

- `_search_rag_places()`: 취향 문장을 임베딩해 `match_places` RPC로 도시 내 유사도 top-N 검색
- **3단계 fallback**: RAG 실패/결과없음 → TourAPI 실시간 검색 → Mock
- `match_places` SQL 함수 재정의(Supabase SQL Editor 수동 실행): `city_filter` 파라미터 추가, `rating`/`review_count`/`category`/`address` 반환 컬럼 추가, 이후 `category='여행코스'` 행도 검색 대상에서 제외하도록 재수정 (RAG가 코스 설명 텍스트를 개별 방문 장소처럼 잘못 추천하던 문제 해결)
- Supabase `places` 테이블에는 좌표가 없어서, 선택된 후보만 TourAPI `detailCommon2`로 좌표/지역코드 보완 (`_fill_missing_place_details`)

### 2-2. review_count 기반 prefer_local 필터링

- `_sort_by_prefer_local()`: `prefer_local=true`면 review_count 오름차순(로컬 우선), `false`면 내림차순(유명한 곳 우선)
- review_count가 없는(Google Places 매칭 실패) 곳은 배제하지 않고 뒤쪽 배치
- 이걸로 "로컬/유명 장소 필터링" 요구사항이 Coordinator+Route Planner 양쪽 다 완료됨

### 2-3. 연관 관광지 추천 로직 전면 교체

기존 TourAPI "관광지별 연관 관광지 정보"(T맵 내비게이션 기반, `related_place_api.py`) 사용 시 403 Forbidden 발생 → data.go.kr 승인 처리로 해결했으나, **이 API의 데이터셋 자체가 "2024.05~2025.04"까지만 제공되는 한시적 데이터라 현재 시점엔 항상 0건**임을 확인 (코드로 해결 불가능한 데이터 수명 문제).

**대체 방안**: TourAPI **여행코스**(contentTypeId=25) 데이터 활용
- `get_detail_info()`(반복정보조회) 신규 추가
- 선택된 장소가 어떤 코스의 하위 장소(subcontentid)로 포함돼 있는지 콘텐츠 ID로 대조해서, 같은 코스의 다른 장소를 연관 장소로 추천 (`_search_course_related_places`) — 임베딩이 아니라 순수 ID 매칭
- 실제 데이터로 매칭 검증 완료 (예: "안목해변" 선택 → "자디마루", "경포호" 등 같은 코스 소속 장소가 정확히 추천됨)
- **다일차 코스 문제 발견 및 수정**: 코스 하위 장소엔 "몇 일차"인지 구분이 없어서, 5일 코스인데 2일 여행이면 다른 날짜 구간 장소가 섞여 들어올 수 있었음 → 매칭된 장소의 코스 내 순서(index) 기준 앞뒤 2개(`COURSE_NEARBY_WINDOW`)만 추천하도록 근사치 제한 추가. 라이브 데이터로 검증(코스 마지막 순서 장소 매칭 시 그 앞쪽 2개만 나오고 코스 앞부분은 제외됨).
- 코스 구성은 자주 안 바뀌므로 `app/utils/cache.py`의 `cached_call()`로 7일 캐싱 적용 (DB에 새 테이블 없이 기존 캐시 유틸 재사용)
- 부수 버그 수정: `related_place_api.py`의 `_extract_items()`가 결과 0건일 때 `items`가 `""`(빈 문자열)로 오는 케이스 방어 처리 누락 → `AttributeError` 발생하던 것 수정

### 2-4. 여행코스 데이터 보강

초기엔 도시당 코스가 너무 적어(강릉 2건, 경주·전주·서울은 0건) 연관 장소 추천이 항상 좁은 풀에서만 나오는 문제 발견. TourAPI 실제 보유량을 확인해보니 초기 수집 때 다 못 가져온 것으로 확인됨.

원인: **여행코스는 단일 주소(addr1)가 없는 경우가 대부분이라, 기존 `ingest_city()`의 "주소 없으면 제외" 필터에 다 걸러져서 저장이 안 되고 있었음.** `vector_store.py`를 수정해 여행코스(contentTypeId=25)는 addr1이 없으면 검색에 사용한 도시명을 대체 주소로 저장하고 지역 필터도 생략하도록 함 (다른 콘텐츠 타입은 기존 필터 유지).

재수집 결과 (수정 전 → 수정 후):

| 도시 | 이전 | 현재 |
|---|---|---|
| 강릉 | 2 | 10 |
| 속초 | 2 | 6 |
| 춘천 | 2 | 5 |
| 부산 | 1 | 13 |
| 제주 | 1 | 14 |
| 경주 | 0 | 8 |
| 전주 | 0 | 4 |
| 여수 | 1 | 8 |
| 인천 | 1 | 8 |
| 서울 | 0 | 19 |

총 96건. 경주·전주·서울처럼 이전엔 데이터가 아예 없던 도시도 이제 연관 관광지 추천이 정상 동작함.

### 2-5. 지리적 효율성 필터링

RAG는 취향 유사도만 보고 거리를 전혀 고려하지 않아서, 취향 1등이 해변이고 2등이 반대편 산간 지역이어도 그대로 동선에 들어가는 문제 발견 (카카오모빌리티는 구간별 거리·시간을 계산만 하지, 그 결과로 후보를 거르거나 순서를 바꾸는 로직이 없었음).

`_filter_places_within_radius()` 추가: 하버사인 공식으로 거리 계산, 취향 1등 장소를 시작점으로 이미 선택된 후보 중 하나에라도 15km(`MAX_CANDIDATE_DISTANCE_KM`) 이내인 것만 순차적으로 채택 (순차적 지리 군집화). 좌표를 모르는 장소는 일단 통과시킴. 테스트로 검증(서울-부산 300km+ 거리는 정확히 배제, 5km 이내는 포함 확인).

**후속 수정**: 이 필터가 처음엔 RAG 후보(`candidate_places`)에만 적용되고, 코스 매칭으로 붙는 `related_places`는 거리 검증 없이 그대로 합쳐지는 걸 재점검 중 발견 — `anchor_places` 파라미터를 추가해 이미 확정된 candidate_places 군집을 기준으로 related_places도 15km 이내인지 걸러지도록 수정.

### 2-6. 하루 일정 과밀도 체크 + 계절 반영

- `_check_daily_density()`: 하루 단위로 구간 이동시간 합을 계산해서, 일정 강도별 기준(여유로운 일정 180분/빡빡한 일정 300분)을 넘으면 "Day N: 이동시간 합이 약 XX분으로 빡빡할 수 있습니다" 경고를 남김. 장소별 체류시간 데이터는 없어서 구간 이동시간만으로 근사 판단.
- `_build_time_slots()`에 `season` 파라미터 추가: 겨울이면 일조시간이 짧다고 보고 저녁 시간대 슬롯을 제외(예: 여유로운 일정 1박2일 기준 여름 5슬롯 → 겨울 4슬롯), "겨울철은 일조시간이 짧아 저녁 시간대 일정을 제외했습니다" 경고 문구 추가.
- 라이브 검증: 강릉 1박2일 동일 조건에서 여름 5슬롯 vs 겨울 4슬롯(저녁 슬롯만 빠짐) 확인.

### 2-7. 테스트

- `tests/test_route_planner.py` — RAG 경로, prefer_local 정렬, 코스 매칭(성공/실패/거리 윈도우), 지리 필터링, 일정 과밀도/계절 반영까지 총 17개 테스트
- 기존 `tests/test_react_loop.py`의 Mock fallback 테스트가 RAG 우선 구조 때문에 깨져서 수정 (RAG도 같이 막아야 완전 실패 시나리오가 재현됨)
- 최종 전체 테스트 **31개 통과**

---

## 2-8. Financial Agent — 실측 데이터 반영

기존엔 식비/카페비/입장료/숙박비가 전부 인당 고정값이었음. 이번에 다음을 실제 데이터 기반으로 교체:

**입장료**: TourAPI `detailIntro2`의 `usefee`(비정형 텍스트, 예: "어른 3,000원 / 청소년 2,000원")를
Upstage Solar로 구조화 추출(`parse_usefee_amount`, `app/core/prompts.py`에 전용 프롬프트 추가).
무료/파싱불가/정보없음을 구분해서 처리, 실패 시에만 기본값(5,000원) 사용.

**숙박비 — 선택 보장**: Route Planner가 여행이 1박 이상이면 `_search_lodging_place()`로 숙박 후보를
명시적으로 하나 골라둠 (기존엔 RAG가 우연히 숙박을 뽑아줄 때만 실제 요금이 반영됐음). 이미 선택된
관광지 군집과 15km 이내인 곳들 중, `prefer_budget`(Coordinator가 "가성비" 표현을 인식해서 넘기는
신호)이면 실제 요금 최저가, 아니면 rating 최고 순으로 정렬 — **그 정렬 순서에서 실제 요금 데이터가
있는 첫 번째 후보를 우선 선택**하도록 추가 개선(평점 1등이 요금 미등록이면 다음 순위 중 요금 있는
곳을 선택, 동점/전부 없으면 원래 1등 유지).

**숙박비 — 실제 계산**: TourAPI `detailInfo2`(객실 목록)에서 인원수(`roommaxcount` 기준 수용 가능한
객실 선택, 안 맞으면 같은 타입 객실 여러 개로 근사)와 성수기 여부(`is_peak_season`, Coordinator가
"8월 초", "여름휴가철" 같은 표현으로 판단해서 넘김)를 반영해 1박 요금을 계산. 계산 로직은
`app/utils/cost_rules.py`에 공용 함수로 모아서 Route Planner(선택 시점)와 Financial Agent(최종
청구 시점)가 동일한 로직을 재사용 — 선택 시점과 청구 시점의 판단이 어긋나지 않게 함.

**버그 발견 및 수정**: 실제 데이터로 검증하다가 특정 숙박업소의 요금 필드가 문자열 `"0"`으로
등록된 경우(무료가 아니라 데이터 미기재로 추정)를 발견 — 이를 "0원짜리 방"으로 잘못 인정해서
숙박비 전체가 0으로 계산되는 버그가 있었음. `to_positive_int()`로 0 이하 값을 무효 처리하도록 수정.
30건 표본 조사 결과 실제 요금 있음 53%, 0으로 잘못 등록됨 10%, 객실 정보 자체 없음 37% — 후자
두 경우는 기본 추정치로 자연스럽게 대체됨.

**prefer_budget/is_peak_season 신호**: 처음엔 route_planner.py에서 키워드 매칭으로 직접 판단하려
했으나, `prefer_local`과 동일한 이유(브랜치 로직으로는 한계가 있음)로 Coordinator가 Solar로 판단해서
`condition_summary`/State로 넘기는 방식으로 변경.

교통비 계산 시 하드코딩돼있던 `travel_days=2`도 실제 daily_schedule 기준 일수로 수정.

테스트(`test_financial.py`, `test_route_planner.py`) 다수 추가 — usefee 파싱, 인원수별 객실 수용
여부, 성수기 요금 우선순위, 0원 데이터 방어, 실요금 데이터 우선 선택 등. 최종 전체 테스트 **45개 통과**.

---

## 2-9. 최종 감사 — 3-Agent 완료 여부 정밀 검증

`docs/project_plan.md`를 전체 재점검하면서 갱신 안 된 stale 체크박스를 발견해서 정정함
(`transport_rules.py`, `cost_rules.py`, Financial Agent 세부 3항목이 실제로는 완료됐는데 미완료로
남아있었음 — Step 5 섹션에 Step 3와 중복된 체크리스트가 있어서 한쪽만 갱신했던 게 원인).

**실제 API 엔드포인트로 end-to-end 검증**: 그동안은 `run_triproute_coordinator()` 함수를 직접
호출해서만 확인했는데, `app/main.py`의 실제 FastAPI 엔드포인트(`/trip/plan`)를
`fastapi.testclient.TestClient`로 호출해서 검증함 — `app/agents/react_loop.py`가 이미
`run_triproute_coordinator()`로 위임하는 얇은 호환용 wrapper였음을 확인, 200 응답 + 정확한
`cost_summary`/`condition_summary`(`prefer_budget`/`is_peak_season` 포함) 확인 완료.

**최종 결론**:

| 항목 | 상태 |
|---|---|
| Coordinator | 완료 |
| Route Planner | 완료 |
| Financial Agent | 완료 |
| `/trip/plan` API 실제 동작 | 확인됨 |

3-Agent 로직 자체는 완료됐지만, **"전체 시스템"은 아직 남음** — 이건 별개 작업임:
- **LangGraph 미사용**: `app/graph/nodes.py`/`edges.py`/`workflow.py` 전부 빈 파일. Coordinator가
  Route Planner/Financial을 일반 함수 호출로 직접 부르는 구조, LangGraph StateGraph로 감싸는
  작업 자체가 안 됨
- **Gradio UI**: `ui/gradio_app.py` 파일은 있으나 내용 비어있음 (이번 세션에서 미착수)
- **Step 6 출력 포맷/스트리밍**: `formatter.py`, 타이핑 효과 스트리밍 등 미착수
- **`tests/test_rag.py`**: 파일만 있고 비어있음 (retriever.py 직접 테스트 케이스 없음,
  route_planner 테스트가 간접적으로만 커버 중)
- **Step 7/8**(시연 준비, GCP 배포): 별도 트랙, 미착수

---

## 3. 그 외 결정 사항

- **숙박비**: TourAPI `detailInfo2`로 객실별 성수기/비성수기 요금을 받을 수 있음을 확인 (새 API 연동 불필요). `get_detail_info()` 함수는 이번 작업에서 이미 구현됨 — Financial Agent 작업 때 그대로 재사용 가능.
- **프로젝트 배포 목표**: 로컬 실행에 그치지 않고 Docker 컨테이너화 + CI/CD 파이프라인으로 GCP(Cloud Run 유력)에 실제 서비스로 배포하는 것이 최종 목표임을 README/project_plan.md에 명문화 (Step 8 신설).

---

## 4. Route Planner 완료 상태

Route Planner Agent(Step 3 항목 + Step 5의 Route Planner 소관 항목)는 **모두 완료**됨:
RAG 연동, review_count/prefer_local 필터링, 연관 관광지(코스 기반) 추천, 다일차 코스 구간 제한,
지리적 효율성 필터링, 하루 일정 과밀도 체크, 계절(겨울) 반영까지 전부 구현·테스트·라이브 검증 완료.

## 5. 남은 일 (Step 3/5 전체 기준, Route Planner 외)

- **Financial Agent**: 지금 식비·카페비·입장료·숙박비가 전부 고정값 하드코딩. `usefee` 텍스트 파싱, `detailInfo2` 숙박 요금 반영 필요.
- **LangGraph 미사용**: `app/graph/nodes.py`/`edges.py`/`workflow.py` 전부 빈 파일. Coordinator가 일반 함수 호출로 처리 중, 그래프 조립 작업 필요.
