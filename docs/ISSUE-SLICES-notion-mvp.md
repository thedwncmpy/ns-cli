# Notion CLI MVP Issue Slices (HITL)

Parent PRD issue: https://github.com/thedwncmpy/notion-cli/issues/1

## Approved slicing

1. Bootstrap `notion` Command With Subcommand Router
- Type: HITL
- Blocked by: None
- User stories: 2, 26, 27, 28, 30

2. Add Project Config Lifecycle (`init`)
- Type: HITL
- Blocked by: #1
- User stories: 3, 4, 5, 6, 30

3. Add Relation Mapping Workflow (`link`)
- Type: HITL
- Blocked by: #2
- User stories: 10, 11, 12, 17

4. Implement Credential Loading and Secret Separation
- Type: HITL
- Blocked by: #1
- User stories: 7, 8, 9, 26

5. Ship Upload Vertical Slice With Strict Guardrails
- Type: HITL
- Blocked by: #3, #4
- User stories: 13, 14, 15, 16, 17, 18, 22, 23, 24, 25, 26, 27

6. Ship Download Vertical Slice With Overwrite + Create Behavior
- Type: HITL
- Blocked by: #3, #4
- User stories: 19, 20, 21, 22, 23, 24, 25, 26, 27
- Clarified behavior: if file exists locally, `notion download` overwrites it with remote content; if missing locally and remote exists, create it (including parent directories).

7. Roundtrip and Contract Test Harness
- Type: HITL
- Blocked by: #5, #6
- User stories: 25, 26, 29, 30

8. Publish Homebrew Tap Package for MVP
- Type: HITL
- Blocked by: #7
- User stories: 1, 28, 29

## TDD mode

Use TDD where needed for implementation tickets:
- Red-Green-Refactor in vertical slices
- Test external CLI behavior via public interface
- Avoid implementation-coupled tests
