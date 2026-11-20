# Instructor setup

Date: 2026-11-16  
POC: Course instructor  
TL;DR: Configure shared integrations and role grants once, publish the pinned fixtures, and rehearse the lab as `all_users_role`.

All shell commands run from the lab root. SQL worksheets are in `sql/`, and Python scripts are in `python/`; worksheet basenames below refer to that SQL folder.

## Shared setup

The database is the existing `bootcamp`. Select a course-owned schema for network rules before running `instructor_setup.sql`. That script creates the shared `public_filing_access` external access integration and a stage in the selected schema. Students create their own stages separately; do not ask them to rerun shared integration setup.

For the Git connection, reuse the existing organization-wide integration. If provisioning another environment, run:

```sql
CREATE API INTEGRATION dataexpert_github_api
    API_PROVIDER = git_https_api
    API_ALLOWED_PREFIXES = ('https://github.com/DataExpert-io/')
    ENABLED = TRUE;
```

Grant course privileges using a role authorized to manage them:

```sql
GRANT USAGE ON DATABASE bootcamp TO ROLE all_users_role;
GRANT CREATE SCHEMA ON DATABASE bootcamp TO ROLE all_users_role;
GRANT CREATE INTEGRATION ON ACCOUNT TO ROLE all_users_role;
GRANT USAGE ON INTEGRATION dataexpert_github_api TO ROLE all_users_role;
GRANT USAGE ON INTEGRATION public_filing_access TO ROLE all_users_role;

GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE all_users_role;
GRANT USE AI FUNCTION AI_EXTRACT ON ACCOUNT TO ROLE all_users_role;
GRANT USE AI FUNCTION AI_PARSE_DOCUMENT ON ACCOUNT TO ROLE all_users_role;

-- Replace with the actual assigned warehouse.
GRANT USAGE ON WAREHOUSE COURSE_WAREHOUSE TO ROLE all_users_role;
```

### Integration permissions

Students need to create integrations for pipeline exercises later in the bootcamp. Grant `CREATE INTEGRATION` to `all_users_role` as part of the standard course setup and keep it enabled throughout the bootcamp. Run this in a Snowsight SQL worksheet as `ACCOUNTADMIN` (these grants are also included above):

```sql
USE ROLE ACCOUNTADMIN;

GRANT CREATE INTEGRATION ON ACCOUNT
    TO ROLE all_users_role;

GRANT USAGE ON INTEGRATION dataexpert_github_api
    TO ROLE all_users_role;
```

The first grant lets students create integrations; the second lets them use the existing course Git integration. Students can run their integration creation SQL after selecting the course role:

```sql
USE ROLE all_users_role;
```

`CREATE INTEGRATION` is an account-level privilege that applies beyond GitHub integrations. Sharing this capability through `all_users_role` is intentional in this learning environment. Some integration types also require supporting objects and permissions; grant those as needed for each pipeline exercise. Use course-scoped credentials for shared exercises and keep personal GitHub tokens under a private role and in a private schema.

At the end of the bootcamp, you can remove permission to create integrations:

```sql
USE ROLE ACCOUNTADMIN;

REVOKE CREATE INTEGRATION ON ACCOUNT
    FROM ROLE all_users_role;
```

Revoking this privilege does not remove integrations already created or their ownership privileges. Review those objects separately.

### Student role assignment

Assign `all_users_role` to students through your account's user provisioning process. Notebook/Workspace creation may require additional permissions for the account's enabled runtime. Test with an actual student account.

The Git integration permits access to repository URLs; `public_filing_access` permits HTTP requests from Snowflake-hosted Python. They are different integrations. The bundled starter needs no HTTP access.

Separate student schemas under one role prevent name collisions, not unauthorized access. Use distinct roles for enforced isolation.

## Publish the starter

Commit the Python/SQL files and all four files under `fixtures/`: the PDF, SEC JSON, manifest, and provenance README. The source artifacts together are about 4.7 MB. Check organizational rules for redistributing the source report before publishing the course repository.

The fixture builder was run locally to download the sources. The PDF headings, values, fiscal-calendar note, and matching Company Facts were checked. See [provenance](../fixtures/README.md).

Do not silently refresh the pinned files: a new SEC response has a different hash even if the selected facts are unchanged. To intentionally refresh, install `requests` and `pypdf`, set a real contact `SEC_USER_AGENT` in `python/build_starter_fixture.py`, and run:

```sh
python python/build_starter_fixture.py
```

Then review the report again, update hashes and metadata in `fixtures/starter_manifest.json`, and run tests. The builder writes artifacts; it does not automatically approve new hashes or page ranges.

For live-ingestion exercises, fetch source data once or stagger student downloads. Keep aggregate SEC traffic below 10 requests per second across clients.

## Rehearsal checklist

The hosted SQL/notebook flow has not been executed in this environment. Before class:

1. Connect the actual course remote using the configured integration.
2. Use `all_users_role` and a fresh student schema.
3. Confirm notebook imports and `session.file.put_stream` work in the assigned runtime.
4. Run `01.ddls.sql`, set the scope to AAPL 2023-2023 in `00.set_session_variables.ipynb`, then `load_starter(session)`; confirm the stage and approved manifest.
5. Run `04.prepare_manifest.sql`, `05.locate_statement_pages.sql` and `06.check_readiness.sql`; `pipeline_coverage` should show 2023 as READY.
6. Run `07.first_extraction.sql`, then the `08.extract_reports.ipynb` notebook with defaults and `09.evaluate_results.sql`; expect three metrics per method.
7. Repeat 08 with `include_all_metrics = TRUE` (a new `prompt_version`, so it re-extracts even with `only_new_reports = TRUE`); expect ten metrics per method.
8. Run `10.validation.sql` and check for duplicate run outputs.
9. Widen the scope to several years with live ingestion and confirm `pipeline_coverage` lists every year with a sensible `next_step`.
10. Confirm students can inspect intermediate Markdown and explain differences.
11. Check actual inference cost and runtime before setting class limits. Every runner query is tagged `lab:<step file>`; a role with `SNOWFLAKE.ACCOUNT_USAGE` access can group AI cost by step (query in [PRODUCTION.md](PRODUCTION.md)). `ALL_USERS_ROLE` does not have that access.
12. **Standing check:** before every class and after any code edit, Run All in `python/00.run_pipeline.ipynb` with both gates `False`. It is free; expect no `FAILED` step and every step 10 check passing.

Page selection keeps the starter small. Do not enable cross-region inference without organizational approval. Larger warehouse sizes do not guarantee faster document AI calls.

If a hosted runtime cannot upload streams, use [local loading](LOCAL_SETUP.md) to populate each student's stage, or provide an instructor-staged copy and grant appropriate read access.

## Offline checks

```sh
python3 -m unittest discover -s tests -v
```

Offline checks verify fixture integrity, pinned reference values, starter selection, and mocked ingestion/session behavior. They do not validate live Snowflake SQL compilation or hosted runtime support.

## References

- [Public Git integrations](https://docs.snowflake.com/en/developer-guide/git/git-setting-up-public)
- [Git-connected Workspaces](https://docs.snowflake.com/en/user-guide/ui-snowsight/workspaces-git)
- [Cortex privileges](https://docs.snowflake.com/en/user-guide/snowflake-cortex/aisql-privileges-and-access)
- [Notebook packages and runtime](https://docs.snowflake.com/en/user-guide/ui-snowsight/notebooks-in-workspaces/notebooks-in-workspaces-packages-runtime)
