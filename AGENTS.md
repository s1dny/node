# AGENTS

## Execution Policy (Mandatory)
- Execute tasks end-to-end by default. Do not ask the user to run commands you can run yourself.
- For operational requests, the agent must directly perform: inspect, edit, commit, push, deploy, and verify when access allows.
- Ask the user to do something only when truly blocked by one of these:
  - Interactive authentication the agent cannot complete (for example, sudo password prompts).
  - Missing secret values or credentials the agent cannot infer.
  - Explicit user approval required for destructive or out-of-sandbox actions.
- If blocked by permissions, attempt the command and then request escalation/approval; do not hand the task back to the user as a first response.
- Report actions taken and results; avoid replacing execution with instructions.

## Communication Policy
- Keep responses direct and concise.
- Do not shift execution back to the user when the agent can continue.
