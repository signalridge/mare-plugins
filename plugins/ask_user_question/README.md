# ask_user_question

Prompts the user through Mare's interactive UI with structured multi-choice questions, recommendations, optional previews, free-text answers, and skip handling.

## Tool

- `ask_user_question`: required `questions` (array of 1 to 4 objects).
  - Each question requires `id` (`<= 64` chars, unique), `header` (`<= 12` chars), `question` (`<= 2000` chars), and `options` (2 to 4 objects, each requiring `label` `<= 120` chars and not `"Other"`, plus `description` `<= 1000` chars; optional `recommended` boolean with at most one per question, and optional `preview` `<= 10000` chars).
  - Optional per question: `multi_select` (`boolean`).

## Availability and error codes

- Requires an interactive UI responder (`mare.ui.can_respond() == true`) in a main session.
- Inside child agents (`mare.mode == "child"`) or headless sessions without an interactive responder, returns `{ answers = [], error = { code = "NO_PROVIDER", message = ... } }` with `is_error = true`.
- User dismissals return `{ answers = [], note = ... }` (`is_error = false`).
- Aborts/interrupts return `code = "ASK_ABORTED"` and disconnects return `code = "DISCONNECTED"`.

## Requirements

- Injects `tools` and `session`.
- See [docs/plugins.md](../../docs/plugins.md#ask_user_question) for full details.
