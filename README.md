# Capstone - MIRA v0.1 (TPM Genie)

**MIRA (AI-Powered Project Intelligence Assistant)**, also branded in chat as **TPM Genie**, is an automated n8n multi-agent workflow designed to help Technical Project Managers (TPMs) ingest project plans, track sprint status, analyze risks, and distribute executive updates across Slack and Email.

---

## Architecture Overview

The workflow operates via two primary triggers and routes requests through an AI triage system or a deterministic Excel ingestion pipeline:

1. **Interactive Chat (`When chat message received`)**:
   - **File Upload Branch**: Checks if an `.xlsx` or `.xls` file is attached. If present, it extracts data from four sheets (`Project`, `Phases`, `Milestones`, `Tasks`), merges them, and calls a Supabase RPC endpoint to persist the project.
   - **Text Query Branch**: Routes natural language queries to the **Router Agent**.
2. **Scheduled Automation (`Schedule Trigger`)**:
   - Runs every **Monday at 9:00 AM**.
   - Automatically triggers a leadership-formatted weekly status update for the *ABCDE Ltd. AI Adoption Project* and distributes it via Slack and Email.

---

## Multi-Agent System

All agents use `openai/gpt-4o-mini` via **OpenRouter**:

| Agent | Role & Responsibilities | Connected Tools |
| :--- | :--- | :--- |
| **Router** | Triage agent that classifies `intent`, `sprint`, `audience`, and `source`, delegating sequentially to specialist agents without altering responses. | `Planner Agent`, `Risk Agent`, `Status Agent` |
| **Planner Agent** | Extracts project scopes, KPIs, phases, milestones, tasks, and initial risks from raw descriptions and persists them to Supabase. | `Save Project to DB` (HTTP RPC), `Planner Slack Tool`, `Planner Email Tool` |
| **Status Agent** | Queries task/milestone progress, flags missing timelines or blocked items, and tailors status reports by audience. | `Fetch Project Status` (Supabase), `Status Slack Tool`, `Status Email Tool` |
| **Risk Agent** | Retrieves or analyzes project risks, ranks them by severity (`Critical` to `Low`), and formats mitigation tables. | `Fetch Project Risks` (Supabase), `Risk Slack Tool`, `Risk Email Tool` |

---

## Database & Integrations

### Supabase Backend
- **Views Queried**:
  - `v_project_status_summary` (filtered via `ilike` on `search_key`)
  - `v_project_risks_summary` (filtered via `ilike` on `search_key`)
- **RPC Endpoint**:
  - `POST /rest/v1/rpc/ingest_excel_project` — Accepts `p_project`, `p_phases`, `p_milestones`, `p_tasks`, and `p_risks` JSON payloads.

### Notification Channels
- **Slack Channels**:
  - `#mira-status-updates` (channel-id)
  - `#mira-plan-notifications` (channel-id)
  - `#mira-risk-notifications` (channel-id)
- **Email (Gmail)**:
  - Sends formatted reports to the configured recipient ([Email ID]) when delivery is requested or triggered by schedule.

---

## Excel Ingestion Format

To ingest a project via file upload in chat, upload an `.xlsx` or `.xls` workbook containing the following tabs with header rows:

1. **`Project`**: `project_code`, `client_name`, `title`, `description`, `start_date`, `target_end_date`
2. **`Phases`**: `phase_number`, `phase_name`, `start_week`, `end_week`, `key_activities`
3. **`Milestones`**: `milestone_code`, `title`, `phase_number`, `target_sprint`, `due_date`, `priority`, `status`
4. **`Tasks`**: `task_id`, `task_name`, `status`, `assignee`, `priority`, `sprint`, `milestone_code`, `due_date`, `labels`, `description`

---

## Setup & Deployment (n8n)

1. **Import Workflow**: Import the `Capstone - MIRA v0.1` JSON file into your n8n instance.
2. **Configure Credentials**:
   - **OpenRouter API**: Link your OpenRouter account to the 4 language model nodes.
   - **Supabase**: Configure both OAuth2 (`supabaseOAuth2Api`) for table/view reads and API Key (`supabaseApi`) for the RPC HTTP requests.
   - **Slack OAuth2**: Authenticate and verify channel IDs for status, plan, and risk notifications.
   - **Gmail OAuth2**: Authenticate and update the `sendTo` email address in the three Email Tool nodes.
3. **Activate**: Toggle the workflow to **Active** to enable the public chat interface and Monday morning schedule trigger.

---

## Example Prompts

- **Create a Plan**: *"Create a new project plan for Acme Corp Cloud Migration. Goal: migrate 50 microservices in 12 weeks across 3 phases..."*
- **Check Status**: *"Give me the latest sprint status for ABCDE tailored for engineering."*
- **Analyze Risks**: *"Show me the top 5 risks for ABCDE-AI-2026 and send the report to Slack and Email."*
