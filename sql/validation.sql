-- Run after evaluate_results.sql. These checks do not call AI or modify data.
-- Every row should say PASS.
WITH cases AS (
    SELECT column1 AS input, column2::FLOAT AS expected
    FROM VALUES ('383285', 383285), ('6.13', 6.13), ('(123.50)', -123.50),
        ('-45', -45), ('0', 0), ('NOT_FOUND', NULL), ('1,234', NULL),
        ('$123', NULL), ('12 million', NULL), ('', NULL)
)
SELECT input, expected, lab_number(input) AS actual,
       IFF(EQUAL_NULL(actual, expected), 'PASS', 'FAIL') AS test_status
FROM cases;

WITH cases AS (
    SELECT column1 AS label, column2::STRING AS printed,
           column3::STRING AS scale, column4::FLOAT AS reference,
           column5::FLOAT AS abs_tolerance, column6::FLOAT AS rel_tolerance,
           column7::BOOLEAN AS expected_pass
    FROM VALUES
        ('USD millions', '383285', '1000000', 383285000000, 1000000, 0.0001, TRUE),
        ('EPS unscaled', '6.13', '1', 6.13, 0.01, 0, TRUE),
        ('Wrong scale', '383285', '1', 383285000000, 1000000, 0.0001, FALSE),
        ('Negative cash flow', '(123)', '1000000', -123000000, 1000000, 0.0001, TRUE),
        ('Zero reference inside absolute tolerance', '0.005', '1', 0, 0.01, 0, TRUE),
        ('Zero reference outside absolute tolerance', '2', '1', 0, 0.01, 0, FALSE)
)
SELECT label,
       ABS(lab_number(printed) * lab_number(scale) - reference)
           <= GREATEST(abs_tolerance, ABS(reference) * rel_tolerance) AS actual_pass,
       IFF(actual_pass = expected_pass, 'PASS', 'FAIL') AS test_status
FROM cases;

-- Should return no rows. Repeated manual INSERTs can duplicate a run/method.
SELECT run_id, method, COUNT(*) AS copies
FROM extraction_results
GROUP BY run_id, method HAVING COUNT(*) > 1;

-- Should return no rows.
SELECT run_id, COUNT(*) AS copies
FROM lab_runs GROUP BY run_id HAVING COUNT(*) > 1;
