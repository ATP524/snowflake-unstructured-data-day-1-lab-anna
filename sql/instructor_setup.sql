USE ROLE all_users_role;
USE DATABASE bootcamp;
USE warehouse compute_wh;
USE SCHEMA atp524;

-- We need to do this to allow Snowflake access to external APIs!
CREATE OR REPLACE NETWORK RULE public_filing_hosts
    MODE = EGRESS TYPE = HOST_PORT
    VALUE_LIST = ('www.sec.gov', 'data.sec.gov', 'www.annualreports.com', 'annualreports.com');

CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION public_filing_access
    ALLOWED_NETWORK_RULES = (public_filing_hosts)
    ENABLED = TRUE;

CREATE STAGE IF NOT EXISTS annual_report_pdfs
    DIRECTORY = (ENABLE = TRUE)
    ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE');