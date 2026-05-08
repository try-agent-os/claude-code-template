-- Operator onboarding state table
-- DB: agents/operator/operator.db
-- Managed by: onboarding skill (agents/operator/skills/onboarding.md)

CREATE TABLE IF NOT EXISTS onboarding_state (
  -- Telegram chat_id of the user (PRIMARY KEY — each admin is onboarded separately)
  user_id INTEGER PRIMARY KEY,

  -- Current onboarding phase
  -- welcome  → welcome message sent, waiting for response
  -- survey   → survey in progress (survey_step points to current question)
  -- menu     → survey complete, direction menu sent
  -- done     → onboarding fully complete
  -- skipped  → user ignored the return prompt twice
  current_phase TEXT NOT NULL DEFAULT 'welcome',

  -- Current survey question (1=name, 2=occupation+goals, 3=projects)
  -- Relevant only when current_phase = 'survey'
  survey_step INTEGER DEFAULT 1,

  -- Survey answers as JSON
  -- Structure: {"name": "...", "occupation": "...", "goals": [...], "active_projects": [...]}
  -- NULL until survey is started
  survey_answers TEXT,

  -- Selected flow from Phase 3 menu
  -- Values: productivity | gmail | calendar | docs | chats | skip
  selected_flow TEXT,

  -- JSON array of completed integration flows
  -- Example: ["gmail", "calendar"]
  -- Updated when each setup flow completes
  completed_flows TEXT NOT NULL DEFAULT '[]',

  -- Timestamp when onboarding started
  started_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,

  -- Timestamp when onboarding completed (NULL = not yet complete)
  -- When completed_at IS NOT NULL — skip onboarding on next boot
  completed_at TIMESTAMP NULL
);

-- Index for fast boot-time check
CREATE INDEX IF NOT EXISTS idx_onboarding_incomplete
  ON onboarding_state (user_id)
  WHERE completed_at IS NULL;

-- Example queries used by the onboarding skill:

-- Boot check:
-- SELECT current_phase, survey_step, survey_answers, completed_at
-- FROM onboarding_state WHERE user_id = ?;

-- Create row on first run:
-- INSERT INTO onboarding_state (user_id, current_phase) VALUES (?, 'welcome');

-- Update phase:
-- UPDATE onboarding_state SET current_phase = 'survey', survey_step = 1 WHERE user_id = ?;

-- Save a survey answer:
-- UPDATE onboarding_state
-- SET survey_answers = json_patch(COALESCE(survey_answers, '{}'), json_object('name', ?))
-- WHERE user_id = ?;

-- Complete onboarding:
-- UPDATE onboarding_state SET current_phase = 'done', completed_at = CURRENT_TIMESTAMP WHERE user_id = ?;

-- Add completed flow:
-- UPDATE onboarding_state
-- SET completed_flows = json_insert(completed_flows, '$[#]', 'gmail')
-- WHERE user_id = ?;

-- Skip onboarding (/skip onboarding command):
-- UPDATE onboarding_state SET current_phase = 'skipped', completed_at = CURRENT_TIMESTAMP WHERE user_id = ?;
