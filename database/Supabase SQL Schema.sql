


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";






CREATE TYPE "public"."agent_type_enum" AS ENUM (
    'orchestrator',
    'planner',
    'risk_assessor',
    'status_reporter',
    'milestone_tracker',
    'resource_advisor',
    'clarification_guard'
);


ALTER TYPE "public"."agent_type_enum" OWNER TO "postgres";


CREATE TYPE "public"."milestone_status_enum" AS ENUM (
    'Pending',
    'On track',
    'At risk',
    'Completed',
    'Missed'
);


ALTER TYPE "public"."milestone_status_enum" OWNER TO "postgres";


CREATE TYPE "public"."priority_level_enum" AS ENUM (
    'Low',
    'Medium',
    'High',
    'Critical'
);


ALTER TYPE "public"."priority_level_enum" OWNER TO "postgres";


CREATE TYPE "public"."project_status_enum" AS ENUM (
    'Planning',
    'Active',
    'On hold',
    'Completed',
    'Cancelled'
);


ALTER TYPE "public"."project_status_enum" OWNER TO "postgres";


CREATE TYPE "public"."risk_category_enum" AS ENUM (
    'Data Quality & Availability',
    'Integration Issues',
    'Talent & Skills Gap',
    'Change Resistance',
    'Ethical & Legal Concerns',
    'Cost Overruns',
    'Unrealistic Expectations',
    'Model Performance Drift',
    'Security Vulnerabilities',
    'Vendor Lock-in',
    'Other'
);


ALTER TYPE "public"."risk_category_enum" OWNER TO "postgres";


CREATE TYPE "public"."risk_severity_enum" AS ENUM (
    'Low',
    'Medium',
    'High',
    'Critical'
);


ALTER TYPE "public"."risk_severity_enum" OWNER TO "postgres";


CREATE TYPE "public"."risk_status_enum" AS ENUM (
    'Open',
    'Mitigating',
    'Accepted',
    'Closed'
);


ALTER TYPE "public"."risk_status_enum" OWNER TO "postgres";


CREATE TYPE "public"."sprint_status_enum" AS ENUM (
    'Planned',
    'Active',
    'Completed'
);


ALTER TYPE "public"."sprint_status_enum" OWNER TO "postgres";


CREATE TYPE "public"."task_status_enum" AS ENUM (
    'To Do',
    'In Progress',
    'Done',
    'Blocked'
);


ALTER TYPE "public"."task_status_enum" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."ingest_excel_project"("p_project" "jsonb", "p_phases" "jsonb" DEFAULT '[]'::"jsonb", "p_milestones" "jsonb" DEFAULT '[]'::"jsonb", "p_tasks" "jsonb" DEFAULT '[]'::"jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  v_dept_id uuid;
  v_project_id uuid;
  v_item jsonb;
  v_phase_id uuid;
  v_sprint_id uuid;
  v_milestone_id uuid;
  v_assignee_id uuid;
  v_phase_count int := 0;
  v_milestone_count int := 0;
  v_task_count int := 0;
BEGIN
  -- 1. RESOLVE DEPARTMENT (Defaults to DEPT-AI)
  SELECT id INTO v_dept_id
  FROM departments
  WHERE dept_code = COALESCE(NULLIF(p_project->>'dept_code', ''), 'DEPT-AI')
  LIMIT 1;

  -- 2. UPSERT PROJECT
  INSERT INTO projects (
    department_id, project_code, client_name, title, description, start_date, target_end_date, status
  )
  VALUES (
    v_dept_id,
    p_project->>'project_code',
    p_project->>'client_name',
    p_project->>'title',
    COALESCE(NULLIF(p_project->>'description', ''), 'Imported via Excel'),
    NULLIF(p_project->>'start_date', '')::date,
    NULLIF(p_project->>'target_end_date', '')::date,
    'Active'
  )
  ON CONFLICT (project_code) DO UPDATE SET
    client_name = EXCLUDED.client_name,
    title = EXCLUDED.title,
    description = EXCLUDED.description,
    start_date = COALESCE(EXCLUDED.start_date, projects.start_date),
    target_end_date = COALESCE(EXCLUDED.target_end_date, projects.target_end_date)
  RETURNING id INTO v_project_id;

  -- 3. UPSERT PROJECT PHASES
  FOR v_item IN SELECT * FROM jsonb_array_elements(COALESCE(p_phases, '[]'::jsonb))
  LOOP
    INSERT INTO project_phases (
      project_id, phase_number, phase_name, start_week, end_week, key_activities
    )
    VALUES (
      v_project_id,
      (v_item->>'phase_number')::int,
      v_item->>'phase_name',
      COALESCE(NULLIF(v_item->>'start_week', '')::int, 1),
      COALESCE(NULLIF(v_item->>'end_week', '')::int, 2),
      string_to_array(COALESCE(v_item->>'key_activities', ''), ';')
    )
    ON CONFLICT (project_id, phase_number) DO UPDATE SET
      phase_name = EXCLUDED.phase_name,
      start_week = EXCLUDED.start_week,
      end_week = EXCLUDED.end_week,
      key_activities = EXCLUDED.key_activities;

    v_phase_count := v_phase_count + 1;
  END LOOP;

  -- 4. UPSERT MILESTONES (Links to Phase & Target Sprint)
  FOR v_item IN SELECT * FROM jsonb_array_elements(COALESCE(p_milestones, '[]'::jsonb))
  LOOP
    -- Resolve Phase UUID by phase_number
    SELECT id INTO v_phase_id
    FROM project_phases
    WHERE project_id = v_project_id
      AND phase_number = NULLIF(v_item->>'phase_number', '')::int
    LIMIT 1;

    -- Resolve or auto-create Target Sprint UUID
    IF v_item->>'target_sprint' IS NOT NULL AND v_item->>'target_sprint' <> '' THEN
      INSERT INTO sprints (project_id, sprint_number, sprint_name, start_date, end_date, status)
      VALUES (
        v_project_id,
        COALESCE(NULLIF(regexp_replace(v_item->>'target_sprint', '\D', '', 'g'), '')::int, 1),
        v_item->>'target_sprint',
        CURRENT_DATE,
        CURRENT_DATE + INTERVAL '14 days',
        'Planned'
      )
      ON CONFLICT (project_id, sprint_name) DO UPDATE SET sprint_name = EXCLUDED.sprint_name
      RETURNING id INTO v_sprint_id;
    ELSE
      v_sprint_id := NULL;
    END IF;

    INSERT INTO project_milestones (
      project_id, phase_id, target_sprint_id, milestone_code, title, due_date, priority, status
    )
    VALUES (
      v_project_id,
      v_phase_id,
      v_sprint_id,
      v_item->>'milestone_code',
      v_item->>'title',
      COALESCE(NULLIF(v_item->>'due_date', '')::date, CURRENT_DATE + INTERVAL '30 days'),
      COALESCE(NULLIF(v_item->>'priority', ''), 'High')::priority_level_enum,
      COALESCE(NULLIF(v_item->>'status', ''), 'Pending')::milestone_status_enum
    )
    ON CONFLICT (project_id, milestone_code) DO UPDATE SET
      phase_id = COALESCE(EXCLUDED.phase_id, project_milestones.phase_id),
      target_sprint_id = COALESCE(EXCLUDED.target_sprint_id, project_milestones.target_sprint_id),
      title = EXCLUDED.title,
      due_date = EXCLUDED.due_date,
      priority = EXCLUDED.priority,
      status = EXCLUDED.status;

    v_milestone_count := v_milestone_count + 1;
  END LOOP;

  -- 5. UPSERT PROJECT TASKS (Links to Sprint, Milestone & Assignee)
  FOR v_item IN SELECT * FROM jsonb_array_elements(COALESCE(p_tasks, '[]'::jsonb))
  LOOP
    -- Resolve or auto-create Sprint UUID
    IF v_item->>'sprint' IS NOT NULL AND v_item->>'sprint' <> '' THEN
      INSERT INTO sprints (project_id, sprint_number, sprint_name, start_date, end_date, status)
      VALUES (
        v_project_id,
        COALESCE(NULLIF(regexp_replace(v_item->>'sprint', '\D', '', 'g'), '')::int, 1),
        v_item->>'sprint',
        CURRENT_DATE,
        CURRENT_DATE + INTERVAL '14 days',
        'Planned'
      )
      ON CONFLICT (project_id, sprint_name) DO UPDATE SET sprint_name = EXCLUDED.sprint_name
      RETURNING id INTO v_sprint_id;
    ELSE
      v_sprint_id := NULL;
    END IF;

    -- Resolve Milestone UUID by milestone_code
    SELECT id INTO v_milestone_id
    FROM project_milestones
    WHERE project_id = v_project_id
      AND milestone_code = NULLIF(TRIM(v_item->>'milestone_code'), '')
    LIMIT 1;

    -- Resolve Assignee UUID by full_name
    SELECT id INTO v_assignee_id
    FROM resources
    WHERE LOWER(full_name) = LOWER(TRIM(v_item->>'assignee'))
    LIMIT 1;

    INSERT INTO project_tasks (
      project_id, sprint_id, milestone_id, assignee_id,
      task_id, task_name, status, priority, due_date, labels, description
    )
    VALUES (
      v_project_id,
      v_sprint_id,
      v_milestone_id,
      v_assignee_id,
      v_item->>'task_id',
      v_item->>'task_name',
      COALESCE(NULLIF(v_item->>'status', ''), 'To Do')::task_status_enum,
      COALESCE(NULLIF(v_item->>'priority', ''), 'Medium')::priority_level_enum,
      COALESCE(NULLIF(v_item->>'due_date', '')::date, CURRENT_DATE + INTERVAL '14 days'),
      CASE WHEN v_item->>'labels' IS NOT NULL AND v_item->>'labels' <> ''
           THEN string_to_array(v_item->>'labels', ',')
           ELSE NULL END,
      v_item->>'description'
    )
    ON CONFLICT (project_id, task_id) DO UPDATE SET
      sprint_id = COALESCE(EXCLUDED.sprint_id, project_tasks.sprint_id),
      milestone_id = COALESCE(EXCLUDED.milestone_id, project_tasks.milestone_id),
      assignee_id = COALESCE(EXCLUDED.assignee_id, project_tasks.assignee_id),
      task_name = EXCLUDED.task_name,
      status = EXCLUDED.status,
      priority = EXCLUDED.priority,
      due_date = EXCLUDED.due_date,
      description = EXCLUDED.description;

    v_task_count := v_task_count + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'status', 'success',
    'project_code', p_project->>'project_code',
    'phases_ingested', v_phase_count,
    'milestones_ingested', v_milestone_count,
    'tasks_ingested', v_task_count
  );
END;
$$;


ALTER FUNCTION "public"."ingest_excel_project"("p_project" "jsonb", "p_phases" "jsonb", "p_milestones" "jsonb", "p_tasks" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."ingest_excel_project"("p_project" "jsonb", "p_phases" "jsonb" DEFAULT '[]'::"jsonb", "p_milestones" "jsonb" DEFAULT '[]'::"jsonb", "p_tasks" "jsonb" DEFAULT '[]'::"jsonb", "p_risks" "jsonb" DEFAULT '[]'::"jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  v_dept_id uuid;
  v_project_id uuid;
  v_item jsonb;
  v_phase_id uuid;
  v_sprint_id uuid;
  v_milestone_id uuid;
  v_assignee_id uuid;
  v_phase_count int := 0;
  v_milestone_count int := 0;
  v_task_count int := 0;
  v_risk_count int := 0;
BEGIN
  -- Auto-unwrap if LLM sent stringified JSON scalars instead of JSON objects/arrays
  IF jsonb_typeof(p_project) = 'string' THEN p_project := (p_project #>> '{}')::jsonb; END IF;
  IF jsonb_typeof(p_phases) = 'string' THEN p_phases := (p_phases #>> '{}')::jsonb; END IF;
  IF jsonb_typeof(p_milestones) = 'string' THEN p_milestones := (p_milestones #>> '{}')::jsonb; END IF;
  IF jsonb_typeof(p_tasks) = 'string' THEN p_tasks := (p_tasks #>> '{}')::jsonb; END IF;
  IF jsonb_typeof(p_risks) = 'string' THEN p_risks := (p_risks #>> '{}')::jsonb; END IF;

  -- 1. RESOLVE DEPARTMENT
  SELECT id INTO v_dept_id
  FROM departments
  WHERE dept_code = COALESCE(NULLIF(p_project->>'dept_code', ''), 'DEPT-AI')
  LIMIT 1;

  -- 2. UPSERT PROJECT
  INSERT INTO projects (
    department_id, project_code, client_name, title, description, start_date, target_end_date, status
  )
  VALUES (
    v_dept_id,
    p_project->>'project_code',
    p_project->>'client_name',
    p_project->>'title',
    COALESCE(NULLIF(p_project->>'description', ''), 'Created via MIRA'),
    COALESCE(NULLIF(p_project->>'start_date', '')::date, CURRENT_DATE),
    COALESCE(NULLIF(p_project->>'target_end_date', '')::date, CURRENT_DATE + INTERVAL '16 weeks'),
    'Active'
  )
  ON CONFLICT (project_code) DO UPDATE SET
    client_name = EXCLUDED.client_name,
    title = EXCLUDED.title,
    description = EXCLUDED.description
  RETURNING id INTO v_project_id;

  -- 3. UPSERT PROJECT PHASES
  FOR v_item IN SELECT * FROM jsonb_array_elements(COALESCE(p_phases, '[]'::jsonb))
  LOOP
    INSERT INTO project_phases (
      project_id, phase_number, phase_name, start_week, end_week, key_activities
    )
    VALUES (
      v_project_id,
      (v_item->>'phase_number')::int,
      v_item->>'phase_name',
      COALESCE(NULLIF(v_item->>'start_week', '')::int, 1),
      COALESCE(NULLIF(v_item->>'end_week', '')::int, 2),
      CASE 
        WHEN jsonb_typeof(v_item->'key_activities') = 'array' THEN
          ARRAY(SELECT jsonb_array_elements_text(v_item->'key_activities'))
        ELSE
          string_to_array(COALESCE(v_item->>'key_activities', ''), ';')
      END
    )
    ON CONFLICT (project_id, phase_number) DO UPDATE SET
      phase_name = EXCLUDED.phase_name,
      start_week = EXCLUDED.start_week,
      end_week = EXCLUDED.end_week,
      key_activities = EXCLUDED.key_activities;

    v_phase_count := v_phase_count + 1;
  END LOOP;

  -- 4. UPSERT MILESTONES
  FOR v_item IN SELECT * FROM jsonb_array_elements(COALESCE(p_milestones, '[]'::jsonb))
  LOOP
    SELECT id INTO v_phase_id
    FROM project_phases
    WHERE project_id = v_project_id
      AND phase_number = NULLIF(v_item->>'phase_number', '')::int
    LIMIT 1;

    IF v_item->>'target_sprint' IS NOT NULL AND v_item->>'target_sprint' <> '' THEN
      INSERT INTO sprints (project_id, sprint_number, sprint_name, start_date, end_date, status)
      VALUES (
        v_project_id,
        COALESCE(NULLIF(regexp_replace(v_item->>'target_sprint', '\D', '', 'g'), '')::int, 1),
        v_item->>'target_sprint',
        CURRENT_DATE,
        CURRENT_DATE + INTERVAL '14 days',
        'Planned'
      )
      ON CONFLICT (project_id, sprint_name) DO UPDATE SET sprint_name = EXCLUDED.sprint_name
      RETURNING id INTO v_sprint_id;
    ELSE
      v_sprint_id := NULL;
    END IF;

    INSERT INTO project_milestones (
      project_id, phase_id, target_sprint_id, milestone_code, title, due_date, priority, status
    )
    VALUES (
      v_project_id,
      v_phase_id,
      v_sprint_id,
      v_item->>'milestone_code',
      v_item->>'title',
      COALESCE(NULLIF(v_item->>'due_date', '')::date, CURRENT_DATE + INTERVAL '30 days'),
      COALESCE(NULLIF(v_item->>'priority', ''), 'High')::priority_level_enum,
      COALESCE(NULLIF(v_item->>'status', ''), 'Pending')::milestone_status_enum
    )
    ON CONFLICT (project_id, milestone_code) DO UPDATE SET
      title = EXCLUDED.title,
      due_date = EXCLUDED.due_date,
      priority = EXCLUDED.priority,
      status = EXCLUDED.status;

    v_milestone_count := v_milestone_count + 1;
  END LOOP;

  -- 5. UPSERT TASKS
  FOR v_item IN SELECT * FROM jsonb_array_elements(COALESCE(p_tasks, '[]'::jsonb))
  LOOP
    IF v_item->>'sprint' IS NOT NULL AND v_item->>'sprint' <> '' THEN
      INSERT INTO sprints (project_id, sprint_number, sprint_name, start_date, end_date, status)
      VALUES (
        v_project_id,
        COALESCE(NULLIF(regexp_replace(v_item->>'sprint', '\D', '', 'g'), '')::int, 1),
        v_item->>'sprint',
        CURRENT_DATE,
        CURRENT_DATE + INTERVAL '14 days',
        'Planned'
      )
      ON CONFLICT (project_id, sprint_name) DO UPDATE SET sprint_name = EXCLUDED.sprint_name
      RETURNING id INTO v_sprint_id;
    ELSE
      v_sprint_id := NULL;
    END IF;

    SELECT id INTO v_milestone_id
    FROM project_milestones
    WHERE project_id = v_project_id
      AND milestone_code = NULLIF(TRIM(v_item->>'milestone_code'), '')
    LIMIT 1;

    SELECT id INTO v_assignee_id
    FROM resources
    WHERE LOWER(full_name) = LOWER(TRIM(v_item->>'assignee'))
    LIMIT 1;

    INSERT INTO project_tasks (
      project_id, sprint_id, milestone_id, assignee_id,
      task_id, task_name, status, priority, due_date, labels, description
    )
    VALUES (
      v_project_id,
      v_sprint_id,
      v_milestone_id,
      v_assignee_id,
      v_item->>'task_id',
      v_item->>'task_name',
      COALESCE(NULLIF(v_item->>'status', ''), 'To Do')::task_status_enum,
      COALESCE(NULLIF(v_item->>'priority', ''), 'Medium')::priority_level_enum,
      COALESCE(NULLIF(v_item->>'due_date', '')::date, CURRENT_DATE + INTERVAL '14 days'),
      CASE 
        WHEN jsonb_typeof(v_item->'labels') = 'array' THEN
          ARRAY(SELECT jsonb_array_elements_text(v_item->'labels'))
        WHEN v_item->>'labels' IS NOT NULL AND v_item->>'labels' <> '' THEN
          string_to_array(v_item->>'labels', ',')
        ELSE NULL 
      END,
      v_item->>'description'
    )
    ON CONFLICT (project_id, task_id) DO UPDATE SET
      task_name = EXCLUDED.task_name,
      status = EXCLUDED.status,
      priority = EXCLUDED.priority,
      due_date = EXCLUDED.due_date,
      description = EXCLUDED.description;

    v_task_count := v_task_count + 1;
  END LOOP;

  -- 6. UPSERT RISKS
  FOR v_item IN SELECT * FROM jsonb_array_elements(COALESCE(p_risks, '[]'::jsonb))
  LOOP
    INSERT INTO project_risks (
      project_id, risk_id, category, severity, risk_challenge, impact, mitigation_strategy, status
    )
    VALUES (
      v_project_id,
      v_item->>'risk_id',
      COALESCE(
        (SELECT unnest(enum_range(NULL::risk_category_enum))::text 
         INTERSECT SELECT v_item->>'category' LIMIT 1),
        'Other'
      )::risk_category_enum,
      COALESCE(NULLIF(v_item->>'severity', ''), 'Medium')::risk_severity_enum,
      v_item->>'risk_challenge',
      v_item->>'impact',
      v_item->>'mitigation_strategy',
      'Open'
    )
    ON CONFLICT (project_id, risk_id) DO UPDATE SET
      category = EXCLUDED.category,
      severity = EXCLUDED.severity,
      risk_challenge = EXCLUDED.risk_challenge,
      impact = EXCLUDED.impact,
      mitigation_strategy = EXCLUDED.mitigation_strategy;

    v_risk_count := v_risk_count + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'status', 'success',
    'project_code', p_project->>'project_code',
    'phases_ingested', v_phase_count,
    'milestones_ingested', v_milestone_count,
    'tasks_ingested', v_task_count,
    'risks_ingested', v_risk_count
  );
END;
$$;


ALTER FUNCTION "public"."ingest_excel_project"("p_project" "jsonb", "p_phases" "jsonb", "p_milestones" "jsonb", "p_tasks" "jsonb", "p_risks" "jsonb") OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."agent_outputs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "project_id" "uuid",
    "test_case_id" "text",
    "agent_routed" "public"."agent_type_enum" NOT NULL,
    "user_prompt" "text" NOT NULL,
    "generated_output" "jsonb" NOT NULL,
    "is_approved" boolean DEFAULT false,
    "tokens_used" integer,
    "estimated_cost_usd" numeric(10,6),
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."agent_outputs" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."departments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "dept_code" "text" NOT NULL,
    "name" "text" NOT NULL,
    "head_of_dept" "text",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."departments" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."project_milestones" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "project_id" "uuid",
    "phase_id" "uuid",
    "target_sprint_id" "uuid",
    "milestone_code" "text" NOT NULL,
    "title" "text" NOT NULL,
    "due_date" "date" NOT NULL,
    "priority" "public"."priority_level_enum" DEFAULT 'High'::"public"."priority_level_enum" NOT NULL,
    "status" "public"."milestone_status_enum" DEFAULT 'Pending'::"public"."milestone_status_enum" NOT NULL
);


ALTER TABLE "public"."project_milestones" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."project_phases" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "project_id" "uuid",
    "phase_number" integer NOT NULL,
    "phase_name" "text" NOT NULL,
    "start_week" integer NOT NULL,
    "end_week" integer NOT NULL,
    "key_activities" "text"[] NOT NULL
);


ALTER TABLE "public"."project_phases" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."project_risks" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "project_id" "uuid",
    "risk_id" "text" NOT NULL,
    "category" "public"."risk_category_enum" NOT NULL,
    "severity" "public"."risk_severity_enum" DEFAULT 'High'::"public"."risk_severity_enum" NOT NULL,
    "risk_challenge" "text" NOT NULL,
    "impact" "text" NOT NULL,
    "mitigation_strategy" "text" NOT NULL,
    "owner_id" "uuid",
    "status" "public"."risk_status_enum" DEFAULT 'Open'::"public"."risk_status_enum" NOT NULL
);


ALTER TABLE "public"."project_risks" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."project_tasks" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "project_id" "uuid",
    "sprint_id" "uuid",
    "milestone_id" "uuid",
    "related_risk_id" "uuid",
    "assignee_id" "uuid",
    "task_id" "text" NOT NULL,
    "task_name" "text" NOT NULL,
    "status" "public"."task_status_enum" DEFAULT 'To Do'::"public"."task_status_enum" NOT NULL,
    "priority" "public"."priority_level_enum" DEFAULT 'Medium'::"public"."priority_level_enum" NOT NULL,
    "due_date" "date" NOT NULL,
    "estimated_hours" numeric(6,2) DEFAULT 0,
    "actual_hours" numeric(6,2) DEFAULT 0,
    "labels" "text"[],
    "description" "text"
);


ALTER TABLE "public"."project_tasks" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."projects" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "department_id" "uuid",
    "project_code" "text" NOT NULL,
    "client_name" "text" NOT NULL,
    "title" "text" NOT NULL,
    "description" "text" NOT NULL,
    "start_date" "date",
    "target_end_date" "date",
    "status" "public"."project_status_enum" DEFAULT 'Active'::"public"."project_status_enum" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."projects" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."resource_allocations" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "project_id" "uuid",
    "resource_id" "uuid",
    "sprint_id" "uuid",
    "allocated_hours" numeric(6,2) NOT NULL,
    "logged_hours" numeric(6,2) DEFAULT 0
);


ALTER TABLE "public"."resource_allocations" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."resources" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "employee_code" "text" NOT NULL,
    "full_name" "text" NOT NULL,
    "email" "text",
    "role_title" "text" NOT NULL,
    "department_id" "uuid",
    "weekly_capacity_hours" numeric(5,2) DEFAULT 40.00,
    "hourly_rate_usd" numeric(8,2),
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."resources" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."risk_milestone_links" (
    "risk_id" "uuid" NOT NULL,
    "milestone_id" "uuid" NOT NULL,
    "impact_note" "text"
);


ALTER TABLE "public"."risk_milestone_links" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."sprints" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "project_id" "uuid",
    "sprint_number" integer NOT NULL,
    "sprint_name" "text" NOT NULL,
    "start_date" "date" NOT NULL,
    "end_date" "date" NOT NULL,
    "goal" "text",
    "status" "public"."sprint_status_enum" DEFAULT 'Planned'::"public"."sprint_status_enum" NOT NULL
);


ALTER TABLE "public"."sprints" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_at_risk_milestones" AS
 SELECT "p"."project_code",
    "m"."milestone_code",
    "m"."title" AS "milestone_title",
    "m"."due_date" AS "milestone_due_date",
    "m"."status" AS "milestone_status",
    "t"."task_id" AS "blocking_task_id",
    "t"."task_name" AS "blocking_task_name",
    "t"."status" AS "task_status",
    "r"."risk_id",
    "r"."category" AS "risk_category",
    "r"."risk_challenge"
   FROM (((("public"."project_milestones" "m"
     JOIN "public"."projects" "p" ON (("m"."project_id" = "p"."id")))
     LEFT JOIN "public"."project_tasks" "t" ON ((("t"."milestone_id" = "m"."id") AND ("t"."status" = 'Blocked'::"public"."task_status_enum"))))
     LEFT JOIN "public"."risk_milestone_links" "rml" ON (("rml"."milestone_id" = "m"."id")))
     LEFT JOIN "public"."project_risks" "r" ON (("r"."id" = COALESCE("t"."related_risk_id", "rml"."risk_id"))))
  WHERE (("m"."status" = ANY (ARRAY['At risk'::"public"."milestone_status_enum", 'Missed'::"public"."milestone_status_enum"])) OR ("t"."status" = 'Blocked'::"public"."task_status_enum"));


ALTER VIEW "public"."v_at_risk_milestones" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_project_risks_summary" AS
 SELECT "p"."id" AS "project_id",
    "p"."project_code",
    "p"."client_name",
    "p"."title" AS "project_title",
    "r"."risk_id",
    "r"."category",
    "r"."severity",
    "r"."risk_challenge",
    "r"."impact",
    "r"."mitigation_strategy",
    "r"."status" AS "risk_status",
    "res"."full_name" AS "risk_owner",
    COALESCE("string_agg"((("m"."milestone_code" || ': '::"text") || "m"."title"), '; '::"text"), 'None linked'::"text") AS "impacted_milestones",
    "lower"((((("p"."project_code" || ' '::"text") || "p"."client_name") || ' '::"text") || "p"."title")) AS "search_key"
   FROM (((("public"."projects" "p"
     JOIN "public"."project_risks" "r" ON (("r"."project_id" = "p"."id")))
     LEFT JOIN "public"."resources" "res" ON (("r"."owner_id" = "res"."id")))
     LEFT JOIN "public"."risk_milestone_links" "rml" ON (("rml"."risk_id" = "r"."id")))
     LEFT JOIN "public"."project_milestones" "m" ON (("rml"."milestone_id" = "m"."id")))
  GROUP BY "p"."id", "p"."project_code", "p"."client_name", "p"."title", "r"."risk_id", "r"."category", "r"."severity", "r"."risk_challenge", "r"."impact", "r"."mitigation_strategy", "r"."status", "res"."full_name";


ALTER VIEW "public"."v_project_risks_summary" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_project_status_summary" AS
 SELECT "p"."id" AS "project_id",
    "p"."project_code",
    "p"."client_name",
    "p"."title" AS "project_title",
    "p"."status" AS "project_status",
    "s"."sprint_number",
    "s"."sprint_name",
    "s"."status" AS "sprint_status",
    "m"."milestone_code",
    "m"."title" AS "milestone_title",
    "m"."due_date" AS "milestone_due_date",
    "m"."status" AS "milestone_status",
    "t"."task_id",
    "t"."task_name",
    "t"."status" AS "task_status",
    "t"."priority" AS "task_priority",
    "t"."due_date" AS "task_due_date",
    "res"."full_name" AS "assignee_name",
    "t"."description" AS "task_description",
    "lower"((((("p"."project_code" || ' '::"text") || "p"."client_name") || ' '::"text") || "p"."title")) AS "search_key"
   FROM (((("public"."projects" "p"
     LEFT JOIN "public"."project_tasks" "t" ON (("t"."project_id" = "p"."id")))
     LEFT JOIN "public"."sprints" "s" ON (("t"."sprint_id" = "s"."id")))
     LEFT JOIN "public"."project_milestones" "m" ON (("t"."milestone_id" = "m"."id")))
     LEFT JOIN "public"."resources" "res" ON (("t"."assignee_id" = "res"."id")));


ALTER VIEW "public"."v_project_status_summary" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_resource_utilization" AS
SELECT
    NULL::"text" AS "employee_code",
    NULL::"text" AS "full_name",
    NULL::"text" AS "role_title",
    NULL::"text" AS "department_name",
    NULL::"text" AS "sprint_name",
    NULL::"date" AS "start_date",
    NULL::"date" AS "end_date",
    NULL::numeric AS "sprint_capacity_hours",
    NULL::numeric AS "total_allocated_hours",
    NULL::numeric AS "utilization_pct";


ALTER VIEW "public"."v_resource_utilization" OWNER TO "postgres";


ALTER TABLE ONLY "public"."agent_outputs"
    ADD CONSTRAINT "agent_outputs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."departments"
    ADD CONSTRAINT "departments_dept_code_key" UNIQUE ("dept_code");



ALTER TABLE ONLY "public"."departments"
    ADD CONSTRAINT "departments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."project_milestones"
    ADD CONSTRAINT "project_milestones_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."project_milestones"
    ADD CONSTRAINT "project_milestones_project_id_milestone_code_key" UNIQUE ("project_id", "milestone_code");



ALTER TABLE ONLY "public"."project_phases"
    ADD CONSTRAINT "project_phases_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."project_phases"
    ADD CONSTRAINT "project_phases_project_id_phase_number_key" UNIQUE ("project_id", "phase_number");



ALTER TABLE ONLY "public"."project_risks"
    ADD CONSTRAINT "project_risks_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."project_risks"
    ADD CONSTRAINT "project_risks_project_id_risk_id_key" UNIQUE ("project_id", "risk_id");



ALTER TABLE ONLY "public"."project_tasks"
    ADD CONSTRAINT "project_tasks_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."project_tasks"
    ADD CONSTRAINT "project_tasks_project_id_task_id_key" UNIQUE ("project_id", "task_id");



ALTER TABLE ONLY "public"."projects"
    ADD CONSTRAINT "projects_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."projects"
    ADD CONSTRAINT "projects_project_code_key" UNIQUE ("project_code");



ALTER TABLE ONLY "public"."resource_allocations"
    ADD CONSTRAINT "resource_allocations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."resource_allocations"
    ADD CONSTRAINT "resource_allocations_project_id_resource_id_sprint_id_key" UNIQUE ("project_id", "resource_id", "sprint_id");



ALTER TABLE ONLY "public"."resources"
    ADD CONSTRAINT "resources_email_key" UNIQUE ("email");



ALTER TABLE ONLY "public"."resources"
    ADD CONSTRAINT "resources_employee_code_key" UNIQUE ("employee_code");



ALTER TABLE ONLY "public"."resources"
    ADD CONSTRAINT "resources_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."risk_milestone_links"
    ADD CONSTRAINT "risk_milestone_links_pkey" PRIMARY KEY ("risk_id", "milestone_id");



ALTER TABLE ONLY "public"."sprints"
    ADD CONSTRAINT "sprints_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."sprints"
    ADD CONSTRAINT "sprints_project_id_sprint_name_key" UNIQUE ("project_id", "sprint_name");



CREATE INDEX "idx_allocations_resource_sprint" ON "public"."resource_allocations" USING "btree" ("resource_id", "sprint_id");



CREATE INDEX "idx_projects_dept" ON "public"."projects" USING "btree" ("department_id");



CREATE INDEX "idx_tasks_project_status" ON "public"."project_tasks" USING "btree" ("project_id", "status");



CREATE INDEX "idx_tasks_sprint_milestone" ON "public"."project_tasks" USING "btree" ("sprint_id", "milestone_id");



CREATE OR REPLACE VIEW "public"."v_resource_utilization" AS
 SELECT "res"."employee_code",
    "res"."full_name",
    "res"."role_title",
    "d"."name" AS "department_name",
    "s"."sprint_name",
    "s"."start_date",
    "s"."end_date",
    ("res"."weekly_capacity_hours" * (2)::numeric) AS "sprint_capacity_hours",
    COALESCE("sum"("ra"."allocated_hours"), (0)::numeric) AS "total_allocated_hours",
    "round"(((COALESCE("sum"("ra"."allocated_hours"), (0)::numeric) / NULLIF(("res"."weekly_capacity_hours" * (2)::numeric), (0)::numeric)) * (100)::numeric), 1) AS "utilization_pct"
   FROM ((("public"."resources" "res"
     LEFT JOIN "public"."departments" "d" ON (("res"."department_id" = "d"."id")))
     CROSS JOIN "public"."sprints" "s")
     LEFT JOIN "public"."resource_allocations" "ra" ON ((("ra"."resource_id" = "res"."id") AND ("ra"."sprint_id" = "s"."id"))))
  GROUP BY "res"."id", "d"."name", "s"."id";



ALTER TABLE ONLY "public"."agent_outputs"
    ADD CONSTRAINT "agent_outputs_project_id_fkey" FOREIGN KEY ("project_id") REFERENCES "public"."projects"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."project_milestones"
    ADD CONSTRAINT "project_milestones_phase_id_fkey" FOREIGN KEY ("phase_id") REFERENCES "public"."project_phases"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."project_milestones"
    ADD CONSTRAINT "project_milestones_project_id_fkey" FOREIGN KEY ("project_id") REFERENCES "public"."projects"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."project_milestones"
    ADD CONSTRAINT "project_milestones_target_sprint_id_fkey" FOREIGN KEY ("target_sprint_id") REFERENCES "public"."sprints"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."project_phases"
    ADD CONSTRAINT "project_phases_project_id_fkey" FOREIGN KEY ("project_id") REFERENCES "public"."projects"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."project_risks"
    ADD CONSTRAINT "project_risks_owner_id_fkey" FOREIGN KEY ("owner_id") REFERENCES "public"."resources"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."project_risks"
    ADD CONSTRAINT "project_risks_project_id_fkey" FOREIGN KEY ("project_id") REFERENCES "public"."projects"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."project_tasks"
    ADD CONSTRAINT "project_tasks_assignee_id_fkey" FOREIGN KEY ("assignee_id") REFERENCES "public"."resources"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."project_tasks"
    ADD CONSTRAINT "project_tasks_milestone_id_fkey" FOREIGN KEY ("milestone_id") REFERENCES "public"."project_milestones"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."project_tasks"
    ADD CONSTRAINT "project_tasks_project_id_fkey" FOREIGN KEY ("project_id") REFERENCES "public"."projects"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."project_tasks"
    ADD CONSTRAINT "project_tasks_related_risk_id_fkey" FOREIGN KEY ("related_risk_id") REFERENCES "public"."project_risks"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."project_tasks"
    ADD CONSTRAINT "project_tasks_sprint_id_fkey" FOREIGN KEY ("sprint_id") REFERENCES "public"."sprints"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."projects"
    ADD CONSTRAINT "projects_department_id_fkey" FOREIGN KEY ("department_id") REFERENCES "public"."departments"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."resource_allocations"
    ADD CONSTRAINT "resource_allocations_project_id_fkey" FOREIGN KEY ("project_id") REFERENCES "public"."projects"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."resource_allocations"
    ADD CONSTRAINT "resource_allocations_resource_id_fkey" FOREIGN KEY ("resource_id") REFERENCES "public"."resources"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."resource_allocations"
    ADD CONSTRAINT "resource_allocations_sprint_id_fkey" FOREIGN KEY ("sprint_id") REFERENCES "public"."sprints"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."resources"
    ADD CONSTRAINT "resources_department_id_fkey" FOREIGN KEY ("department_id") REFERENCES "public"."departments"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."risk_milestone_links"
    ADD CONSTRAINT "risk_milestone_links_milestone_id_fkey" FOREIGN KEY ("milestone_id") REFERENCES "public"."project_milestones"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."risk_milestone_links"
    ADD CONSTRAINT "risk_milestone_links_risk_id_fkey" FOREIGN KEY ("risk_id") REFERENCES "public"."project_risks"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."sprints"
    ADD CONSTRAINT "sprints_project_id_fkey" FOREIGN KEY ("project_id") REFERENCES "public"."projects"("id") ON DELETE CASCADE;



ALTER TABLE "public"."agent_outputs" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."departments" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."project_milestones" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."project_phases" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."project_risks" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."project_tasks" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."projects" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."resource_allocations" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."resources" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."risk_milestone_links" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."sprints" ENABLE ROW LEVEL SECURITY;




ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";


GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";






















































































































































GRANT ALL ON FUNCTION "public"."ingest_excel_project"("p_project" "jsonb", "p_phases" "jsonb", "p_milestones" "jsonb", "p_tasks" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."ingest_excel_project"("p_project" "jsonb", "p_phases" "jsonb", "p_milestones" "jsonb", "p_tasks" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."ingest_excel_project"("p_project" "jsonb", "p_phases" "jsonb", "p_milestones" "jsonb", "p_tasks" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."ingest_excel_project"("p_project" "jsonb", "p_phases" "jsonb", "p_milestones" "jsonb", "p_tasks" "jsonb", "p_risks" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."ingest_excel_project"("p_project" "jsonb", "p_phases" "jsonb", "p_milestones" "jsonb", "p_tasks" "jsonb", "p_risks" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."ingest_excel_project"("p_project" "jsonb", "p_phases" "jsonb", "p_milestones" "jsonb", "p_tasks" "jsonb", "p_risks" "jsonb") TO "service_role";


















GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."agent_outputs" TO "anon";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."agent_outputs" TO "authenticated";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."agent_outputs" TO "service_role";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."departments" TO "anon";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."departments" TO "authenticated";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."departments" TO "service_role";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."project_milestones" TO "anon";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."project_milestones" TO "authenticated";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."project_milestones" TO "service_role";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."project_phases" TO "anon";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."project_phases" TO "authenticated";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."project_phases" TO "service_role";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."project_risks" TO "anon";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."project_risks" TO "authenticated";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."project_risks" TO "service_role";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."project_tasks" TO "anon";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."project_tasks" TO "authenticated";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."project_tasks" TO "service_role";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."projects" TO "anon";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."projects" TO "authenticated";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."projects" TO "service_role";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."resource_allocations" TO "anon";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."resource_allocations" TO "authenticated";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."resource_allocations" TO "service_role";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."resources" TO "anon";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."resources" TO "authenticated";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."resources" TO "service_role";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."risk_milestone_links" TO "anon";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."risk_milestone_links" TO "authenticated";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."risk_milestone_links" TO "service_role";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."sprints" TO "anon";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."sprints" TO "authenticated";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."sprints" TO "service_role";



GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."v_at_risk_milestones" TO "anon";
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."v_at_risk_milestones" TO "authenticated";
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."v_at_risk_milestones" TO "service_role";



GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."v_project_risks_summary" TO "anon";
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."v_project_risks_summary" TO "authenticated";
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."v_project_risks_summary" TO "service_role";



GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."v_project_status_summary" TO "anon";
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."v_project_status_summary" TO "authenticated";
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."v_project_status_summary" TO "service_role";



GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."v_resource_utilization" TO "anon";
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."v_resource_utilization" TO "authenticated";
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."v_resource_utilization" TO "service_role";









ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLES TO "service_role";































