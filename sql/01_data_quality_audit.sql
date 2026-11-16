/* ============================================================================
   FILE: 02_data_quality_audit.sql
   PROJECT: B2B SaaS Revenue & Churn Analytics Engine
   LAYER: Raw Staging Diagnostic Audit
   DESCRIPTION: Quantifies primary key duplicates, broken foreign keys, 
                negative transactions, temporal anomalies, and text 
                inconsistencies across all 6 staging tables.
   ============================================================================ */

WITH audit_checks AS (
    -- Check 1: Duplicate Primary Keys in stg_customers
    SELECT 
        1 AS check_id,
        'stg_customers' AS table_name,
        'Duplicate customer_id records (Fan-out join risk)' AS issue_description,
        'CRITICAL' AS severity,
        COUNT(*) - COUNT(DISTINCT customer_id) AS affected_rows
    FROM raw_staging.stg_customers

    UNION ALL

    -- Check 2: Broken Foreign Keys in stg_subscriptions (Case & trailing space mismatch)
    SELECT 
        2 AS check_id,
        'stg_subscriptions' AS table_name,
        'Unmatched plan_id foreign keys (P_PRO with trailing space)' AS issue_description,
        'CRITICAL' AS severity,
        COUNT(*) AS affected_rows
    FROM raw_staging.stg_subscriptions s
    LEFT JOIN raw_staging.stg_plans p 
        ON s.plan_id = p.plan_id
    WHERE p.plan_id IS NULL

    UNION ALL

    -- Check 3: Negative Payment Amounts in stg_payments
    SELECT 
        3 AS check_id,
        'stg_payments' AS table_name,
        'Negative payment amounts distorting revenue totals' AS issue_description,
        'HIGH' AS severity,
        COUNT(*) AS affected_rows
    FROM raw_staging.stg_payments
    WHERE amount <= 0

    UNION ALL

    -- Check 4: Temporal Logic Bug in stg_subscriptions (End date before start date)
    SELECT 
        4 AS check_id,
        'stg_subscriptions' AS table_name,
        'Time-travel bug: end_date occurs prior to start_date' AS issue_description,
        'HIGH' AS severity,
        COUNT(*) AS affected_rows
    FROM raw_staging.stg_subscriptions
    WHERE end_date IS NOT NULL 
      AND CAST(end_date AS DATE) < CAST(start_date AS DATE)

    UNION ALL

    -- Check 5: Pre-Signup Usage Events in stg_usage
    SELECT 
        5 AS check_id,
        'stg_usage' AS table_name,
        'Usage event_date occurs prior to customer signup_date' AS issue_description,
        'MEDIUM' AS severity,
        COUNT(*) AS affected_rows
    FROM raw_staging.stg_usage u
    INNER JOIN (
        SELECT DISTINCT customer_id, signup_date 
        FROM raw_staging.stg_customers
    ) c ON u.customer_id = c.customer_id
    WHERE CAST(u.event_date AS DATE) < CAST(c.signup_date AS DATE)

    UNION ALL

    -- Check 6: Missing Feature Telemetry in stg_usage
    SELECT 
        6 AS check_id,
        'stg_usage' AS table_name,
        'NULL feature_name in product usage logs' AS issue_description,
        'LOW' AS severity,
        COUNT(*) AS affected_rows
    FROM raw_staging.stg_usage
    WHERE feature_name IS NULL
)
SELECT 
    check_id,
    table_name,
    issue_description,
    severity,
    affected_rows
FROM audit_checks
ORDER BY check_id;