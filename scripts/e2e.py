#!/usr/bin/env python3
"""Real HTTP + PostgreSQL checks, against the isolated fixture from e2e.sh."""
import concurrent.futures
import json
import os
import subprocess
import time
import urllib.error
import urllib.request

BASE = 'http://127.0.0.1:' + os.environ['ARM_PORT']
READONLY = 'http://127.0.0.1:' + os.environ['ARM_TEST_READONLY_PORT']


def sql(statement):
    return subprocess.check_output(
        ['psql', os.environ['ARM_TEST_DATABASE_URL'], '-XAt', '-v', 'ON_ERROR_STOP=1', '-c', statement],
        text=True).strip()


def call(path, body=None, status=200, base=BASE, raw=None):
    payload = raw if raw is not None else (None if body is None else json.dumps(body, ensure_ascii=False).encode())
    request = urllib.request.Request(base + path, data=payload, headers={'Content-Type': 'application/json'})
    try:
        response = urllib.request.urlopen(request, timeout=5)
    except urllib.error.HTTPError as error:
        response = error
    content = response.read()
    assert response.code == status, (path, response.code, content)
    if status in (404, 405) and not response.headers['Content-Type'].startswith('application/json'):
        return content.decode()
    assert response.headers['Content-Type'].startswith('application/json'), response.headers
    decoded = json.loads(content)
    if status != 200:
        assert isinstance(decoded['error']['kind'], str) and decoded['error']['message'], decoded
    return decoded


def check(name, action):
    action()
    print('PASS:', name, flush=True)


def wait_ready(base):
    for _ in range(100):
        try:
            call('/open-tasks', base=base)
            return
        except (OSError, AssertionError):
            time.sleep(.1)
    raise RuntimeError('sample server did not become ready: ' + base)


def main():
    wait_ready(BASE)
    wait_ready(READONLY)
    assert len(call('/open-tasks')['openTasks']) == 2
    assert len(call('/open-tasks?projectId=1')['openTasks']) == 1
    assert call('/project-task-state?projectId=1') == {'projectId': 1, 'open': 1, 'closed': 1}
    assert len(call('/assignee-inbox?assigneeId=2')['inbox']) == 1
    print('PASS: all three observations read seeded PostgreSQL state', flush=True)
    before = sql('SELECT row_to_json(t) FROM tasks t ORDER BY id')
    for path in ('/open-tasks', '/project-task-state?projectId=1', '/assignee-inbox?assigneeId=2'):
        assert call(path, base=READONLY) == call(path)
    assert before == sql('SELECT row_to_json(t) FROM tasks t ORDER BY id')
    call('/create-task', {'title': 'forbidden'}, status=404, base=READONLY)
    print('PASS: observation-only HTTP app on a PostgreSQL read-only connection; no state change', flush=True)

    for path in ('/open-tasks?projectId=x', '/open-tasks?projectId=0', '/open-tasks?projectId=1&projectId=2',
                 '/open-tasks?unexpected=1', '/project-task-state', '/assignee-inbox', '/open-tasks?projectId=9223372036854775808'):
        call(path, status=400)
    call('/open-tasks?projectId=9999', status=404)
    call('/assignee-inbox?assigneeId=9999', status=404)
    call('/project-task-state?projectId=9999', status=404)
    call('/create-task', raw=b'{', status=400)
    call('/create-task', raw=b'\xff', status=400)
    call('/close-task', {'taskId': 9223372036854775808}, status=400)
    call('/assign-task', {'taskId': 1}, status=400)
    for body in (
        {'title': '  ', 'projectId': 1, 'actorId': 1},
        {'title': 'x' * 201, 'projectId': 1, 'actorId': 1},
        {'title': 'review\x00task', 'projectId': 1, 'actorId': 1},
        {'title': 'x', 'projectId': 1, 'actorId': 3},
        {'title': 'x', 'projectId': 1, 'actorId': 1, 'assigneeId': 3},
        {'title': 'x', 'projectId': 1, 'actorId': 1, 'status': 'closed'},
    ):
        call('/create-task', body, status=400)
    call('/create-task', {'title': 'x', 'projectId': 9999, 'actorId': 1}, status=404)
    call('/create-task', {'title': 'x', 'projectId': 1, 'actorId': 9999}, status=404)
    call('/close-task', {'taskId': 9999}, status=404)
    call('/assign-task', {'taskId': 9999, 'assigneeId': None}, status=404)
    assert before == sql('SELECT row_to_json(t) FROM tasks t ORDER BY id')
    print('PASS: malformed inputs and invalid domain transitions return structured errors without writes', flush=True)

    title = "日本語 '); DROP TABLE tasks; --"
    task = call('/create-task', {'title': title, 'projectId': 1, 'actorId': 1, 'assigneeId': 2})['createdTaskId']
    stored = json.loads(sql(f'SELECT row_to_json(t) FROM tasks t WHERE id={task}'))
    assert stored['title'] == title and stored['project_id'] == 1 and stored['created_by'] == 1
    assert stored['created_at'] and stored['status'] == 'open' and stored['assignee_id'] == 2 and stored['closed_at'] is None
    assert any(t['taskId'] == task and t['title'] == title for t in call('/open-tasks')['openTasks'])
    assert any(t['taskId'] == task for t in call('/assignee-inbox?assigneeId=2', base=READONLY)['inbox'])
    print('PASS: HTTP decode -> SELECT context -> pure creation delta -> INSERT -> JSON; Unicode and SQL parameters preserved', flush=True)

    call('/assign-task', {'taskId': task, 'assigneeId': 3}, status=400)
    call('/assign-task', {'taskId': task, 'assigneeId': 2}, status=409)
    result = call('/assign-task', {'taskId': task, 'assigneeId': 1})
    assert result['assigneeId'] == 1 and result['version'] == 1
    assert sql(f'SELECT assignee_id FROM tasks WHERE id={task}') == '1'
    assert not any(t['taskId'] == task for t in call('/assignee-inbox?assigneeId=2')['inbox'])
    assert any(t['taskId'] == task for t in call('/assignee-inbox?assigneeId=1')['inbox'])
    assert call('/assign-task', {'taskId': task, 'assigneeId': None})['assigneeId'] is None
    assert sql(f'SELECT assignee_id IS NULL FROM tasks WHERE id={task}') == 't'
    print('PASS: assign replaces and explicit null removes the mapping in PostgreSQL', flush=True)

    call('/close-task', {'taskId': task})
    call('/close-task', {'taskId': task}, status=409)
    call('/assign-task', {'taskId': task, 'assigneeId': 2}, status=409)
    assert sql(f'SELECT status FROM tasks WHERE id={task}') == 'closed'
    assert sql(f'SELECT closed_at IS NOT NULL FROM tasks WHERE id={task}') == 't'
    assert not any(t['taskId'] == task for t in call('/open-tasks', base=READONLY)['openTasks'])
    assert call('/project-task-state?projectId=1', base=READONLY)['closed'] == 2
    print('PASS: close applies status and timestamp together; all observations see changed state', flush=True)

    second = call('/create-task', {'title': 'concurrent close', 'projectId': 1, 'actorId': 1})['createdTaskId']
    def close_once(_):
        request = urllib.request.Request(BASE + '/close-task', data=json.dumps({'taskId': second}).encode())
        try:
            return urllib.request.urlopen(request, timeout=5).status
        except urllib.error.HTTPError as error:
            return error.code
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
        assert sorted(executor.map(close_once, range(2))) == [200, 409]
    assert sql(f'SELECT version FROM tasks WHERE id={second}') == '1'
    print('PASS: concurrent closes apply exactly one delta, loser receives 409', flush=True)
    sql("INSERT INTO projects VALUES (99, 'Empty')")
    assert call('/project-task-state?projectId=99') == {'projectId': 99, 'open': 0, 'closed': 0}
    assert call('/open-tasks?projectId=99')['openTasks'] == []
    call('/tasks', status=404)
    call('/create-task', status=405)
    print('PASS: empty existing domain, named URLs and method routing', flush=True)
    print('All real HTTP + PostgreSQL E2E checks passed', flush=True)


if __name__ == '__main__':
    main()
