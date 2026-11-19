USE ROLE all_users_role;
USE DATABASE bootcamp;
USE warehouse compute_wh;
USE SCHEMA atp524;

-- Synthetic earnings evaluation: run one numbered step at a time.
-- First generate the five reports. Use the same database and student schema.
-- This lesson checks numeric accuracy only.
-- For unit, period, and evidence checks, use 13.evaluate_synthetic.sql.

-- 1. Look at the correct answers.
-- Expect 50 rows: five reports with ten metrics each.
SELECT ticker, metric_id, expected_value, expected_unit
FROM synthetic_ground_truth
ORDER BY ticker, metric_id;

-- 2. Write a question for each metric, then group questions by PDF.
-- OBJECT_AGG makes a dictionary: metric_id -> question.
-- We give the model field names and dates, but NEVER the correct numbers.
CREATE OR REPLACE TEMP TABLE student_question_list AS
SELECT
    relative_path,
    metric_id,
    'Find ' || metric_label ||
        ' in the consolidated financial statements for the fiscal year ending ' ||
        TO_CHAR(period_end, 'YYYY-MM-DD') || '. ' ||
        'Ignore comparative years and rounded summary figures. ' ||
        'Return the value in ' || expected_unit || ' as a signed number only, ' ||
        'with no commas or currency symbols. ' ||
        'Convert amounts in millions to dollars by multiplying by 1000000. ' ||
        'Do not multiply earnings per share. Return NOT_FOUND if absent.'
        AS question
FROM synthetic_ground_truth;

-- Read the 50 individual questions first.
SELECT * FROM student_question_list ORDER BY relative_path, metric_id;

-- Bundle each PDF's ten questions into one dictionary.
CREATE OR REPLACE TEMP TABLE student_questions AS
SELECT relative_path, OBJECT_AGG(metric_id, question) AS questions
FROM student_question_list
GROUP BY relative_path;

-- Expect five rows. Read the questions before calling AI.
SELECT * FROM student_questions;

-- 3. Run both extraction paths. Only this step calls AI.
-- Five PDFs: five direct extractions, five parses, up to five text extractions.
-- Rerunning this step repeats inference charges. Scoring never calls AI.
CREATE OR REPLACE TEMP TABLE student_answers AS
SELECT
    relative_path,
    'DIRECT_PDF' AS method,
    AI_EXTRACT(
        file => FL_FILTER_PAGES(TO_FILE('@annual_report_pdfs', relative_path),
                    ARRAY_CONSTRUCT(OBJECT_CONSTRUCT('start', 1, 'end', 5))),
        responseFormat => questions
    ) AS result
FROM student_questions;

-- Path B: PDF -> Markdown -> structured answers.
-- page_split=FALSE returns one content field instead of a pages array.
CREATE OR REPLACE TEMP TABLE student_parsed AS
SELECT relative_path,
       AI_PARSE_DOCUMENT(
           TO_FILE('@annual_report_pdfs', relative_path),
           OBJECT_CONSTRUCT('mode', 'LAYOUT', 'page_split', FALSE,
               'page_filter', ARRAY_CONSTRUCT(OBJECT_CONSTRUCT('start', 1, 'end', 5))),
           TRUE
       ) AS parsed_result
FROM student_questions;

-- Inspect content and errors BEFORE running text extraction.
CREATE OR REPLACE TEMP TABLE student_markdown AS
SELECT relative_path,
       parsed_result:value:content::STRING AS markdown,
       parsed_result:error::STRING AS parse_error,
       parsed_result:value:error::STRING AS document_error
FROM student_parsed;

SELECT *, LENGTH(markdown) AS characters FROM student_markdown;

INSERT INTO student_answers (relative_path, method, result)
SELECT questions.relative_path, 'PARSE_THEN_EXTRACT',
       AI_EXTRACT(text => parsed.markdown, responseFormat => questions.questions)
FROM student_questions AS questions
JOIN student_markdown AS parsed
    ON questions.relative_path = parsed.relative_path
WHERE parsed.parse_error IS NULL AND parsed.document_error IS NULL
  AND LENGTH(parsed.markdown) BETWEEN 1 AND 60000;
-- The 60,000-character limit is a lab guardrail, not a model limit.
-- Failed, empty, or oversized parses are not truncated; their missing answers
-- remain in the scoring denominator. Inspect student_markdown to diagnose them.

-- The response is a dictionary: metric_id -> extracted answer.
-- Check for errors here before scoring.
SELECT relative_path, method, result:response AS answers, result:error AS error
FROM student_answers;

-- 4. Match each answer to its ground truth.
-- LEFT JOIN keeps the expected row even if an answer is missing.
-- GET looks up a metric in the response dictionary.
-- TRY_TO_DOUBLE returns NULL when the answer is not a number.
CREATE OR REPLACE TEMP TABLE student_comparison AS
SELECT
    truth.ticker,
    methods.method,
    truth.metric_id,
    truth.expected_unit,
    truth.expected_value,
    TRY_TO_DOUBLE(
        GET(answers.result:response, truth.metric_id)::STRING
    ) AS extracted_value,
    answers.result:error::STRING AS extraction_error
FROM synthetic_ground_truth AS truth
CROSS JOIN (SELECT column1 AS method FROM VALUES
    ('DIRECT_PDF'), ('PARSE_THEN_EXTRACT')) AS methods
LEFT JOIN student_answers AS answers
    ON truth.relative_path = answers.relative_path
   AND methods.method = answers.method;

SELECT * FROM student_comparison ORDER BY ticker, metric_id;

-- 5. Mark each answer and calculate a score.
-- Allow half a cent for EPS and half a dollar for other amounts.
-- Missing, invalid, and failed extractions count as incorrect.
CREATE OR REPLACE TEMP TABLE student_scores AS
SELECT
    *,
    CASE
        WHEN extraction_error IS NOT NULL THEN 'ERROR'
        WHEN extracted_value IS NULL THEN 'MISSING'
        WHEN ABS(extracted_value - expected_value) <=
             CASE WHEN expected_unit = 'USD/shares' THEN 0.005 ELSE 0.5 END
            THEN 'PASS'
        ELSE 'FAIL'
    END AS status
FROM student_comparison;

-- Read the individual results.
SELECT ticker, method, metric_id, expected_value, extracted_value, status
FROM student_scores
ORDER BY ticker, metric_id;

-- Accuracy for each report: correct answers / expected answers.
SELECT
    ticker,
    method,
    COUNT(*) AS expected_answers,
    SUM(CASE WHEN status = 'PASS' THEN 1 ELSE 0 END) AS correct_answers,
    ROUND(100.0 * SUM(CASE WHEN status = 'PASS' THEN 1 ELSE 0 END)
          / NULLIF(COUNT(*), 0), 1) AS accuracy_percent
FROM student_scores
GROUP BY ticker, method
ORDER BY ticker, method;

-- Overall comparison: expect 50 answers PER METHOD (100 comparison rows).
SELECT
    method,
    COUNT(*) AS expected_answers,
    SUM(CASE WHEN status = 'PASS' THEN 1 ELSE 0 END) AS correct_answers,
    ROUND(100.0 * SUM(CASE WHEN status = 'PASS' THEN 1 ELSE 0 END)
          / NULLIF(COUNT(*), 0), 1) AS accuracy_percent
FROM student_scores
GROUP BY method
ORDER BY method;

-- Discussion:
-- Did the model forget to multiply a value in millions?
-- Did it choose a comparative year instead of the requested year?
-- Does a correct number prove the model used the right evidence?
