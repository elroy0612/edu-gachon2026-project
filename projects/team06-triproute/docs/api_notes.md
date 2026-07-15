# API 사용 범위와 한계 정리

각 외부 API를 실제로 연결하면서 확인된 스펙, 발견된 제약, 사용법을 정리합니다.
공식 문서(Swagger)와 실제 동작이 다른 부분이 있으니, 여기 적힌 걸 우선 신뢰하세요.

---

## 1. TourAPI — 국문 관광정보 서비스_GW (`app/services/tour_api.py`)

- data.go.kr 서비스 ID: `15101578`
- Base URL: `https://apis.data.go.kr/B551011/KorService2`
- 인증: `TOUR_API_KEY` (`.env`) 를 `serviceKey` 쿼리 파라미터로 전달

### 사용 중인 오퍼레이션

| 오퍼레이션 | 용도 | 필수 파라미터 |
| --- | --- | --- |
| `searchKeyword2` | 키워드(도시명 등)로 관광지 검색 | `keyword`, `numOfRows`, `pageNo` |
| `detailCommon2` | 관광지 상세(주소·좌표·개요) 조회 | `contentId` |
| `detailIntro2` | 운영시간·쉬는날·이용요금 등 소개정보 조회 | `contentId`, **`contentTypeId` (필수! detailCommon2와 다름)** |

공통 파라미터: `serviceKey`, `MobileOS=ETC`, `MobileApp=TripRoute`, `_type=json`

### 실제 연결하며 발견한 제약사항

- **`searchKeyword2`에 `arrangeType` 파라미터를 넣으면 에러**
  (`INVALID_REQUEST_PARAMETER_ERROR(arrangeType)`) — 공식 문서엔 정렬 옵션으로 나오지만
  이 게이트웨이 버전에서는 지원하지 않음. **넣지 말 것.**
- **`detailCommon2`는 옵션 플래그(`overviewYN`, `addrinfoYN`, `mapinfoYN`, `defaultYN`,
  `firstImageYN`, `areacodeYN`, `catcodeYN`, `transGuideYN`, `contentTypeId`)를 전부 지원 안 함.**
  하나라도 같이 보내면 `INVALID_REQUEST_PARAMETER_ERROR(그 파라미터명)` 에러가 남.
  **`contentId`만 보내면 됨** — 기본 응답에 `overview`(개요), `addr1`(주소), `mapx`/`mapy`(좌표)가
  이미 다 포함되어 있음.
- **에러 응답 형식이 2가지임**:
  - 정상 응답: `{"response": {"header": {"resultCode": "0000", ...}, "body": {...}}}`
  - 파라미터 오류 등 게이트웨이 레벨 에러: `{"resultCode": "10", "resultMsg": "..."}` (최상위, `response` 래퍼 없음)
  → 코드에서 둘 다 처리해야 함 (`_request()` 참고).
- **운영시간·이용요금은 `detailCommon2`가 아니라 `detailIntro2`에 있음.** `detailIntro2`는
  `detailCommon2`와 반대로 **`contentTypeId`가 필수**임 (안 넣으면
  `NO_MANDATORY_REQUEST_PARAMETERS_ERROR1(contentTypeId)`).
- **`usefee`는 콘텐츠 타입마다 있고 없음.** 관광지(12, 예: 공원)는 `usetime`(운영시간)만
  있고 `usefee` 필드 자체가 없음(무료라서). 문화시설(14, 예: 오죽헌 시립박물관)은
  `usefee`에 실제 요금 텍스트가 들어옴 (예: `"어른 : 개인 3,000원 / 단체 2,000원..."`).
  즉 **모든 관광지가 유료는 아니며, usefee 유무 자체가 유료/무료를 구분하는 신호가 됨.**
  Financial Agent(Step 5)에서 usefee 없으면 무료로 처리하면 됨.
- 콘텐츠 타입별로 `detailIntro2` 응답 필드명이 다름 (예: 관광지는 `usetime`/`restdate`,
  문화시설은 `usetimeculture`/`restdateculture`) — 타입별 필드 매핑표는 나중에 필요해지면 추가.
- **대량 호출 시 `429 Too Many Requests`가 실제로 발생함.** 10개 도시 × 6개 카테고리(약 1,500건
  검색 + 900건 이상 상세조회)를 짧은 시간에 몰아서 호출하니, 마지막 도시(서울) 처리 중 다수의
  `detailCommon2` 호출이 429로 실패함 (재시도 3회를 다 써도 안 풀림 — 순간적 요청 폭주라 backoff
  몇 초로는 부족했음). 대응: 이후 배치 작업(카테고리 백필 등)에는 호출 사이에 0.2~1초 딜레이를
  추가함. 대량 수집을 다시 할 일이 있으면 처음부터 호출 간 딜레이를 넣거나, 도시별로 시간을
  나눠서 실행하는 걸 권장.
- 한글이 터미널(Git Bash)에 깨져 보이는 건 콘솔 코드페이지 문제일 뿐, 실제 응답 데이터의
  인코딩은 UTF-8로 정상임 (파일로 저장해서 확인함).
- **결과 0건일 때 `items`가 `{}`가 아니라 `""`(빈 문자열)로 내려오는 경우가 있음.**
  `body.get("items", {}).get("item", [])`처럼 짜면 `''.get(...)`에서 `AttributeError`로 죽는다.
  `tour_api.py`의 `_extract_items()` 헬퍼로 방어 처리함 (items가 dict가 아니면 빈 리스트 반환).

### TourAPI 대량 수집 이슈 (강릉/속초/춘천/부산/제주/경주/전주/여수/인천/서울 10개 도시 수집 중 발견)

- **`searchKeyword2`는 전국 대상 키워드 검색이라, 도시 이름으로 검색해도 그 도시에 없는 동명
  상호가 대거 섞여 들어온다.** 예: "부산" 검색 시 충청북도 옥천군의 "부산식당", 서울의
  "부산복집" 등 전국 각지의 동명 식당이 결과에 포함됨. 실측 결과 전체 수집 데이터의 약
  18%가 이런 지역 불일치 오염 데이터였음. **대응**: `vector_store.py`의
  `CITY_TO_REGION_PREFIXES`로 도시별 실제 주소 접두사를 정의해두고, `addr1`이 여기 안 맞으면
  저장 전에 걸러냄 (`_is_in_expected_region`). 주소가 아예 없는 항목(여행코스 등, 단일 주소가
  없는 콘텐츠 타입)도 동선 계산에 못 쓰므로 같이 제외함.
- **`DEFAULT_CONTENT_TYPE_IDS`에 32(숙박)/38(쇼핑)이 원래 빠져있었음.** 그래서 초기 수집분은
  대부분 도시에 숙박·쇼핑 데이터가 아예 없었음 — 나중에 발견해서 추가하고 별도로 보충 수집함.
  새 도시를 수집할 땐 이 8개 타입(`12,14,15,25,28,32,38,39`)이 다 포함됐는지 확인할 것.
- **`contenttypeid` 필드가 문자열("12")이 아니라 숫자(12)로 내려올 때가 있어서**, dict 키 조회 시
  `str()`로 정규화 안 하면 category가 계속 `None`으로 저장되는 버그가 있었음
  (`content_type_id_to_category`에서 처리함).

---

## 2. 연관 관광지 정보 (`app/services/related_place_api.py`)

- data.go.kr 서비스 ID: `15128560` (한국관광공사_관광지별 연관 관광지 정보)
- 서비스명(영문): `TarRlteTarService1`
- Base URL: `https://apis.data.go.kr/B551011/TarRlteTarService1`
- TourAPI(15101578)와는 **별개 서비스**지만, data.go.kr 계정당 인증키가 1개라 `TOUR_API_KEY`를
  그대로 재사용함 (활용신청만 서비스별로 따로 진행). `config.py`에 `RELATED_PLACE_API_KEY`라는
  별도 필드가 있었는데 `.env`에 값이 없어서 항상 `None`이었음 — 삭제하고 `TOUR_API_KEY`로 통일함.
- **일반 TourAPI(`KorService2`)와 오퍼레이션 이름이 겹치지 않게 주의**: 이 서비스는
  `KorService1`/`KorService2`와 무관한 완전히 다른 서비스(`TarRlteTarService1`)임.
  Swagger에 보이는 오퍼레이션 이름이 `areaBasedList1`/`searchKeyword1`이라고 TourAPI의
  `KorService1`로 착각하면 안 됨 (실제로 `KorService1`은 500 에러 남).

### 사용 중인 오퍼레이션

| 오퍼레이션 | 용도 | 필수 파라미터 |
| --- | --- | --- |
| `areaBasedList1` | 시군구 내 관광지들의 연관 관광지 목록 조회 | `baseYm`, `areaCd`, `signguCd` |
| `searchKeyword1` | 관광지명 검색 후 그 연관 관광지 목록 조회 | `baseYm`, `areaCd`, `signguCd`, `keyword` |

- `baseYm`(기준연월, YYYYMM 형식)은 필수지만, **실제로는 어떤 달 값을 넣어도 같은 최신
  스냅샷을 반환함** (202504~202606 다 테스트해봄). 정확한 유효 범위는 알 수 없으나
  일단 아무 값이나 넣어도 문제는 없음 → `related_place_api.py`의 `DEFAULT_BASE_YM` 참고.
- `areaCd`/`signguCd`는 법정동코드 기준. 강원특별자치도=`51`, 강릉시=`51150`.
  다른 도시 코드가 필요해지면 행정표준코드관리시스템에서 조회해야 함.
- 응답 핵심 필드: `tAtsNm`(기준 관광지명), `rlteTatsNm`(연관 관광지명), `rlteRank`(연관순위),
  `rlteCtgryLclsNm`(연관 카테고리: 관광지/음식/숙박 등).
- `searchKeyword1`으로 "경포대" 검색 시 연관 관광지로 경포해변·강릉중앙시장·오죽헌·안목해변이
  나옴 — README 예시 일정표와 거의 일치해서 실제 추천 로직에 바로 쓸 만함.

---

## 3. 카카오모빌리티 길찾기 (`app/services/kakao_mobility.py`)

- Base URL: `https://apis-navi.kakaomobility.com/v1/directions`
- 인증: `KAKAO_MOBILITY_API_KEY`를 `Authorization: KakaoAK {키}` 헤더로 전달 (쿼리 파라미터 아님!)
- 좌표 순서: `origin`/`destination` 모두 **"경도,위도"** 순서 (TourAPI의 `mapx`(경도)/`mapy`(위도)와
  순서가 그대로 일치해서 별도 변환 없이 바로 연결 가능함)
- 응답에서 쓰는 필드: `routes[0].summary.distance`(미터), `.duration`(초),
  `.fare.taxi`(택시요금), `.fare.toll`(통행료) — README가 요구하는 4가지 정보(거리·시간·택시비·통행료)를
  이 API 하나로 전부 커버함
- 정상 응답인지는 `routes[0].result_code == 0`으로 판단 (다른 API들처럼 `resultCode: "0000"` 형식이 아님, 정수 `0`)
- TourAPI와 달리 스펙이 안정적이라 문서 그대로 구현해서 첫 시도에 성공함 (실측: 안목해변→강릉중앙시장
  7.1km, 19분, 택시 12,900원, 통행료 0원)

---

## 4. Upstage Solar (`app/services/upstage_client.py`)

- OpenAI Python SDK와 호환되는 방식. `OpenAI(api_key=UPSTAGE_API_KEY, base_url="https://api.upstage.ai/v1")`로
  클라이언트를 만들고, 이후 `client.chat.completions.create(...)` / `client.embeddings.create(...)`를
  OpenAI SDK 쓰듯 그대로 호출하면 됨.
- **Chat 모델**: `solar-pro2` 사용. (참고: `response_format`(구조화 출력)은 `solar-pro-2`에서만
  지원되고 최신 `solar-pro3`에서는 아직 안 됨 — Coordinator Agent에서 구조화 추출 쓸 때 `solar-pro2` 유지할 것)
- **Embedding 모델은 "범용 1개"가 아니라 용도별 2개로 분리되어 있음**:
  질의용 `solar-embedding-1-large-query`, 문서 저장용 `solar-embedding-1-large-passage`.
  짧은 검색 질의와 긴 저장 문서는 문장 성격이 달라서, Upstage가 각각에 최적화된 모델을
  따로 제공함 (하나의 범용 모델로 둘 다 처리하는 것보다 검색 정확도가 높음).
  같은 4096차원 벡터공간이라 서로 비교 가능하지만, 반드시 용도에 맞는 모델을 써야 함
  (RAG 저장 시 passage, 사용자 취향 검색 시 query).
- 벡터 차원: **4096** (Supabase pgvector 테이블 컬럼 차원을 이 값으로 맞춰야 함 — Step 4에서 주의).
- 실제 호출 다 성공함 (chat 답변 생성, query/passage 임베딩 둘 다 4096차원 확인).

---

## 5. Supabase (`app/services/supabase_client.py`)

- `SUPABASE_KEY`는 `sb_publishable_...` 형식 — Supabase의 신규 키 체계에서 구 `anon` 키에
  해당하는 **클라이언트용 저권한 키**임 (RLS 적용, REST API 데이터 조작만 가능).
- **연결 테스트 방법 주의**: `/rest/v1/` 루트(스키마 조회용 OpenAPI 문서)는
  `secret` 키만 허용하고 `publishable` 키는 401(`"Secret API key required"`)이 남 —
  이건 정상이고 키가 잘못된 게 아님. 대신 실제 테이블 조회(`client.table(...).select(...)`)로
  테스트해야 함 — 존재하지 않는 테이블을 조회하면 `PGRST205`(테이블 없음) 에러가 나는데,
  이게 "인증은 통과했다"는 뜻이라 연결 확인 성공으로 간주함.
- **pgvector 확장은 이 키로 활성화 불가.** `CREATE EXTENSION vector;` 같은 DB 관리자 작업은
  PostgREST(REST API) 범위 밖이라 `publishable`/`anon` 키로는 절대 안 됨.
  **Supabase 대시보드 → SQL Editor에서 직접 실행해야 함**:
  ```sql
  create extension if not exists vector;
  ```
  Step 4(RAG 구현) 시작하기 전에 팀원 중 Supabase 프로젝트 소유자가 실행해야 함.
- pgvector 테이블 만들 때 벡터 컬럼 차원은 **4096**으로 맞출 것 (Upstage 임베딩 차원, 위 4번 참고).

### pgvector 세팅 완료 (SQL Editor에서 수동 실행함)

```sql
create extension if not exists vector;

create table if not exists places (
    id bigserial primary key,
    content_id text unique not null,
    title text not null,
    address text,
    overview text,
    category text,
    embedding vector(4096),
    event_start_date date,
    event_end_date date,
    rating numeric,
    review_count integer,
    created_at timestamptz default now()
);

create or replace function match_places(
    query_embedding vector(4096),
    match_count int default 5
)
returns table (
    id bigint,
    content_id text,
    title text,
    overview text,
    similarity float
)
language sql stable
as $$
    select id, content_id, title, overview,
           1 - (embedding <=> query_embedding) as similarity
    from places
    order by embedding <=> query_embedding
    limit match_count;
$$;
```

- **HNSW/IVFFlat 인덱스는 안 만듦.** pgvector의 인덱스는 최대 2000차원까지만 지원하는데
  Upstage 임베딩은 4096차원이라 인덱스 생성 자체가 에러남
  (`column cannot have more than 2000 dimensions for hnsw index`).
  지금 규모(관광지 몇백 건)에서는 인덱스 없는 전체 스캔으로도 충분함. 나중에 필요해지면
  `halfvec` 타입(용량 절반이라 인덱싱 가능 차원이 늘어남) 또는 임베딩 자체를 2000차원 이하로
  축소해서 별도 인덱스용 컬럼을 두는 방법을 검토.
- **PostgREST(REST API)는 벡터 거리 정렬을 표현할 방법이 없어서, `match_places`라는 Postgres
  함수를 만들고 `client.rpc("match_places", {...})`로 호출하는 방식을 씀.**
- `app/services/supabase_client.py`의 `insert_place`(upsert)와 `search_similar_places`(RPC 호출)로
  실제 강릉 관광지 5개 임베딩 저장 + 취향 문장 검색까지 end-to-end 테스트 성공함.
- `event_start_date`/`event_end_date`/`rating`/`review_count` 컬럼은 나중에 각각
  `alter table places add column if not exists ...`로 추가함 (SQL Editor에서 수동 실행,
  Supabase REST API로는 DDL 불가). 위 `create table` 문에는 최신 스키마 기준으로 반영해뒀음.
- **`select()`가 기본적으로 1000행까지만 반환함(PostgREST 기본 페이지 제한).** 전체 조회할 땐
  `.range(start, start+999)`로 페이지네이션 안 하면 실제로는 더 많은 행이 있는데도 1000건인 줄
  착각하게 됨 — 데이터 정리 작업 중 실제 1024건을 1000건으로 잘못 파악해서 24건을 놓친 적 있음.

---

## 6. Google Places API (New) — 평점/리뷰수 보강 (`app/services/google_places_api.py`)

- **왜 필요한가**: TourAPI(한국관광공사)는 공식 등록 DB라 별점/리뷰 필드가 아예 없고, 카카오
  로컬 API·네이버 검색 API도 별점·리뷰수 필드를 안 줌. 별점/리뷰수를 제공하는 API는 Google
  Places가 사실상 유일함.
- **Legacy 말고 반드시 New 버전을 쓸 것.** Places API(Legacy)는 2025년 3월부로 동결되어
  **신규 프로젝트에서는 활성화 자체가 안 됨.** Google Cloud Console에서 라이브러리 검색할 때도
  "Places API"가 아니라 "**Places API (New)**"를 활성화해야 함.
- Base URL: `https://places.googleapis.com/v1/places:searchText` (POST, JSON body)
- 인증: 쿼리 파라미터가 아니라 `X-Goog-Api-Key` 헤더로 전달. 응답 필드를 제한하려면
  `X-Goog-FieldMask` 헤더가 **필수**임 (없으면 대부분 필드가 빈 응답으로 옴).
- 응답 필드명이 Legacy와 다름: `user_ratings_total`이 아니라 **`userRatingCount`**(camelCase).
- **이름 텍스트 검색만으로는 심각한 오매칭이 발생함.** 실측: "존재하지않는가상의장소12345"라는
  완전 가짜 이름을 검색했는데, 서울의 "이혼·상속 전문로펌 법무법인 **존재**"가 매칭됨
  (상호명에 "존재"라는 글자가 겹친다는 이유만으로). 카테고리·거리 제약이 없는 순수 텍스트
  유사도 검색이라 이런 사고가 실제로 남.
  - 주소 문자열 비교(시/군 토큰 일치 검증)로 오매칭을 걸러보려 했으나, 안목해변처럼
    `formattedAddress`에 시/군 표기가 아예 없는 자연 명소(관광지)를 오히려 걸러내는
    부작용이 있어서 채택하지 않음.
  - **대신 TourAPI의 `mapx`(경도)/`mapy`(위도)로 `locationBias`(원형 반경, 기본 500m)를 걸어
    검증함 — 실측 결과 이 방식만으로 위 오매칭 사고가 재현되지 않음.** `find_place()`/
    `get_rating_and_review_count()` 호출 시 **가능하면 항상 lat/lng을 같이 넘길 것.**
    좌표 없이 이름만으로 부르면 오매칭 위험이 남음.
- 매칭 실패(또는 검색 결과 없음) 시 `rating`/`review_count` 둘 다 `None`으로 저장됨. **이건
  삭제 대상이 아님** — Google에 등록 안 된 정상적인 로컬 장소일 뿐이고, 오히려 review_count
  기반 "로컬/hidden-gem" 필터링(Step 3 참고)에 유용한 신호가 될 수 있음.
- 결제 계정 등록이 필수 (등록 안 하면 API 활성화가 안 됨). 신규 Google Cloud 계정은 보통
  크레딧을 줘서 이 프로젝트 규모에서는 과금 걱정이 거의 없음.
