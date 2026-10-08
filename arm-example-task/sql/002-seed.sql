INSERT INTO users VALUES (1, 'Alice'), (2, 'Bob'), (3, 'Carol');
INSERT INTO projects VALUES (1, 'ARM MVP'), (2, 'Documentation');
INSERT INTO project_members VALUES (1, 1), (1, 2), (2, 1), (2, 3);
INSERT INTO tasks (title, project_id, status, created_by, created_at, assignee_id, closed_at)
VALUES ('Review domain algebra', 1, 'open', 1, '2026-06-27T12:00:00Z', 2, NULL),
       ('Write usage guide', 2, 'open', 1, '2026-06-27T12:00:00Z', 3, NULL),
       ('Define MVP scope', 1, 'closed', 1, '2026-06-27T12:00:00Z', NULL, '2026-06-28T12:00:00Z');
